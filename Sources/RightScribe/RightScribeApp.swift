import AppKit
import Combine
import SwiftUI

@main
struct RightScribeApp: App {
    @NSApplicationDelegateAdaptor(RightScribeAppDelegate.self) private var appDelegate
    @StateObject private var appModel = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            RightScribeMenu(appModel: appModel)
        } label: {
            Label("RightScribe", systemImage: appModel.menuBarIcon)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class RightScribeAppDelegate: NSObject, NSApplicationDelegate {
    private static let menuBarModeKey = "RightScribe.preferMenuBarMode"
    private var setupWindowController: SetupWindowController?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        let controller = SetupWindowController(appModel: AppModel.shared) { [weak self] in
            self?.enterMenuBarMode()
        }
        setupWindowController = controller
        let storedPreference = UserDefaults.standard.object(forKey: Self.menuBarModeKey) as? Bool
        let shouldStartInMenuBar = storedPreference
            ?? PermissionManager.currentStatus().allGranted
        if shouldStartInMenuBar {
            enterMenuBarMode()
        } else {
            controller.show()
        }

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { _ in AppModel.shared.applicationBecameActive() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .rightScribeShowWindow)
            .sink { [weak self] _ in self?.showControlWindow() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .rightScribeShowHistory)
            .sink { [weak self] _ in self?.showHistoryWindow() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .rightScribeShowMeetings)
            .sink { [weak self] _ in self?.showMeetingsWindow() }
            .store(in: &cancellables)

        AppModel.shared.startup()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControlWindow()
        return true
    }

    private func showControlWindow() {
        NSApp.setActivationPolicy(.regular)
        setupWindowController?.show()
    }

    private func showHistoryWindow() {
        NSApp.setActivationPolicy(.regular)
        setupWindowController?.show(tab: .history)
    }

    private func showMeetingsWindow() {
        NSApp.setActivationPolicy(.regular)
        setupWindowController?.show(tab: .meetings)
    }

    private func enterMenuBarMode() {
        UserDefaults.standard.set(true, forKey: Self.menuBarModeKey)
        setupWindowController?.hide()
        NSApp.setActivationPolicy(.accessory)
        NSApp.hide(nil)
    }
}

private struct RightScribeMenu: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        Text(appModel.statusTitle)

        if let detail = appModel.statusDetail, !detail.isEmpty {
            Text(detail)
        }

        Divider()

        if appModel.isMeetingRecording {
            Text("Recording \(appModel.meetingApplicationName ?? "meeting")")
            Button("End Meeting Recording") {
                appModel.endMeetingNotes()
            }
        } else if appModel.isMeetingTransitioning {
            Text(appModel.meetingPhase == .stopping ? "Saving meeting notes…" : "Starting meeting notes…")
        } else if appModel.isReady {
            Text("Press Right Command to start or finish")
            Button(appModel.isSessionActive ? "Finish Dictation" : "Start Dictation") {
                appModel.toggleDictationFromMenu()
            }
            .keyboardShortcut("d")
        } else {
            Button("Set Up Permissions & Model") {
                appModel.requestSetup()
            }
            Button("Refresh Permission Status") {
                appModel.refreshSetup()
            }
            Button("Open Privacy & Security") {
                appModel.openPrivacySettings()
            }
        }

        Divider()

        Toggle("Add a space after dictation", isOn: $appModel.addTrailingSpace)
        Toggle("Remove filler words", isOn: $appModel.removeFillerWords)

        Button("Transcript History") {
            NotificationCenter.default.post(name: .rightScribeShowHistory, object: nil)
        }

        Button("Meeting Notes") {
            NotificationCenter.default.post(name: .rightScribeShowMeetings, object: nil)
        }

        Button("Open RightScribe Window") {
            NotificationCenter.default.post(name: .rightScribeShowWindow, object: nil)
        }

        Button("About RightScribe") {
            appModel.showAbout()
        }

        Button("Quit RightScribe") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

extension Notification.Name {
    static let rightScribeShowWindow = Notification.Name("RightScribe.showWindow")
    static let rightScribeShowHistory = Notification.Name("RightScribe.showHistory")
    static let rightScribeShowMeetings = Notification.Name("RightScribe.showMeetings")
}
