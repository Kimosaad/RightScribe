import AppKit
import Combine
import Foundation
import OSLog

enum MeetingPhase: Equatable {
    case idle
    case suggested(MeetingCandidate)
    case starting(MeetingCandidate)
    case recording(MeetingCandidate, Date)
    case stopping
    case error(String)
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum Phase: Equatable {
        case checking
        case needsSetup(String)
        case preparingModel
        case ready
        case starting
        case listening
        case transcribing
        case cancelling
        case inserting
        case error(String)
    }

    @Published private(set) var phase: Phase = .checking
    @Published private(set) var liveTranscript = ""
    @Published private(set) var permissionStatus = PermissionManager.currentStatus()
    @Published private(set) var transcriptHistory: [TranscriptHistoryItem]
    @Published private(set) var meetingHistory: [MeetingRecord]
    @Published private(set) var meetingPhase: MeetingPhase = .idle
    @Published private(set) var customVocabulary: [String]
    @Published private(set) var googleCalendarConnectionState: GoogleCalendarConnectionState
    @Published private(set) var googleCalendarClientID: String
    @Published var addTrailingSpace: Bool {
        didSet { UserDefaults.standard.set(addTrailingSpace, forKey: Self.trailingSpaceKey) }
    }
    @Published var removeFillerWords: Bool {
        didSet { UserDefaults.standard.set(removeFillerWords, forKey: Self.removeFillersKey) }
    }

    private static let trailingSpaceKey = "RightScribe.addTrailingSpace"
    private static let removeFillersKey = "RightScribe.removeFillerWords"
    private static let customVocabularyKey = "RightScribe.customVocabulary"
    private let logger = Logger(subsystem: "com.karimsaad.rightscribe", category: "App")
    private let speechEngine = AppleSpeechEngine()
    private let injector = TextInjector()
    private let router: any TranscriptRouting = V1TranscriptRouter()
    private let overlay = DictationOverlayController()
    private let meetingDetector = MeetingDetector()
    private let meetingPrompt = MeetingPromptController()
    private let meetingRecorder = MeetingRecorder()
    private let googleCalendarService = GoogleCalendarService()
    private var rightCommandMonitor: RightCommandMonitor?
    private var setupTask: Task<Void, Never>?
    private var permissionWatcherTask: Task<Void, Never>?
    private var sessionTask: Task<Void, Never>?
    private var rearmTask: Task<Void, Never>?
    private var startupWatchdogTask: Task<Void, Never>?
    private var finishingWatchdogTask: Task<Void, Never>?
    private var recordingSafetyTask: Task<Void, Never>?
    private var chordCancelledSession = false
    private var engineSessionStarted = false
    private var finishRequested = false
    private var finishTaskStarted = false
    private var cancelRequested = false
    private var pendingMeetingCandidate: MeetingCandidate?
    private var dismissedMeetingID: String?
    private var meetingCalendarMatchTask: Task<CalendarEventSnapshot?, Never>?

    private init() {
        addTrailingSpace = UserDefaults.standard.object(forKey: Self.trailingSpaceKey) as? Bool ?? true
        removeFillerWords = UserDefaults.standard.object(forKey: Self.removeFillersKey) as? Bool ?? true
        transcriptHistory = TranscriptHistoryPersistence.load()
        meetingHistory = MeetingHistoryPersistence.load()
        customVocabulary = CustomVocabulary.sanitized(
            UserDefaults.standard.stringArray(forKey: Self.customVocabularyKey) ?? []
        )
        let configuredGoogleClientID = GoogleCalendarService.configuredClientID
        googleCalendarClientID = configuredGoogleClientID
        if configuredGoogleClientID.isEmpty {
            googleCalendarConnectionState = .notConfigured
        } else if GoogleCalendarService.hasStoredConnection {
            googleCalendarConnectionState = .connected(nil)
        } else {
            googleCalendarConnectionState = .disconnected
        }
    }

    var isReady: Bool {
        phase == .ready || isSessionActive
    }

    var isSessionActive: Bool {
        switch phase {
        case .starting, .listening, .transcribing, .cancelling, .inserting:
            return true
        default:
            return false
        }
    }

    var statusTitle: String {
        switch phase {
        case .checking: return "Checking setup…"
        case .needsSetup: return "Setup needed"
        case .preparingModel: return "Preparing Apple speech model…"
        case .ready: return "Ready"
        case .starting: return "Starting microphone…"
        case .listening: return "Listening…"
        case .transcribing: return "Finishing transcript…"
        case .cancelling: return "Cancelling…"
        case .inserting: return "Inserting text…"
        case .error: return "RightScribe needs attention"
        }
    }

    var statusDetail: String? {
        switch phase {
        case .needsSetup(let reason), .error(let reason): return reason
        case .ready: return "Your audio and transcript stay on this Mac."
        default: return nil
        }
    }

    var menuBarIcon: String {
        if isMeetingRecording || isMeetingTransitioning { return "record.circle.fill" }
        return phase == .listening ? "waveform.circle.fill" : "waveform.circle"
    }

    var isMeetingRecording: Bool {
        if case .recording = meetingPhase { return true }
        return false
    }

    var isMeetingTransitioning: Bool {
        switch meetingPhase {
        case .starting, .stopping: return true
        default: return false
        }
    }

    var meetingApplicationName: String? {
        switch meetingPhase {
        case .suggested(let candidate), .starting(let candidate), .recording(let candidate, _):
            return candidate.applicationName
        default:
            return nil
        }
    }

    var meetingStartedAt: Date? {
        if case .recording(_, let date) = meetingPhase { return date }
        return nil
    }

    func startup() {
        logger.notice("RightScribe startup")
        startPermissionWatcher()
        refreshSetup()
        refreshGoogleCalendarConnection()
    }

    func shutdown() {
        setupTask?.cancel()
        permissionWatcherTask?.cancel()
        sessionTask?.cancel()
        rearmTask?.cancel()
        startupWatchdogTask?.cancel()
        finishingWatchdogTask?.cancel()
        recordingSafetyTask?.cancel()
        meetingCalendarMatchTask?.cancel()
        rightCommandMonitor?.stop()
        meetingDetector.stop()
        meetingPrompt.hide()
        Task {
            await speechEngine.cancel()
            await meetingRecorder.cancel()
        }
    }

    func refreshSetup() {
        setupTask?.cancel()
        setupTask = Task { [weak self] in
            guard let self else { return }
            phase = .checking
            permissionStatus = PermissionManager.currentStatus()
            logger.notice("Permissions speech=\(permissionStatus.speech, privacy: .public) microphone=\(permissionStatus.microphone, privacy: .public) accessibility=\(permissionStatus.accessibility, privacy: .public)")
            guard permissionStatus.allGranted else {
                phase = .needsSetup(permissionStatus.missingDescription)
                return
            }
            await prepareModelAndMonitor()
        }
    }

    func requestSetup() {
        setupTask?.cancel()
        setupTask = Task { [weak self] in
            guard let self else { return }
            phase = .checking
            await PermissionManager.requestSpeechAndMicrophone()
            _ = await PermissionManager.requestMeetingAudio()
            PermissionManager.requestAccessibility()

            permissionStatus = PermissionManager.currentStatus()
            guard permissionStatus.allGranted else {
                phase = .needsSetup("Finish enabling the requested permissions in Privacy & Security. RightScribe will detect them automatically.")
                return
            }
            await prepareModelAndMonitor()
        }
    }

    func applicationBecameActive() {
        permissionStatus = PermissionManager.currentStatus()
        if case .needsSetup = phase {
            refreshSetup()
        }
    }

    func toggleDictationFromMenu() {
        guard !isMeetingRecording, !isMeetingTransitioning else { return }
        if isSessionActive {
            requestFinish()
        } else if phase == .ready {
            sessionTask = Task { [weak self] in await self?.beginSession() }
        }
    }

    func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    func connectGoogleCalendar(clientID: String) {
        let cleanClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        googleCalendarClientID = cleanClientID
        googleCalendarConnectionState = .connecting
        Task { [weak self] in
            guard let self else { return }
            do {
                let account = try await self.googleCalendarService.connect(clientID: cleanClientID)
                self.googleCalendarClientID = GoogleCalendarService.configuredClientID
                self.googleCalendarConnectionState = .connected(account)
            } catch is CancellationError {
                self.googleCalendarConnectionState = .disconnected
            } catch {
                self.googleCalendarConnectionState = .error(error.localizedDescription)
            }
        }
    }

    func disconnectGoogleCalendar() {
        meetingCalendarMatchTask?.cancel()
        Task { [weak self] in
            guard let self else { return }
            await self.googleCalendarService.disconnect()
            self.googleCalendarConnectionState = .disconnected
        }
    }

    func openGoogleCalendarSetup() {
        guard let url = URL(string: "https://console.cloud.google.com/apis/credentials") else { return }
        NSWorkspace.shared.open(url)
    }

    func openGoogleCalendarAPISetup() {
        guard let url = URL(string: "https://console.cloud.google.com/apis/library/calendar-json.googleapis.com") else { return }
        NSWorkspace.shared.open(url)
    }

    func requestMeetingAudioPermission() {
        Task { [weak self] in
            guard let self else { return }
            _ = await PermissionManager.requestMeetingAudio()
            self.permissionStatus = PermissionManager.currentStatus()
            if !self.permissionStatus.meetingAudioPrepared {
                self.openMeetingAudioSettings()
            }
        }
    }

    func openMeetingAudioSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    func showAbout() {
        let alert = NSAlert()
        alert.messageText = "RightScribe"
        alert.informativeText = "Private on-device dictation for macOS 26. Press Right Command once to start, then press it again to insert the transcript. Press Escape to cancel without pasting. Audio is never stored. Transcript history and custom vocabulary are saved only on this Mac."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func copyHistoryItem(_ item: TranscriptHistoryItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.text, forType: .string)
    }

    func deleteHistoryItems(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            transcriptHistory.remove(at: index)
        }
        persistHistory()
    }

    func deleteHistoryItem(_ item: TranscriptHistoryItem) {
        transcriptHistory.removeAll { $0.id == item.id }
        persistHistory()
    }

    func clearTranscriptHistory() {
        transcriptHistory.removeAll()
        persistHistory()
    }

    func copyMeeting(_ meeting: MeetingRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(meeting.fullTranscript, forType: .string)
    }

    func deleteMeeting(_ meeting: MeetingRecord) {
        meetingHistory.removeAll { $0.id == meeting.id }
        persistMeetingHistory()
    }

    func clearMeetingHistory() {
        meetingHistory.removeAll()
        persistMeetingHistory()
    }

    func endMeetingNotes() {
        guard case .recording = meetingPhase else { return }
        meetingPhase = .stopping
        Task { [weak self] in
            await self?.finishMeetingNotes()
        }
    }

    func addCustomVocabularyEntry(_ entry: String) {
        let updated = CustomVocabulary.adding(entry, to: customVocabulary)
        guard updated != customVocabulary else { return }
        customVocabulary = updated
        persistAndApplyCustomVocabulary()
    }

    func deleteCustomVocabularyEntry(_ entry: String) {
        customVocabulary.removeAll { $0 == entry }
        persistAndApplyCustomVocabulary()
    }

    private func prepareModelAndMonitor() async {
        logger.notice("Preparing local speech model")
        phase = .preparingModel
        overlay.show(mode: .preparing, transcript: "Preparing Apple speech…")
        do {
            try await speechEngine.setCustomVocabulary(customVocabulary)
            try await speechEngine.prepare(locale: Locale(identifier: "en_US"))
            try startRightCommandMonitor()
            phase = .ready
            logger.notice("RightScribe is ready")
            overlay.hide()
            configureAndStartMeetingDetection()
        } catch {
            logger.error("Setup failed: \(error.localizedDescription, privacy: .public)")
            phase = .error(error.localizedDescription)
            overlay.show(mode: .error, transcript: error.localizedDescription)
            overlay.hide(after: 3)
        }
    }

    private func startRightCommandMonitor() throws {
        rightCommandMonitor?.stop()
        let monitor = RightCommandMonitor()
        monitor.onRightCommandDown = { [weak self] in
            self?.handleRightCommandDown() ?? false
        }
        monitor.onRightCommandPressed = { [weak self] in
            self?.handleRightCommandPress()
        }
        monitor.onCommandChord = { [weak self] in
            self?.handleCommandChord()
        }
        monitor.onListenerInterrupted = { [weak self] in
            self?.handleListenerInterrupted()
        }
        monitor.onEscapePressed = { [weak self] in
            self?.handleEscapePress() ?? false
        }
        try monitor.start()
        rightCommandMonitor = monitor
    }

    private func handleRightCommandPress() {
        guard !isMeetingRecording, !isMeetingTransitioning else { return }
        logger.notice("Shortcut received while phase=\(String(describing: self.phase), privacy: .public)")
        chordCancelledSession = false
        if phase == .ready {
            sessionTask = Task { [weak self] in await self?.beginSession() }
        } else if phase == .starting || phase == .listening {
            requestFinish()
        }
    }

    private func handleRightCommandDown() -> Bool {
        if isMeetingRecording || isMeetingTransitioning { return false }
        switch phase {
        case .starting, .listening:
            logger.notice("Right Command key-down requested an immediate stop")
            requestFinish()
            return true
        case .transcribing, .cancelling, .inserting:
            return true
        default:
            return false
        }
    }

    private func handleListenerInterrupted() {
        guard phase == .starting || phase == .listening else { return }
        logger.warning("Keyboard listener was interrupted during dictation; forcing a safe stop")
        requestFinish()
    }

    private func handleEscapePress() -> Bool {
        if isMeetingRecording || isMeetingTransitioning { return false }
        switch phase {
        case .starting, .listening, .transcribing:
            logger.notice("Escape requested an emergency cancel")
            cancelRequested = true
            finishRequested = false
            sessionTask?.cancel()
            phase = .cancelling
            overlay.hide()
            sessionTask = Task { [weak self] in
                await self?.cancelSession()
            }
            return true
        case .cancelling:
            return true
        default:
            return false
        }
    }

    private func handleCommandChord() {
        chordCancelledSession = true
        cancelRequested = true
        if isSessionActive, engineSessionStarted {
            sessionTask = Task { [weak self] in await self?.cancelSession() }
        }
    }

    private func beginSession() async {
        guard phase == .ready else { return }
        engineSessionStarted = false
        finishRequested = false
        finishTaskStarted = false
        cancelRequested = false
        liveTranscript = ""
        phase = .starting
        logger.notice("Dictation startup requested")
        overlay.show(mode: .preparing, transcript: "Starting…")

        startupWatchdogTask?.cancel()
        startupWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, self.phase == .starting else { return }
            self.logger.error("Speech startup timed out; resetting the session")
            self.phase = .error("The speech engine took too long to start. RightScribe reset it automatically; try again.")
            self.overlay.show(mode: .error, transcript: "Speech startup timed out")
            self.overlay.hide(after: 3)
            await self.speechEngine.cancel()
            guard self.phase != .starting else { return }
            self.resetSessionState()
            self.phase = .ready
            self.rearmSpeechEngineInBackground()
        }

        do {
            try await speechEngine.start()
            startupWatchdogTask?.cancel()
            guard phase == .starting else {
                await speechEngine.cancel()
                return
            }
            engineSessionStarted = true
            phase = .listening
            logger.notice("Dictation started")
            overlay.show(mode: .listening, transcript: "Listening…")
            logger.notice("Microphone and speech analyzer started")
            startRecordingSafetyTimer()

            if cancelRequested || chordCancelledSession {
                await cancelSession()
            } else if finishRequested {
                startFinishTaskIfPossible()
            }
        } catch {
            startupWatchdogTask?.cancel()
            guard !Task.isCancelled else { return }
            await recoverFromSessionFailure(error.localizedDescription)
        }
    }

    private func requestFinish() {
        guard phase == .starting || phase == .listening else { return }
        finishRequested = true
        startFinishTaskIfPossible()
    }

    private func startFinishTaskIfPossible() {
        guard phase == .listening, engineSessionStarted, !finishTaskStarted else { return }
        finishTaskStarted = true
        recordingSafetyTask?.cancel()
        phase = .transcribing
        logger.notice("Dictation finishing")
        overlay.show(mode: .processing, transcript: "Finishing…")
        startFinishingWatchdog()
        sessionTask = Task { [weak self] in
            await self?.finishAndRouteSession()
        }
    }

    private func finishAndRouteSession() async {
        guard phase == .transcribing else { return }

        do {
            let rawTranscript = try await speechEngine.stop()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !Task.isCancelled, phase == .transcribing else { return }
            finishingWatchdogTask?.cancel()
            let transcript = removeFillerWords
                ? TranscriptCleaner.removingFillers(from: rawTranscript)
                : rawTranscript
            engineSessionStarted = false
            finishRequested = false
            finishTaskStarted = false

            guard !transcript.isEmpty else {
                logger.notice("Dictation finished with an empty transcript")
                phase = .ready
                overlay.hide()
                rearmSpeechEngineInBackground()
                offerPendingMeetingIfAppropriate()
                return
            }

            let routed = await router.route(transcript)
            guard !Task.isCancelled, phase == .transcribing else { return }
            switch routed {
            case .insertText(let text):
                phase = .inserting
                let targetApplication = NSWorkspace.shared.frontmostApplication?.localizedName
                let insertion = text + (addTrailingSpace ? " " : "")
                try await injector.insert(insertion)
                appendHistory(text: text, applicationName: targetApplication)
            case .actionUnavailable(let explanation):
                throw RightScribeError.actionUnavailable(explanation)
            }

            phase = .ready
            logger.notice("RightScribe is ready")
            liveTranscript = ""
            overlay.show(mode: .success, transcript: "Inserted")
            overlay.hide(after: 0.7)
            rearmSpeechEngineInBackground()
            offerPendingMeetingIfAppropriate()
        } catch {
            finishingWatchdogTask?.cancel()
            guard !Task.isCancelled else { return }
            logger.error("Dictation failed: \(error.localizedDescription, privacy: .public)")
            await recoverFromSessionFailure(error.localizedDescription)
        }
    }

    private func cancelSession() async {
        startupWatchdogTask?.cancel()
        finishingWatchdogTask?.cancel()
        recordingSafetyTask?.cancel()
        await speechEngine.cancel()
        resetSessionState()
        phase = .ready
        overlay.hide()
        rearmSpeechEngineInBackground()
        offerPendingMeetingIfAppropriate()
    }

    private func startRecordingSafetyTimer() {
        recordingSafetyTask?.cancel()
        recordingSafetyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled, let self, self.phase == .listening else { return }
            self.logger.warning("Maximum recording duration reached; forcing a safe stop")
            self.requestFinish()
        }
    }

    private func startFinishingWatchdog() {
        finishingWatchdogTask?.cancel()
        finishingWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, self.phase == .transcribing else { return }
            self.logger.error("Speech finalization timed out; resetting the session")
            self.sessionTask?.cancel()
            self.resetSessionState()
            self.phase = .ready
            self.overlay.show(mode: .error, transcript: "Recording reset safely")
            self.overlay.hide(after: 2)
            await self.speechEngine.cancel()
            self.rearmSpeechEngineInBackground()
        }
    }

    private func recoverFromSessionFailure(_ message: String) async {
        startupWatchdogTask?.cancel()
        finishingWatchdogTask?.cancel()
        recordingSafetyTask?.cancel()
        await speechEngine.cancel()
        resetSessionState()
        phase = .ready
        overlay.show(mode: .error, transcript: message)
        overlay.hide(after: 3)
        rearmSpeechEngineInBackground()
    }

    private func resetSessionState() {
        engineSessionStarted = false
        finishRequested = false
        finishTaskStarted = false
        cancelRequested = false
        liveTranscript = ""
    }

    private func startPermissionWatcher() {
        permissionWatcherTask?.cancel()
        permissionWatcherTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled, let self else { return }
                guard case .needsSetup = self.phase else { continue }

                let latest = PermissionManager.currentStatus()
                self.permissionStatus = latest
                if latest.allGranted {
                    self.refreshSetup()
                }
            }
        }
    }

    private func appendHistory(text: String, applicationName: String?) {
        transcriptHistory.insert(
            TranscriptHistoryItem(
                id: UUID(),
                text: text,
                createdAt: Date(),
                applicationName: applicationName
            ),
            at: 0
        )
        if transcriptHistory.count > 500 {
            transcriptHistory.removeLast(transcriptHistory.count - 500)
        }
        persistHistory()
    }

    private func persistHistory() {
        do {
            try TranscriptHistoryPersistence.save(transcriptHistory)
        } catch {
            logger.error("Could not save transcript history: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistMeetingHistory() {
        do {
            try MeetingHistoryPersistence.save(meetingHistory)
        } catch {
            logger.error("Could not save meeting history: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func configureAndStartMeetingDetection() {
        meetingDetector.onMeetingDetected = { [weak self] candidate in
            self?.handleMeetingDetected(candidate)
        }
        meetingDetector.onMeetingEnded = { [weak self] meetingID in
            self?.handleMeetingEnded(meetingID)
        }
        meetingDetector.start()
    }

    private func handleMeetingDetected(_ candidate: MeetingCandidate) {
        pendingMeetingCandidate = candidate
        guard dismissedMeetingID != candidate.id else { return }
        offerPendingMeetingIfAppropriate()
    }

    private func offerPendingMeetingIfAppropriate() {
        guard phase == .ready,
              case .idle = meetingPhase,
              let candidate = pendingMeetingCandidate,
              dismissedMeetingID != candidate.id else { return }

        meetingPhase = .suggested(candidate)
        meetingPrompt.show(candidate: candidate) { [weak self] in
            self?.beginMeetingNotes(candidate)
        } onDismiss: { [weak self] in
            guard let self else { return }
            self.dismissedMeetingID = candidate.id
            self.meetingPhase = .idle
        }
    }

    private func handleMeetingEnded(_ meetingID: String) {
        if pendingMeetingCandidate?.id == meetingID {
            pendingMeetingCandidate = nil
        }
        if dismissedMeetingID == meetingID {
            dismissedMeetingID = nil
        }
        if case .suggested(let candidate) = meetingPhase, candidate.id == meetingID {
            meetingPrompt.hide()
            meetingPhase = .idle
        }
        if case .recording(let candidate, _) = meetingPhase, candidate.id == meetingID {
            logger.notice("Meeting audio ended; finishing notes automatically")
            endMeetingNotes()
        }
    }

    private func beginMeetingNotes(_ candidate: MeetingCandidate) {
        guard case .suggested(let suggested) = meetingPhase, suggested.id == candidate.id else { return }
        meetingPhase = .starting(candidate)
        dismissedMeetingID = candidate.id
        Task { [weak self] in
            guard let self else { return }
            await self.speechEngine.cancel()
            do {
                try await self.meetingRecorder.start(
                    candidate: candidate,
                    vocabulary: self.customVocabulary
                )
                self.permissionStatus = PermissionManager.currentStatus()
                let meetingStart = Date()
                self.meetingPhase = .recording(candidate, meetingStart)
                self.meetingCalendarMatchTask?.cancel()
                self.meetingCalendarMatchTask = Task {
                    await self.googleCalendarService.matchingEvent(
                        at: meetingStart,
                        meetingFamily: candidate.applicationFamily
                    )
                }
                self.logger.notice("Meeting recording is active")
            } catch {
                self.meetingCalendarMatchTask?.cancel()
                self.meetingCalendarMatchTask = nil
                self.permissionStatus = PermissionManager.currentStatus()
                self.meetingPhase = .error(error.localizedDescription)
                self.showMeetingError(error.localizedDescription)
                self.meetingPhase = .idle
                self.rearmSpeechEngineInBackground()
            }
        }
    }

    private func finishMeetingNotes() async {
        do {
            let calendarEvent = await meetingCalendarMatchTask?.value
            meetingCalendarMatchTask = nil
            meetingRecorder.setCalendarEvent(calendarEvent)
            if let meeting = try await meetingRecorder.stop() {
                meetingHistory.insert(meeting, at: 0)
                if meetingHistory.count > 200 {
                    meetingHistory.removeLast(meetingHistory.count - 200)
                }
                persistMeetingHistory()
            }
        } catch {
            logger.error("Could not finish meeting notes: \(error.localizedDescription, privacy: .public)")
            showMeetingError(error.localizedDescription)
        }
        meetingPhase = .idle
        pendingMeetingCandidate = nil
        rearmSpeechEngineInBackground()
    }

    private func refreshGoogleCalendarConnection() {
        guard GoogleCalendarService.hasStoredConnection else { return }
        Task { [weak self] in
            guard let self else { return }
            let account = await self.googleCalendarService.connectedAccountIdentifier()
            guard GoogleCalendarService.hasStoredConnection else { return }
            self.googleCalendarConnectionState = .connected(account)
        }
    }

    private func showMeetingError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Meeting notes couldn't start"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if !permissionStatus.meetingAudioPrepared {
            alert.addButton(withTitle: "Open Settings")
        }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            openMeetingAudioSettings()
        }
    }

    private func persistAndApplyCustomVocabulary() {
        UserDefaults.standard.set(customVocabulary, forKey: Self.customVocabularyKey)
        let entries = customVocabulary
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.speechEngine.setCustomVocabulary(entries)
                self.logger.notice("Updated custom vocabulary with \(entries.count, privacy: .public) entries")
            } catch {
                self.logger.error("Could not update custom vocabulary: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func rearmSpeechEngineInBackground() {
        rearmTask?.cancel()
        let engine = speechEngine
        rearmTask = Task {
            do {
                try await engine.rearm()
                logger.debug("Speech analyzer rearmed")
            } catch is CancellationError {
                return
            } catch {
                logger.error("Background speech rearm failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

enum RightScribeError: LocalizedError {
    case actionUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .actionUnavailable(let explanation): return explanation
        }
    }
}
