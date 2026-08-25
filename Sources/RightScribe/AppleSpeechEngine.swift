import AVFoundation
import Foundation
import Speech

actor AppleSpeechEngine {
    enum EngineError: LocalizedError {
        case unavailable
        case unsupportedLocale
        case modelReservationFailed
        case modelNotInstalled
        case audioFormatUnavailable
        case microphoneUnavailable

        var errorDescription: String? {
            switch self {
            case .unavailable: return "Apple's on-device SpeechTranscriber is unavailable on this Mac."
            case .unsupportedLocale: return "The selected English locale is not supported by Apple SpeechTranscriber."
            case .modelReservationFailed: return "macOS could not reserve space for the English speech model."
            case .modelNotInstalled: return "The English speech model could not be installed."
            case .audioFormatUnavailable: return "RightScribe could not find a compatible microphone format."
            case .microphoneUnavailable: return "No usable microphone input is available."
            }
        }
    }

    private var locale: Locale?
    private var analyzer: SpeechAnalyzer?
    private var analyzerFormat: AVAudioFormat?
    private var audioEngine: AVAudioEngine?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var accumulator = TranscriptAccumulator()
    private var customVocabulary: [String] = []

    func setCustomVocabulary(_ entries: [String]) async throws {
        customVocabulary = CustomVocabulary.sanitized(entries)
        if let analyzer {
            try await analyzer.setContext(makeAnalysisContext())
        }
    }

    func prepare(locale requestedLocale: Locale) async throws {
        guard SpeechTranscriber.isAvailable else { throw EngineError.unavailable }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw EngineError.unsupportedLocale
        }

        let reserved = try await AssetInventory.reserve(locale: supported)
        let alreadyReserved = await AssetInventory.reservedLocales.contains {
            $0.identifier == supported.identifier
        }
        guard reserved || alreadyReserved else { throw EngineError.modelReservationFailed }

        let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        let status = await AssetInventory.status(forModules: [transcriber])
        if status != .installed {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }

        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw EngineError.modelNotInstalled
        }
        locale = supported
        try await prepareStandbySession()
    }

    func start() async throws {
        guard locale != nil else { throw EngineError.modelNotInstalled }
        guard audioEngine == nil else { return }

        if analyzer == nil || inputContinuation == nil || analyzerFormat == nil {
            try await prepareStandbySession()
        }

        guard let analyzerFormat else { throw EngineError.audioFormatUnavailable }
        try startMicrophone(targetFormat: analyzerFormat)
    }

    func rearm() async throws {
        guard audioEngine == nil else { return }
        try await prepareStandbySession()
    }

    private func prepareStandbySession() async throws {
        guard analyzer == nil else { return }
        guard let locale else { throw EngineError.modelNotInstalled }

        accumulator = TranscriptAccumulator()
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: options)
        try await analyzer.setContext(makeAnalysisContext())

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw EngineError.audioFormatUnavailable
        }

        try await analyzer.prepareToAnalyze(in: analyzerFormat)

        let streamPair = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        inputContinuation = streamPair.continuation
        self.analyzer = analyzer
        self.analyzerFormat = analyzerFormat

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    await self.receive(text, isFinal: result.isFinal)
                }
            } catch {
                // Stop/finalize surfaces session failures to the caller. A cancelled
                // result stream is expected when the user cancels dictation.
            }
        }

        do {
            try await analyzer.start(inputSequence: streamPair.stream)
        } catch {
            inputContinuation?.finish()
            inputContinuation = nil
            resultsTask?.cancel()
            await resultsTask?.value
            resultsTask = nil
            self.analyzer = nil
            self.analyzerFormat = nil
            throw error
        }
    }

    private func receive(_ text: String, isFinal: Bool) {
        accumulator.receive(text, isFinal: isFinal)
    }

    private func makeAnalysisContext() -> AnalysisContext {
        let context = AnalysisContext()
        if !customVocabulary.isEmpty {
            context.contextualStrings = [.general: customVocabulary]
        }
        return context
    }

    func stop() async throws -> String {
        stopMicrophone()
        inputContinuation?.finish()
        inputContinuation = nil

        if let analyzer {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        await resultsTask?.value
        resultsTask = nil
        analyzer = nil
        analyzerFormat = nil
        return accumulator.finalized
    }

    func cancel() async {
        stopMicrophone()
        inputContinuation?.finish()
        inputContinuation = nil
        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
        await resultsTask?.value
        resultsTask = nil
        analyzer = nil
        analyzerFormat = nil
        accumulator = TranscriptAccumulator()
    }

    private func startMicrophone(targetFormat: AVAudioFormat) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let naturalFormat = input.outputFormat(forBus: 0)
        guard naturalFormat.sampleRate > 0, naturalFormat.channelCount > 0 else {
            throw EngineError.microphoneUnavailable
        }

        let converter = try AudioBufferConverterBox(source: naturalFormat, target: targetFormat)
        let continuation = inputContinuation
        input.installTap(onBus: 0, bufferSize: 2_048, format: naturalFormat) { buffer, _ in
            guard let converted = converter.convert(buffer) else { return }
            continuation?.yield(AnalyzerInput(buffer: converted))
        }

        engine.prepare()
        try engine.start()
        audioEngine = engine
    }

    private func stopMicrophone() {
        guard let audioEngine else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        self.audioEngine = nil
    }
}

private final class AudioBufferConverterBox: @unchecked Sendable {
    enum ConversionError: LocalizedError {
        case unavailable

        var errorDescription: String? { "The microphone audio format could not be converted for speech recognition." }
    }

    private let converter: AVAudioConverter
    private let target: AVAudioFormat
    private let capacityRatio: Double

    init(source: AVAudioFormat, target: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: source, to: target) else {
            throw ConversionError.unavailable
        }
        self.converter = converter
        self.target = target
        capacityRatio = target.sampleRate / source.sampleRate
    }

    func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * capacityRatio)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return input
        }

        guard conversionError == nil, status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}
