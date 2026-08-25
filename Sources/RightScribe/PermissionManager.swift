import ApplicationServices
import AVFoundation
import Foundation
import Speech

struct PermissionStatus: Sendable {
    let speech: Bool
    let microphone: Bool
    let accessibility: Bool
    let meetingAudioPrepared: Bool

    var allGranted: Bool {
        speech && microphone && accessibility
    }

    var missingDescription: String {
        var missing: [String] = []
        if !speech { missing.append("Speech Recognition") }
        if !microphone { missing.append("Microphone") }
        if !accessibility { missing.append("Accessibility") }
        return "Enable " + missing.joined(separator: ", ") + "."
    }
}

enum PermissionManager {
    static func currentStatus() -> PermissionStatus {
        PermissionStatus(
            speech: SFSpeechRecognizer.authorizationStatus() == .authorized,
            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            accessibility: AXIsProcessTrusted(),
            meetingAudioPrepared: UserDefaults.standard.bool(
                forKey: SystemAudioPermissionPrimer.preparedKey
            )
        )
    }

    static func requestSpeechAndMicrophone() async {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { _ in
                    continuation.resume()
                }
            }
        }

        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
    }

    static func requestAccessibility() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        _ = CGRequestPostEventAccess()
    }

    static func requestMeetingAudio() async -> Bool {
        await Task.detached(priority: .userInitiated) {
            SystemAudioPermissionPrimer.request()
        }.value
    }
}
