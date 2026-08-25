import AppKit
import ApplicationServices
import CoreAudio
import Foundation
import OSLog

struct MeetingCandidate: Equatable, Sendable {
    let processID: pid_t
    let applicationName: String
    let bundleIdentifier: String
    let applicationFamily: String

    var id: String { "\(bundleIdentifier):\(processID)" }
}

@MainActor
final class MeetingDetector {
    var onMeetingDetected: (@MainActor (MeetingCandidate) -> Void)?
    var onMeetingEnded: (@MainActor (String) -> Void)?

    private let logger = Logger(subsystem: "com.karimsaad.rightscribe", category: "MeetingDetection")
    private var pollingTask: Task<Void, Never>?
    private var currentCandidate: MeetingCandidate?
    private var endGraceTracker = MeetingEndGraceTracker()

    func start() {
        stop()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        currentCandidate = nil
        endGraceTracker.reset()
    }

    private func poll() {
        let detectedCandidate = detectCandidate()
        let hasCallWindow = currentCandidate.map(Self.hasMeetingWindow(for:)) ?? false
        let candidate = endGraceTracker.resolvedCandidate(
            detected: detectedCandidate,
            current: currentCandidate,
            hasMeetingWindow: hasCallWindow,
            now: Date()
        )

        if candidate?.id != currentCandidate?.id {
            if let previous = currentCandidate {
                onMeetingEnded?(previous.id)
            }
            currentCandidate = candidate
            if let candidate {
                logger.notice("Likely active meeting detected in \(candidate.applicationName, privacy: .public)")
                onMeetingDetected?(candidate)
            }
        }
    }

    private static func hasMeetingWindow(for candidate: MeetingCandidate) -> Bool {
        NSWorkspace.shared.runningApplications.contains { application in
            guard !application.isTerminated,
                  let bundleID = application.bundleIdentifier,
                  let name = application.localizedName,
                  MeetingApplicationClassifier.family(bundleID: bundleID, name: name)
                    == candidate.applicationFamily else { return false }
            return windowTitles(processID: application.processIdentifier)
                .contains(where: looksLikeMeetingWindow)
        }
    }

    private func detectCandidate() -> MeetingCandidate? {
        let applications = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        let audioInputFamilies = Set(AudioProcessInspector.activeInputProcessFamilies())
        let audioOutputFamilies = Set(AudioProcessInspector.activeOutputProcessFamilies())
        var matches: [(score: Int, application: NSRunningApplication, family: String)] = []

        for application in applications {
            guard let bundleID = application.bundleIdentifier,
                  let name = application.localizedName,
                  let family = MeetingApplicationClassifier.family(bundleID: bundleID, name: name) else { continue }

            let titles = Self.windowTitles(processID: application.processIdentifier)
            let hasMeetingWindow = titles.contains(where: Self.looksLikeMeetingWindow)
            let hasDirectInput = AudioProcessInspector.isRunningInput(processID: application.processIdentifier)
            let hasActiveInput = hasDirectInput
                || audioInputFamilies.contains(family)
            let hasActiveOutput = AudioProcessInspector.isRunningOutput(processID: application.processIdentifier)
                || audioOutputFamilies.contains(family)
            let hasCallAudio = hasActiveInput
                || (hasActiveOutput && (hasMeetingWindow || family == "facetime"))

            guard hasCallAudio else { continue }
            guard family != "browser" || hasMeetingWindow else { continue }

            var score = 0
            if application.activationPolicy == .regular { score += 10 }
            if hasMeetingWindow { score += 6 }
            if hasDirectInput { score += 3 }
            if hasActiveOutput { score += 1 }
            let loweredName = name.lowercased()
            if loweredName.contains("helper") || loweredName.contains("host") { score -= 8 }
            matches.append((score, application, family))
        }

        guard let best = matches.max(by: { $0.score < $1.score }),
              let bundleID = best.application.bundleIdentifier,
              let name = best.application.localizedName else { return nil }
        return MeetingCandidate(
            processID: best.application.processIdentifier,
            applicationName: name,
            bundleIdentifier: bundleID,
            applicationFamily: best.family
        )
    }

    private static func looksLikeMeetingWindow(_ title: String) -> Bool {
        let title = title.lowercased()
        return title.contains("google meet")
            || title.contains("meet.google")
            || title.hasPrefix("meet -")
            || title.hasPrefix("meet –")
            || title.contains("zoom meeting")
            || title.contains("microsoft teams")
            || title.contains("webex")
            || title.contains("huddle")
            || title.contains("call with")
            || title.contains("whereby")
            || title.contains("riverside")
    }

    private static func windowTitles(processID: pid_t) -> [String] {
        let application = AXUIElementCreateApplication(processID)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &windowsValue
        ) == .success,
        let windows = windowsValue as? [AXUIElement] else { return [] }

        return windows.compactMap { window in
            var titleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                window,
                kAXTitleAttribute as CFString,
                &titleValue
            ) == .success else { return nil }
            return titleValue as? String
        }
    }
}

struct MeetingEndGraceTracker {
    private(set) var missingSince: Date?

    mutating func resolvedCandidate(
        detected: MeetingCandidate?,
        current: MeetingCandidate?,
        hasMeetingWindow: Bool,
        now: Date
    ) -> MeetingCandidate? {
        if let detected {
            missingSince = nil
            return detected
        }
        guard let current else {
            missingSince = nil
            return nil
        }

        let firstMissing = missingSince ?? now
        missingSince = firstMissing
        let gracePeriod: TimeInterval = hasMeetingWindow || current.applicationFamily == "facetime"
            ? 45
            : 12
        return now.timeIntervalSince(firstMissing) < gracePeriod ? current : nil
    }

    mutating func reset() {
        missingSince = nil
    }
}

enum AudioProcessInspector {
    static func isRunningInput(processID: pid_t) -> Bool {
        guard let objectID = audioObjectID(processID: processID) else { return false }
        return booleanProperty(
            objectID: objectID,
            selector: kAudioProcessPropertyIsRunningInput
        )
    }

    static func isRunningOutput(processID: pid_t) -> Bool {
        guard let objectID = audioObjectID(processID: processID) else { return false }
        return booleanProperty(
            objectID: objectID,
            selector: kAudioProcessPropertyIsRunningOutput
        )
    }

    static func activeInputProcessFamilies() -> [String] {
        activeProcessFamilies(selector: kAudioProcessPropertyIsRunningInput)
    }

    static func activeOutputProcessFamilies() -> [String] {
        activeProcessFamilies(selector: kAudioProcessPropertyIsRunningOutput)
    }

    static func audioProcessObjectIDs(forFamily family: String) -> [AudioObjectID] {
        processObjectIDs().filter { objectID in
            guard let bundleID = stringProperty(
                objectID: objectID,
                selector: kAudioProcessPropertyBundleID
            ) else { return false }
            return MeetingApplicationClassifier.family(bundleID: bundleID, name: bundleID) == family
        }
    }

    private static func activeProcessFamilies(
        selector: AudioObjectPropertySelector
    ) -> [String] {
        processObjectIDs().compactMap { objectID in
            guard booleanProperty(objectID: objectID, selector: selector),
                  let bundleID = stringProperty(objectID: objectID, selector: kAudioProcessPropertyBundleID),
                  let family = MeetingApplicationClassifier.family(bundleID: bundleID, name: bundleID) else { return nil }
            return family
        }
    }

    private static func audioObjectID(processID: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var processID = processID
        var objectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &processID,
            &size,
            &objectID
        )
        return status == noErr && objectID != kAudioObjectUnknown ? objectID : nil
    }

    private static func processObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else { return [] }

        var objects = Array(
            repeating: AudioObjectID(0),
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &objects
        ) == noErr else { return [] }
        return objects
    }

    private static func booleanProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr
            && value != 0
    }

    private static func stringProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value?.takeUnretainedValue() as String?
    }
}

enum MeetingApplicationClassifier {
    nonisolated static func family(bundleID: String, name: String) -> String? {
        let value = "\(bundleID) \(name)".lowercased()
        if value.contains("zoom") { return "zoom" }
        if value.contains("teams") { return "teams" }
        if value.contains("webex") { return "webex" }
        if value.contains("facetime") || value.contains("avconference") { return "facetime" }
        if value.contains("slack") { return "slack" }
        if value.contains("discord") { return "discord" }
        if value.contains("chrome") || value.contains("safari") || value.contains("arc")
            || value.contains("firefox") || value.contains("edge") {
            return "browser"
        }
        return nil
    }
}
