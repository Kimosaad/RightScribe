import AppKit
import SwiftUI

@MainActor
final class DictationOverlayController {
    enum Mode {
        case preparing
        case listening
        case processing
        case success
        case error

        var icon: String {
            switch self {
            case .preparing, .processing: return "ellipsis"
            case .listening: return "waveform"
            case .success: return "checkmark"
            case .error: return "exclamationmark"
            }
        }

        var tint: Color {
            switch self {
            case .preparing, .processing: return .secondary
            case .listening: return .blue
            case .success: return .green
            case .error: return .red
            }
        }
    }

    private var panel: NSPanel?
    private var pendingHide: Task<Void, Never>?

    func show(mode: Mode, transcript: String) {
        pendingHide?.cancel()
        let content = DictationIndicator(mode: mode)
        let hosting = NSHostingView(rootView: content)

        let panel = panel ?? makePanel()
        panel.contentView = hosting
        position(panel)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        pendingHide?.cancel()
        panel?.orderOut(nil)
    }

    func hide(after seconds: Double) {
        pendingHide?.cancel()
        pendingHide = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 54, height: 54),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = true
        return panel
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let origin = NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.minY + 18
        )
        panel.setFrameOrigin(origin)
    }
}

private struct DictationIndicator: View {
    let mode: DictationOverlayController.Mode

    var body: some View {
        Image(systemName: mode == .listening ? "waveform.circle.fill" : mode.icon)
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(mode.tint)
            .symbolEffect(.pulse, options: .repeating, isActive: mode == .listening)
            .frame(width: 50, height: 50)
            .background(.ultraThickMaterial, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
    }
}
