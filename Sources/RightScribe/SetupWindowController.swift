import AppKit
import SwiftUI

enum RightScribeWindowTab: Hashable {
    case recent
    case meetings
    case history
    case settings
}

@MainActor
fileprivate final class RightScribeWindowModel: ObservableObject {
    @Published var selectedTab: RightScribeWindowTab = .recent
}

@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let windowModel = RightScribeWindowModel()
    private let onContinueInMenuBar: () -> Void

    init(appModel: AppModel, onContinueInMenuBar: @escaping () -> Void) {
        self.onContinueInMenuBar = onContinueInMenuBar

        let rootView = RightScribeHomeView(
            appModel: appModel,
            windowModel: windowModel,
            onContinueInMenuBar: onContinueInMenuBar
        )
        let hostingController = NSHostingController(rootView: rootView)
        window = NSWindow(contentViewController: hostingController)
        super.init()

        window.title = "RightScribe"
        window.setContentSize(NSSize(width: 820, height: 640))
        window.minSize = NSSize(width: 720, height: 560)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false
    }

    func show(tab: RightScribeWindowTab = .recent) {
        windowModel.selectedTab = tab
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func hide() {
        window.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onContinueInMenuBar()
        return false
    }
}

private struct RightScribeHomeView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject fileprivate var windowModel: RightScribeWindowModel
    let onContinueInMenuBar: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 560)
        .background(Color.rsCream)
        .preferredColorScheme(.light)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(Color.rsTerracotta)
                Text("RightScribe")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.rsInk)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 20)

            navigationButton("Recent", icon: "sparkles", tab: .recent)
            navigationButton("Meetings", icon: "person.2.wave.2", tab: .meetings)
            navigationButton("History", icon: "clock.arrow.circlepath", tab: .history)
            navigationButton("Settings", icon: "slider.horizontal.3", tab: .settings)

            Spacer()

            Button {
                onContinueInMenuBar()
            } label: {
                Label("Continue in Menu Bar", systemImage: "menubar.rectangle")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.rsMuted)
            .padding(12)
            .background(Color.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(18)
        .frame(width: 224)
        .background(Color.rsSidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.rsBorder).frame(width: 1)
        }
    }

    private var content: some View {
        Group {
            switch windowModel.selectedTab {
            case .recent:
                RecentTranscriptsView(appModel: appModel, selectedTab: $windowModel.selectedTab)
            case .meetings:
                MeetingHistoryView(appModel: appModel)
            case .history:
                TranscriptHistoryView(appModel: appModel)
            case .settings:
                RightScribeSettingsView(appModel: appModel)
            }
        }
        .background(Color.rsCream)
    }

    private func navigationButton(_ title: String, icon: String, tab: RightScribeWindowTab) -> some View {
        Button {
            windowModel.selectedTab = tab
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .foregroundStyle(windowModel.selectedTab == tab ? Color.rsInk : Color.rsMuted)
                .background(
                    windowModel.selectedTab == tab ? Color.white.opacity(0.72) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 11)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct RecentTranscriptsView: View {
    @ObservedObject var appModel: AppModel
    @Binding var selectedTab: RightScribeWindowTab

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(greeting)
                        .font(.system(size: 31, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.rsInk)
                    Text("Your thoughts, captured without leaving the keyboard.")
                        .font(.system(size: 15, design: .rounded))
                        .foregroundStyle(Color.rsMuted)
                }

                readyCard

                HStack(alignment: .firstTextBaseline) {
                    Text("Recent transcripts")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.rsInk)
                    Spacer()
                    if appModel.transcriptHistory.count > 6 {
                        Button("View all") { selectedTab = .history }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.rsTerracotta)
                    }
                }

                if appModel.transcriptHistory.isEmpty {
                    EmptyTranscriptCard()
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(appModel.transcriptHistory.prefix(6)) { item in
                            TranscriptCard(item: item) {
                                appModel.copyHistoryItem(item)
                            } onDelete: {
                                appModel.deleteHistoryItem(item)
                            }
                        }
                    }
                }
            }
            .padding(34)
        }
    }

    private var readyCard: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle().fill(Color.rsTerracotta.opacity(0.13))
                Image(systemName: appModel.phase == .listening ? "waveform" : "command")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(Color.rsTerracotta)
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 5) {
                Text(appModel.phase == .ready ? "Ready when you are" : appModel.statusTitle)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.rsInk)
                Text(appModel.permissionStatus.allGranted
                     ? "Press right Command once to start, then again to paste. Escape cancels."
                     : "Finish setup in Settings to begin dictating.")
                    .foregroundStyle(Color.rsMuted)
            }
            Spacer()
            Circle()
                .fill(appModel.phase == .ready ? Color.rsSage : Color.rsTerracotta)
                .frame(width: 9, height: 9)
        }
        .padding(20)
        .background(Color.rsCard, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.rsBorder, lineWidth: 1))
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }
}

private struct MeetingHistoryView: View {
    @ObservedObject var appModel: AppModel
    @State private var searchText = ""
    @State private var confirmClear = false
    @State private var confirmEndRecording = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                PageHeader("Meeting notes", subtitle: "Private transcripts from your calls, saved only on this Mac.")
                Spacer()
                if !appModel.meetingHistory.isEmpty {
                    Button("Clear all", role: .destructive) { confirmClear = true }
                }
            }

            meetingStatusCard

            TextField("Search meetings", text: $searchText)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.rsCard, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.rsBorder))

            if filteredMeetings.isEmpty {
                EmptyMeetingCard(message: searchText.isEmpty
                    ? "When a call starts, RightScribe will ask before recording anything."
                    : "No meeting notes match your search.")
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 13) {
                        ForEach(filteredMeetings) { meeting in
                            MeetingCard(meeting: meeting) {
                                appModel.copyMeeting(meeting)
                            } onDelete: {
                                appModel.deleteMeeting(meeting)
                            }
                        }
                    }
                }
            }
        }
        .padding(34)
        .confirmationDialog("End this meeting recording?", isPresented: $confirmEndRecording) {
            Button("End and Save Notes") { appModel.endMeetingNotes() }
            Button("Keep Recording", role: .cancel) {}
        } message: {
            Text("RightScribe will finish the transcript and save it in Meeting Notes.")
        }
        .confirmationDialog("Clear all meeting notes?", isPresented: $confirmClear) {
            Button("Clear All", role: .destructive) { appModel.clearMeetingHistory() }
        } message: {
            Text("This permanently removes every saved meeting transcript from this Mac.")
        }
    }

    @ViewBuilder
    private var meetingStatusCard: some View {
        switch appModel.meetingPhase {
        case .recording(_, let startedAt):
            HStack(spacing: 14) {
                Circle()
                    .fill(Color.red.opacity(0.86))
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Recording \(appModel.meetingApplicationName ?? "meeting")")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.rsInk)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Started \(startedAt.formatted(date: .omitted, time: .shortened)) · \(durationText(context.date.timeIntervalSince(startedAt)))")
                            .font(.caption)
                            .foregroundStyle(Color.rsMuted)
                    }
                }
                Spacer()
                Button("End Recording") { confirmEndRecording = true }
                    .buttonStyle(.bordered)
            }
            .padding(16)
            .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.red.opacity(0.18)))
        case .starting:
            Label("Starting private meeting notes…", systemImage: "record.circle")
                .foregroundStyle(Color.rsTerracotta)
                .padding(15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.rsCard, in: RoundedRectangle(cornerRadius: 15))
        case .stopping:
            Label("Finishing and saving the transcript…", systemImage: "ellipsis.circle")
                .foregroundStyle(Color.rsTerracotta)
                .padding(15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.rsCard, in: RoundedRectangle(cornerRadius: 15))
        default:
            EmptyView()
        }
    }

    private var filteredMeetings: [MeetingRecord] {
        guard !searchText.isEmpty else { return appModel.meetingHistory }
        return appModel.meetingHistory.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.sourceApplication.localizedCaseInsensitiveContains(searchText)
                || $0.fullTranscript.localizedCaseInsensitiveContains(searchText)
                || ($0.calendarEvent?.organizerEmail?.localizedCaseInsensitiveContains(searchText) ?? false)
                || ($0.calendarEvent?.attendees.contains {
                    $0.displayName.localizedCaseInsensitiveContains(searchText)
                        || $0.email.localizedCaseInsensitiveContains(searchText)
                } ?? false)
        }
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct MeetingCard: View {
    let meeting: MeetingRecord
    let onCopy: () -> Void
    let onDelete: () -> Void
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                Image(systemName: "person.2.fill")
                    .foregroundStyle(Color.rsTerracotta)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.rsInk)
                    Text("\(meeting.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(durationText(meeting.duration))")
                        .font(.caption)
                        .foregroundStyle(Color.rsMuted)
                }
                Spacer()
                Button(action: onCopy) { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain)
                    .help("Copy meeting transcript")
                Button(action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.plain)
                    .help("Delete meeting notes")
                Button { isExpanded.toggle() } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse" : "Show full transcript")
            }

            if let event = meeting.calendarEvent {
                HStack(spacing: 12) {
                    Label("Google Calendar", systemImage: "calendar")
                    if !event.attendees.isEmpty {
                        Label(
                            "\(event.attendees.filter { !$0.isSelf }.count) attendee\(event.attendees.filter { !$0.isSelf }.count == 1 ? "" : "s")",
                            systemImage: "person.2"
                        )
                    }
                    if let meetingURL = event.meetingURL,
                       let url = URL(string: meetingURL) {
                        Link("Meeting link", destination: url)
                    }
                }
                .font(.caption)
                .foregroundStyle(Color.rsMuted)

                if isExpanded, !event.attendees.isEmpty {
                    let visibleAttendees = event.attendees.filter { !$0.isSelf }
                    if !visibleAttendees.isEmpty {
                        Text(visibleAttendees.map(\.displayName).joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(Color.rsMuted)
                            .textSelection(.enabled)
                    }
                }
            }

            if meeting.turns.isEmpty {
                Text("No speech was recognized during this recording.")
                    .font(.callout)
                    .foregroundStyle(Color.rsMuted)
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(isExpanded ? meeting.turns : Array(meeting.turns.prefix(3))) { turn in
                        HStack(alignment: .top, spacing: 10) {
                            Text(turn.speaker.displayName)
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(turn.speaker == .you ? Color.rsTerracotta : Color.rsSage)
                                .frame(width: 58, alignment: .leading)
                            Text(turn.text)
                                .font(.system(size: 13, design: .rounded))
                                .foregroundStyle(Color.rsInk)
                                .lineLimit(isExpanded ? nil : 2)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                if !isExpanded, meeting.turns.count > 3 {
                    Button("Show \(meeting.turns.count - 3) more turns") { isExpanded = true }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Color.rsTerracotta)
                }
            }
        }
        .padding(17)
        .background(Color.rsCard, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.rsBorder))
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let totalMinutes = max(1, Int(ceil(duration / 60)))
        if totalMinutes < 60 { return "\(totalMinutes) min" }
        return "\(totalMinutes / 60) hr \(totalMinutes % 60) min"
    }
}

private struct EmptyMeetingCard: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2.wave.2")
                .font(.system(size: 29))
                .foregroundStyle(Color.rsTerracotta.opacity(0.7))
            Text("Your meetings, remembered")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(Color.rsInk)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.rsMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(Color.rsCard.opacity(0.75), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.rsBorder, style: StrokeStyle(lineWidth: 1, dash: [5])))
    }
}

private struct TranscriptHistoryView: View {
    @ObservedObject var appModel: AppModel
    @State private var searchText = ""
    @State private var confirmClearHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Transcript history")
                        .font(.system(size: 29, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.rsInk)
                    Text("Saved privately on this Mac. Audio is never stored.")
                        .foregroundStyle(Color.rsMuted)
                }
                Spacer()
                if !appModel.transcriptHistory.isEmpty {
                    Button("Clear all", role: .destructive) { confirmClearHistory = true }
                }
            }

            TextField("Search transcripts", text: $searchText)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.rsCard, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.rsBorder))

            if filteredItems.isEmpty {
                EmptyTranscriptCard(message: searchText.isEmpty ? "Your pasted dictations will collect here." : "No transcripts match your search.")
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(filteredItems) { item in
                            TranscriptCard(item: item) {
                                appModel.copyHistoryItem(item)
                            } onDelete: {
                                appModel.deleteHistoryItem(item)
                            }
                        }
                    }
                }
            }
        }
        .padding(34)
        .confirmationDialog("Clear all transcript history?", isPresented: $confirmClearHistory) {
            Button("Clear All", role: .destructive) { appModel.clearTranscriptHistory() }
        } message: {
            Text("This permanently removes every saved transcript from this Mac.")
        }
    }

    private var filteredItems: [TranscriptHistoryItem] {
        guard !searchText.isEmpty else { return appModel.transcriptHistory }
        return appModel.transcriptHistory.filter {
            $0.text.localizedCaseInsensitiveContains(searchText)
            || ($0.applicationName?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }
}

private struct RightScribeSettingsView: View {
    @ObservedObject var appModel: AppModel
    @State private var vocabularyEntry = ""
    @State private var googleClientID = GoogleCalendarService.configuredClientID

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader("Settings", subtitle: "Make RightScribe work the way you think.")

                SettingsCard(title: "Writing", icon: "text.cursor") {
                    Toggle("Remove filler words", isOn: $appModel.removeFillerWords)
                    Divider()
                    Toggle("Add a space after dictation", isOn: $appModel.addTrailingSpace)
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Emergency cancel")
                            Text("Discard the current recording without pasting.")
                                .font(.caption)
                                .foregroundStyle(Color.rsMuted)
                        }
                        Spacer()
                        Text("esc")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Color.rsSidebar, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.rsBorder))
                    }
                }

                SettingsCard(title: "Google Calendar", icon: "calendar.badge.checkmark") {
                    Text("Connect RightScribe directly to Google Calendar so saved meeting notes can use the event title and attendee list. Access is read-only; Apple Calendar is not used.")
                        .font(.callout)
                        .foregroundStyle(Color.rsMuted)

                    switch appModel.googleCalendarConnectionState {
                    case .connected(let account):
                        HStack {
                            Label("Connected", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(Color.rsSage)
                            if let account, !account.isEmpty {
                                Text(account)
                                    .foregroundStyle(Color.rsMuted)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Button("Disconnect") { appModel.disconnectGoogleCalendar() }
                        }
                    case .connecting:
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Waiting for Google sign-in…")
                                .foregroundStyle(Color.rsMuted)
                        }
                    case .error(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(Color.rsTerracotta)
                        googleConnectionControls
                    case .notConfigured, .disconnected:
                        googleConnectionControls
                    }
                }

                SettingsCard(title: "Custom vocabulary", icon: "text.badge.plus") {
                    Text("Add names and specialized terms you want Apple Speech to recognize. Short entries of one or two words work best.")
                        .font(.callout)
                        .foregroundStyle(Color.rsMuted)

                    HStack(spacing: 10) {
                        TextField("For example, Canary Quinn", text: $vocabularyEntry)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(Color.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.rsBorder))
                            .onSubmit(addVocabularyEntry)
                        Button("Add", action: addVocabularyEntry)
                            .buttonStyle(.borderedProminent)
                            .tint(Color.rsTerracotta)
                            .disabled(
                                CustomVocabulary.normalizedEntry(vocabularyEntry) == nil
                                || appModel.customVocabulary.count >= CustomVocabulary.maximumEntryCount
                            )
                    }

                    if appModel.customVocabulary.isEmpty {
                        Text("No custom terms yet.")
                            .font(.caption)
                            .foregroundStyle(Color.rsMuted)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(appModel.customVocabulary, id: \.self) { entry in
                                HStack {
                                    Text(entry)
                                        .textSelection(.enabled)
                                    Spacer()
                                    Button {
                                        appModel.deleteCustomVocabularyEntry(entry)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Color.rsMuted)
                                    .help("Remove \(entry)")
                                }
                                .padding(.vertical, 8)
                                if entry != appModel.customVocabulary.last {
                                    Divider()
                                }
                            }
                        }
                    }

                    Text("\(appModel.customVocabulary.count) of \(CustomVocabulary.maximumEntryCount) terms")
                        .font(.caption)
                        .foregroundStyle(Color.rsMuted)
                }

                SettingsCard(title: "Permissions", icon: "checkmark.shield") {
                    permissionRow("Speech Recognition", granted: appModel.permissionStatus.speech)
                    Divider()
                    permissionRow("Microphone", granted: appModel.permissionStatus.microphone)
                    Divider()
                    permissionRow("Accessibility", granted: appModel.permissionStatus.accessibility)
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Meeting Audio")
                            Text("Audio-only access for attendees. RightScribe never shares your screen.")
                                .font(.caption)
                                .foregroundStyle(Color.rsMuted)
                        }
                        Spacer()
                        Label(
                            appModel.permissionStatus.meetingAudioPrepared ? "Prepared" : "Set Up",
                            systemImage: appModel.permissionStatus.meetingAudioPrepared ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                        )
                        .foregroundStyle(appModel.permissionStatus.meetingAudioPrepared ? Color.rsSage : Color.rsTerracotta)
                    }

                    HStack {
                        Button("Set Up Permissions") { appModel.requestSetup() }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.rsTerracotta)
                        Button("Check Again") { appModel.refreshSetup() }
                        Button("Open Privacy & Security") { appModel.openPrivacySettings() }
                    }
                    .padding(.top, 8)

                    if !appModel.permissionStatus.meetingAudioPrepared {
                        Button("Prepare Meeting Audio") { appModel.requestMeetingAudioPermission() }
                    }
                }

                SettingsCard(title: "Privacy", icon: "lock") {
                    Text("Audio is processed on-device and never saved. Dictations, meeting transcripts, and calendar details attached to a meeting stay in RightScribe's local application data on this Mac. Google Calendar access is read-only and its token is protected in Keychain. Meeting capture is audio-only and starts only after you explicitly approve the prompt.")
                        .foregroundStyle(Color.rsMuted)
                }
            }
            .padding(34)
        }
    }

    private func permissionRow(_ title: String, granted: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Label(granted ? "Allowed" : "Needed", systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? Color.rsSage : Color.rsTerracotta)
        }
    }

    @ViewBuilder
    private var googleConnectionControls: some View {
        TextField("Google OAuth client ID", text: $googleClientID)
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.rsBorder))

        HStack {
            Button("Connect Google Calendar") {
                appModel.connectGoogleCalendar(clientID: googleClientID)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.rsTerracotta)
            .disabled(!googleClientID.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(".apps.googleusercontent.com"))

        }

        HStack {
            Button("1. Enable Calendar API") { appModel.openGoogleCalendarAPISetup() }
            Button("2. Create Desktop Client ID") { appModel.openGoogleCalendarSetup() }
        }

        Text("This one-time Google setup creates RightScribe's direct connection. Paste the Desktop app client ID above; sign-in then opens in your browser.")
            .font(.caption)
            .foregroundStyle(Color.rsMuted)
    }

    private func addVocabularyEntry() {
        guard CustomVocabulary.normalizedEntry(vocabularyEntry) != nil else { return }
        appModel.addCustomVocabularyEntry(vocabularyEntry)
        vocabularyEntry = ""
    }
}

private struct TranscriptCard: View {
    let item: TranscriptHistoryItem
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "text.quote")
                    .foregroundStyle(Color.rsTerracotta)
                if let applicationName = item.applicationName {
                    Text(applicationName).fontWeight(.semibold)
                }
                Text("•")
                Text(item.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                Spacer()
                Button(action: onCopy) { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain).help("Copy transcript")
                Button(action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.plain).help("Delete transcript")
            }
            .font(.caption)
            .foregroundStyle(Color.rsMuted)

            Text(item.text)
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(Color.rsInk)
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(17)
        .background(Color.rsCard, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.rsBorder))
    }
}

private struct EmptyTranscriptCard: View {
    var message = "Your first pasted dictation will appear here."

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.quote")
                .font(.system(size: 28))
                .foregroundStyle(Color.rsTerracotta.opacity(0.7))
            Text("A quiet place for your words")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(Color.rsInk)
            Text(message).foregroundStyle(Color.rsMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 38)
        .background(Color.rsCard.opacity(0.75), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.rsBorder, style: StrokeStyle(lineWidth: 1, dash: [5])))
    }
}

private struct PageHeader: View {
    let title: String
    let subtitle: String

    init(_ title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 29, weight: .bold, design: .rounded))
                .foregroundStyle(Color.rsInk)
            Text(subtitle).foregroundStyle(Color.rsMuted)
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(Color.rsInk)
            content
        }
        .padding(19)
        .background(Color.rsCard, in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(Color.rsBorder))
    }
}

private extension Color {
    static let rsCream = Color(red: 0.969, green: 0.949, blue: 0.906)
    static let rsSidebar = Color(red: 0.941, green: 0.909, blue: 0.847)
    static let rsCard = Color(red: 1.0, green: 0.992, blue: 0.969)
    static let rsInk = Color(red: 0.235, green: 0.196, blue: 0.153)
    static let rsMuted = Color(red: 0.42, green: 0.38, blue: 0.33)
    static let rsTerracotta = Color(red: 0.70, green: 0.36, blue: 0.24)
    static let rsSage = Color(red: 0.36, green: 0.50, blue: 0.37)
    static let rsBorder = Color(red: 0.73, green: 0.66, blue: 0.55).opacity(0.24)
}
