import AVFoundation
import CoreMedia
import Foundation
import OSLog
import Speech

@MainActor
final class MeetingRecorder {
    enum RecorderError: LocalizedError {
        case sourceApplicationUnavailable
        case unsupportedLocale
        case audioFormatUnavailable

        var errorDescription: String? {
            switch self {
            case .sourceApplicationUnavailable:
                return "The meeting app is no longer available to capture."
            case .unsupportedLocale:
                return "Apple's English speech model is unavailable for meeting notes."
            case .audioFormatUnavailable:
                return "RightScribe could not prepare a compatible meeting audio format."
            }
        }
    }

    private let logger = Logger(subsystem: "com.karimsaad.rightscribe", category: "MeetingRecording")
    private var processTap: ProcessAudioTapCapture?
    private var microphoneCapture: MeetingMicrophoneCapture?
    private var youChannel: MeetingSpeechChannel?
    private var attendeeChannel: MeetingSpeechChannel?
    private var candidate: MeetingCandidate?
    private var startedAt: Date?
    private var calendarEvent: CalendarEventSnapshot?

    func start(candidate: MeetingCandidate, vocabulary: [String]) async throws {
        guard processTap == nil else { return }
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: "en_US")
        ) else {
            throw RecorderError.unsupportedLocale
        }

        let youChannel = MeetingSpeechChannel(speaker: .you)
        let attendeeChannel = MeetingSpeechChannel(speaker: .attendee)
        let youBridge = try await youChannel.start(locale: locale, vocabulary: vocabulary)
        let attendeeBridge = try await attendeeChannel.start(locale: locale, vocabulary: vocabulary)

        do {
            let processObjectIDs = AudioProcessInspector.audioProcessObjectIDs(
                forFamily: candidate.applicationFamily
            )
            guard !processObjectIDs.isEmpty else {
                throw RecorderError.sourceApplicationUnavailable
            }

            let processTap = ProcessAudioTapCapture()
            try processTap.start(processObjectIDs: processObjectIDs, bridge: attendeeBridge)
            let microphoneCapture = MeetingMicrophoneCapture()
            try microphoneCapture.start(bridge: youBridge)

            self.youChannel = youChannel
            self.attendeeChannel = attendeeChannel
            self.processTap = processTap
            self.microphoneCapture = microphoneCapture
            self.candidate = candidate
            startedAt = Date()
            logger.notice("Meeting notes started for \(candidate.applicationName, privacy: .public)")
        } catch {
            processTap?.stop()
            microphoneCapture?.stop()
            await youChannel.cancel()
            await attendeeChannel.cancel()
            throw error
        }
    }

    func setCalendarEvent(_ event: CalendarEventSnapshot?) {
        calendarEvent = event
    }

    func stop() async throws -> MeetingRecord? {
        guard processTap != nil, let candidate, let startedAt else { return nil }
        processTap?.stop()
        microphoneCapture?.stop()
        processTap = nil
        microphoneCapture = nil

        async let youTurns = youChannel?.finish() ?? []
        async let attendeeTurns = attendeeChannel?.finish() ?? []
        let turns = MeetingTranscriptMerger.merged((await youTurns) + (await attendeeTurns))
        let endedAt = Date()
        let record = MeetingRecord(
            id: UUID(),
            title: calendarEvent?.title ?? "Meeting in \(candidate.applicationName)",
            sourceApplication: candidate.applicationName,
            startedAt: startedAt,
            endedAt: endedAt,
            turns: turns,
            calendarEvent: calendarEvent
        )
        reset()
        logger.notice("Meeting notes finished with \(turns.count, privacy: .public) transcript turns")
        return record
    }

    func cancel() async {
        processTap?.stop()
        microphoneCapture?.stop()
        await youChannel?.cancel()
        await attendeeChannel?.cancel()
        reset()
    }

    private func reset() {
        processTap = nil
        microphoneCapture = nil
        youChannel = nil
        attendeeChannel = nil
        candidate = nil
        startedAt = nil
        calendarEvent = nil
    }
}

enum MeetingTranscriptMerger {
    static func merged(_ turns: [MeetingTranscriptTurn]) -> [MeetingTranscriptTurn] {
        let sorted = turns
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted {
                if $0.startedAt == $1.startedAt { return $0.id.uuidString < $1.id.uuidString }
                return $0.startedAt < $1.startedAt
            }

        var result: [MeetingTranscriptTurn] = []
        for turn in sorted {
            let cleanText = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let previous = result.last,
               previous.speaker == turn.speaker,
               turn.startedAt - previous.startedAt < 12 {
                result[result.count - 1] = MeetingTranscriptTurn(
                    id: previous.id,
                    speaker: previous.speaker,
                    text: previous.text + " " + cleanText,
                    startedAt: previous.startedAt
                )
            } else {
                result.append(MeetingTranscriptTurn(
                    id: turn.id,
                    speaker: turn.speaker,
                    text: cleanText,
                    startedAt: turn.startedAt
                ))
            }
        }
        return result
    }
}

private actor MeetingTurnStore {
    private var turns: [MeetingTranscriptTurn] = []

    func append(speaker: MeetingSpeaker, text: String, startedAt: TimeInterval) {
        turns.append(MeetingTranscriptTurn(
            id: UUID(),
            speaker: speaker,
            text: text,
            startedAt: startedAt
        ))
    }

    func all() -> [MeetingTranscriptTurn] { turns }
}

@MainActor
private final class MeetingSpeechChannel {
    private let speaker: MeetingSpeaker
    private let store = MeetingTurnStore()
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    init(speaker: MeetingSpeaker) {
        self.speaker = speaker
    }

    func start(locale: Locale, vocabulary: [String]) async throws -> MeetingAudioBridge {
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
        )
        let context = AnalysisContext()
        let terms = CustomVocabulary.sanitized(vocabulary)
        if !terms.isEmpty {
            context.contextualStrings = [.general: terms]
        }
        try await analyzer.setContext(context)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw MeetingRecorder.RecorderError.audioFormatUnavailable
        }
        try await analyzer.prepareToAnalyze(in: format)

        let pair = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(256))
        continuation = pair.continuation
        self.analyzer = analyzer
        let speaker = speaker
        let store = store
        resultsTask = Task {
            do {
                for try await result in transcriber.results where result.isFinal {
                    let text = String(result.text.characters)
                    let start = CMTimeGetSeconds(result.range.start)
                    await store.append(
                        speaker: speaker,
                        text: text,
                        startedAt: start.isFinite ? start : 0
                    )
                }
            } catch {
                // Finalization reports actionable failures through the recorder.
            }
        }
        try await analyzer.start(inputSequence: pair.stream)
        return MeetingAudioBridge(targetFormat: format, continuation: pair.continuation)
    }

    func finish() async -> [MeetingTranscriptTurn] {
        continuation?.finish()
        continuation = nil
        if let analyzer {
            let finalized = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    do {
                        try await analyzer.finalizeAndFinishThroughEndOfInput()
                        return true
                    } catch {
                        return true
                    }
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(12))
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                if !first {
                    await analyzer.cancelAndFinishNow()
                }
                return first
            }
            if !finalized {
                resultsTask?.cancel()
            }
        }
        await resultsTask?.value
        resultsTask = nil
        analyzer = nil
        return await store.all()
    }

    func cancel() async {
        continuation?.finish()
        continuation = nil
        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
        await resultsTask?.value
        resultsTask = nil
        analyzer = nil
    }
}

final class MeetingAudioBridge: @unchecked Sendable {
    private let targetFormat: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var sourceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    init(
        targetFormat: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) {
        self.targetFormat = targetFormat
        self.continuation = continuation
    }

    func consume(_ input: AVAudioPCMBuffer) {
        if sourceFormat != input.format || converter == nil {
            sourceFormat = input.format
            converter = AVAudioConverter(from: input.format, to: targetFormat)
        }
        guard let converted = convert(input) else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    func consume(_ bufferList: UnsafePointer<AudioBufferList>, format: AVAudioFormat) {
        guard let input = AVAudioPCMBuffer(
            pcmFormat: format,
            bufferListNoCopy: bufferList,
            deallocator: nil
        ) else { return }
        consume(input)
    }

    private func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return nil }
        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard error == nil, status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}
