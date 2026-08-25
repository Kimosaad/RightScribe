import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OSLog

@MainActor
final class TextInjector {
    enum InsertionError: LocalizedError {
        case accessibilityPermissionMissing
        case secureField
        case pasteFailed
        case targetChanged

        var errorDescription: String? {
            switch self {
            case .accessibilityPermissionMissing:
                return "Accessibility permission is required to insert dictated text."
            case .secureField:
                return "RightScribe will not insert dictated text into a password field."
            case .pasteFailed:
                return "RightScribe could not insert text into the focused application."
            case .targetChanged:
                return "The focused application changed before RightScribe could paste the transcript."
            }
        }
    }

    private let logger = Logger(subsystem: "com.karimsaad.rightscribe", category: "Insertion")

    func insert(_ text: String) async throws {
        guard AXIsProcessTrusted() else { throw InsertionError.accessibilityPermissionMissing }

        if let focused = focusedElement() {
            if isSecureTextField(focused) { throw InsertionError.secureField }
        }

        let target = NSWorkspace.shared.frontmostApplication
        logger.notice("Pasting into app=\(target?.bundleIdentifier ?? "unknown", privacy: .public)")
        try await pasteWithClipboardPreservation(text, targetPID: target?.processIdentifier)
    }

    private func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success, let value else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func isSecureTextField(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSubroleAttribute as CFString,
            &value
        ) == .success else { return false }
        return (value as? String) == (kAXSecureTextFieldSubrole as String)
    }

    private func pasteWithClipboardPreservation(_ text: String, targetPID: pid_t?) async throws {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw InsertionError.pasteFailed
        }
        let injectedChangeCount = pasteboard.changeCount

        // Give pasteboard services and sandboxed target apps time to observe the
        // new item before sending the keyboard shortcut.
        try? await Task.sleep(for: .milliseconds(80))

        if let targetPID,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != targetPID {
            restore(snapshot, ifUnchangedSince: injectedChangeCount, on: pasteboard)
            throw InsertionError.targetChanged
        }

        guard await postCommandV() else {
            restore(snapshot, ifUnchangedSince: injectedChangeCount, on: pasteboard)
            throw InsertionError.pasteFailed
        }

        // Chromium, Electron, remote desktop, and document apps may read the
        // clipboard asynchronously. Restoring earlier can paste the old value.
        try? await Task.sleep(for: .milliseconds(900))
        restore(snapshot, ifUnchangedSince: injectedChangeCount, on: pasteboard)
        logger.notice("Paste shortcut delivered and clipboard restored")
    }

    private func postCommandV() async -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(20))
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private func restore(
        _ snapshot: PasteboardSnapshot,
        ifUnchangedSince changeCount: Int,
        on pasteboard: NSPasteboard
    ) {
        guard pasteboard.changeCount == changeCount else {
            logger.notice("Clipboard changed after injection; preserving the newer clipboard")
            return
        }
        snapshot.restore(to: pasteboard)
    }
}

private struct PasteboardSnapshot {
    struct Item {
        let representations: [NSPasteboard.PasteboardType: Data]
    }

    let items: [Item]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let snapshots = (pasteboard.pasteboardItems ?? []).map { item in
            var representations: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    representations[type] = data
                }
            }
            return Item(representations: representations)
        }
        return PasteboardSnapshot(items: snapshots)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restoredItems = items.map { snapshot -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in snapshot.representations {
                item.setData(data, forType: type)
            }
            return item
        }
        if !restoredItems.isEmpty {
            pasteboard.writeObjects(restoredItems)
        }
    }
}
