import ApplicationServices
import CoreGraphics
import Foundation
import OSLog

struct RightCommandGestureInterpreter {
    enum Action: Equatable {
        case toggle
        case chord
    }

    private(set) var rightCommandDown = false
    private var chordUsed = false

    mutating func handleRightCommand(isDown: Bool) -> Action? {
        guard isDown != rightCommandDown else { return nil }
        rightCommandDown = isDown

        if isDown {
            chordUsed = false
            return nil
        }

        return chordUsed ? nil : .toggle
    }

    mutating func handleOtherInput() -> Action? {
        guard rightCommandDown, !chordUsed else { return nil }
        chordUsed = true
        return .chord
    }

    mutating func consumeCurrentPress() {
        guard rightCommandDown else { return }
        chordUsed = true
    }

    mutating func reset() {
        rightCommandDown = false
        chordUsed = false
    }
}

final class RightCommandMonitor: @unchecked Sendable {
    enum MonitorError: LocalizedError {
        case permissionMissing
        case eventTapCreationFailed

        var errorDescription: String? {
            switch self {
            case .permissionMissing:
                return "Accessibility permission is required for the Right Command trigger."
            case .eventTapCreationFailed:
                return "RightScribe could not start the Right Command listener. Reopen the app after granting Accessibility permission."
            }
        }
    }

    var onRightCommandDown: (@MainActor @Sendable () -> Bool)?
    var onRightCommandPressed: (@MainActor @Sendable () -> Void)?
    var onCommandChord: (@MainActor @Sendable () -> Void)?
    var onListenerInterrupted: (@MainActor @Sendable () -> Void)?
    var onEscapePressed: (@MainActor @Sendable () -> Bool)?

    private let rightCommandKeyCode: CGKeyCode = 54
    private let escapeKeyCode: CGKeyCode = 53
    private let logger = Logger(subsystem: "com.karimsaad.rightscribe", category: "RightCommand")
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var healthTimer: Timer?
    private var suppressEscapeKeyUp = false
    private var gesture = RightCommandGestureInterpreter()

    func start() throws {
        guard AXIsProcessTrusted() else {
            logger.error("Listener start rejected: Accessibility is not trusted")
            throw MonitorError.permissionMissing
        }

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.tapDisabledByTimeout.rawValue)
            | CGEventMask(1 << CGEventType.tapDisabledByUserInput.rawValue)

        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<RightCommandMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
                    ? nil
                    : Unmanaged.passUnretained(event)
            },
            userInfo: opaqueSelf
        ) else {
            logger.error("CGEvent tap creation failed")
            throw MonitorError.eventTapCreationFailed
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.ensureListenerIsEnabled()
        }
        healthTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        logger.notice("Right Command event tap started")
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        healthTimer?.invalidate()
        healthTimer = nil
        suppressEscapeKeyUp = false
        gesture.reset()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            logger.warning("Event tap was disabled by macOS; re-enabling it")
            gesture.reset()
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            deliverOnMain(onListenerInterrupted)
            return false

        case .flagsChanged:
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            if keyCode == rightCommandKeyCode {
                let isDown = event.flags.contains(.maskCommand)
                logger.debug("Right Command flagsChanged; isDown=\(isDown, privacy: .public)")
                emit(gesture.handleRightCommand(isDown: isDown))
                if isDown, deliverRightCommandDown() {
                    gesture.consumeCurrentPress()
                }
            } else {
                emit(gesture.handleOtherInput())
            }
            return false

        case .keyDown:
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            if keyCode == escapeKeyCode, deliverEscapePressed() {
                suppressEscapeKeyUp = true
                return true
            }
            if keyCode != rightCommandKeyCode {
                emit(gesture.handleOtherInput())
            }
            return false

        case .keyUp:
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            if keyCode == escapeKeyCode, suppressEscapeKeyUp {
                suppressEscapeKeyUp = false
                return true
            }
            return false

        default:
            return false
        }
    }

    private func emit(_ action: RightCommandGestureInterpreter.Action?) {
        switch action {
        case .toggle:
            logger.notice("Right Command toggle recognized")
            deliverOnMain(onRightCommandPressed)
        case .chord:
            logger.debug("Right Command chord recognized")
            deliverOnMain(onCommandChord)
        case nil: break
        }
    }

    private func deliverRightCommandDown() -> Bool {
        guard let callback = onRightCommandDown else { return false }
        guard Thread.isMainThread else {
            logger.error("Right Command callback arrived off the main thread")
            Task { @MainActor in _ = callback() }
            return false
        }
        return MainActor.assumeIsolated { callback() }
    }

    private func deliverEscapePressed() -> Bool {
        guard let callback = onEscapePressed else { return false }
        guard Thread.isMainThread else {
            logger.error("Escape callback arrived off the main thread")
            Task { @MainActor in _ = callback() }
            return false
        }
        return MainActor.assumeIsolated { callback() }
    }

    private func deliverOnMain(_ callback: (@MainActor @Sendable () -> Void)?) {
        guard let callback else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { callback() }
        } else {
            Task { @MainActor in callback() }
        }
    }

    private func ensureListenerIsEnabled() {
        guard let eventTap, !CGEvent.tapIsEnabled(tap: eventTap) else { return }
        logger.warning("Right Command listener health check found it disabled; re-enabling it")
        gesture.reset()
        CGEvent.tapEnable(tap: eventTap, enable: true)
        deliverOnMain(onListenerInterrupted)
    }
}
