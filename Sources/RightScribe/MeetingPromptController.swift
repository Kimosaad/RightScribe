import AppKit
import SwiftUI

@MainActor
final class MeetingPromptController {
    private var panel: NSPanel?

    func show(
        candidate: MeetingCandidate,
        onStart: @escaping @MainActor () -> Void,
        onDismiss: @escaping @MainActor () -> Void
    ) {
        hide()

        let view = MeetingPromptView(
            applicationName: candidate.applicationName,
            onStart: { [weak self] in
                self?.hide()
                onStart()
            },
            onDismiss: { [weak self] in
                self?.hide()
                onDismiss()
            }
        )
        let controller = NSHostingController(rootView: view)
        let panel = NSPanel(contentViewController: controller)
        panel.title = "Meeting detected"
        panel.styleMask = [.titled, .closable, .fullSizeContentView, .nonactivatingPanel]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setContentSize(NSSize(width: 390, height: 238))
        panel.center()
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.closeButton)?.target = self
        panel.standardWindowButton(.closeButton)?.action = #selector(closePanel)
        self.panel = panel

        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    @objc private func closePanel() {
        hide()
    }
}

private struct MeetingPromptView: View {
    let applicationName: String
    let onStart: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 13) {
                ZStack {
                    Circle().fill(Color(red: 0.70, green: 0.36, blue: 0.24).opacity(0.14))
                    Image(systemName: "person.2.wave.2.fill")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(Color(red: 0.70, green: 0.36, blue: 0.24))
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Meeting detected")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Text(applicationName)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            Text("Would you like RightScribe to create private meeting notes? Nothing is recorded until you choose Start Notes.")
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Not Now", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Start Notes", action: onStart)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.70, green: 0.36, blue: 0.24))
            }
        }
        .padding(26)
        .frame(width: 390, height: 238)
        .background(Color(red: 0.969, green: 0.949, blue: 0.906))
        .preferredColorScheme(.light)
    }
}
