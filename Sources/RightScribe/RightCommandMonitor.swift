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
    static let tapOptions: CGEventTapOptions = .listenOnly

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
    private var gesture = RightCommandGestureInterpreter()

    func start() throws {
        guard AXIsProcessTrusted() else {
            logger.error("Listener start rejected: Accessibility is not trusted")
            throw MonitorError.permissionMissing
        }

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.tapDisabledByTimeout.rawValue)
            | CGEventMask(1 << CGEventType.tapDisabledByUserInput.rawValue)

        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: Self.tapOptions,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<RightCommandMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                monitor.observe(type: type, event: event)
                return Unmanaged.passUnretained(event)
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
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.ensureListenerIsEnabled()
        }
        healthTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        logger.notice("Passive Right Command event tap started")
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
        gesture.reset()
    }

    private func observe(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout:
            logger.warning("Passive event tap timed out; re-enabling it")
            gesture.reset()
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            deliverOnMain(onListenerInterrupted)

        case .tapDisabledByUserInput:
            logger.debug("Passive event tap paused by secure input")
            gesture.reset()
            deliverOnMain(onListenerInterrupted)

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

        case .keyDown:
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            if keyCode == escapeKeyCode {
                _ = deliverEscapePressed()
            }
            if keyCode != rightCommandKeyCode {
                emit(gesture.handleOtherInput())
            }

        default:
            break
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
        logger.debug("Restoring passive keyboard listener after a macOS pause")
        gesture.reset()
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }
}
