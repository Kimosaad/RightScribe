import AVFoundation
import CoreAudio
import Foundation

enum SystemAudioPermissionPrimer {
    static let preparedKey = "RightScribe.meetingAudioPrepared"

    static func request() -> Bool {
        let system = AudioHardwareSystem.shared
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.name = "RightScribe Meeting Audio Permission"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        do {
            guard let tap = try system.makeProcessTap(description: description) else { return false }
            try system.destroyProcessTap(tap)
            UserDefaults.standard.set(true, forKey: preparedKey)
            return true
        } catch {
            return false
        }
    }

    static func markPrepared() {
        UserDefaults.standard.set(true, forKey: preparedKey)
    }
}

final class ProcessAudioTapCapture: @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case noMeetingAudioProcesses
        case tapCreationFailed(String)
        case invalidTapFormat
        case aggregateCreationFailed(String)
        case callbackCreationFailed(OSStatus)
        case startFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .noMeetingAudioProcesses:
                return "RightScribe could not find the meeting app's audio process."
            case .tapCreationFailed(let reason):
                return "Meeting audio access could not start. \(reason)"
            case .invalidTapFormat:
                return "The meeting app returned an unsupported audio format."
            case .aggregateCreationFailed(let reason):
                return "RightScribe could not prepare audio-only meeting capture. \(reason)"
            case .callbackCreationFailed(let status), .startFailed(let status):
                return "Audio-only meeting capture could not start (\(Self.fourCC(status)))."
            }
        }

        private static func fourCC(_ status: OSStatus) -> String {
            let value = UInt32(bitPattern: status)
            let shifts: [UInt32] = [24, 16, 8, 0]
            let characters = shifts.map { shift -> Character in
                let byte = UInt8((value >> shift) & 0xff)
                return byte >= 32 && byte <= 126 ? Character(UnicodeScalar(byte)) : "?"
            }
            return "\(status) / '\(String(characters))'"
        }
    }

    private let system = AudioHardwareSystem.shared
    private let queue = DispatchQueue(
        label: "com.karimsaad.rightscribe.meeting.process-audio",
        qos: .userInitiated
    )
    private var tap: AudioHardwareTap?
    private var aggregateDevice: AudioHardwareAggregateDevice?
    private var ioProcID: AudioDeviceIOProcID?

    func start(processObjectIDs: [AudioObjectID], bridge: MeetingAudioBridge) throws {
        guard tap == nil else { return }
        guard !processObjectIDs.isEmpty else { throw CaptureError.noMeetingAudioProcesses }

        let description = CATapDescription(monoMixdownOfProcesses: processObjectIDs)
        description.name = "RightScribe Meeting Audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        let tap: AudioHardwareTap
        do {
            guard let created = try system.makeProcessTap(description: description) else {
                throw CaptureError.tapCreationFailed("macOS did not create an audio tap.")
            }
            tap = created
            self.tap = created
            SystemAudioPermissionPrimer.markPrepared()
        } catch let error as CaptureError {
            throw error
        } catch {
            throw CaptureError.tapCreationFailed(error.localizedDescription)
        }

        do {
            var streamDescription = try tap.format
            guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
                throw CaptureError.invalidTapFormat
            }
            let tapUID = try tap.uid
            let aggregateUID = "com.karimsaad.rightscribe.meeting.\(UUID().uuidString)"
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "RightScribe Meeting Audio",
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true
                ]]
            ]
            guard let aggregate = try system.makeAggregateDevice(description: aggregateDescription) else {
                throw CaptureError.aggregateCreationFailed("macOS did not create the private audio device.")
            }
            aggregateDevice = aggregate

            var ioProcID: AudioDeviceIOProcID?
            let callbackStatus = AudioDeviceCreateIOProcIDWithBlock(
                &ioProcID,
                aggregate.id,
                queue
            ) { _, inputData, _, _, _ in
                bridge.consume(inputData, format: format)
            }
            guard callbackStatus == noErr, let ioProcID else {
                throw CaptureError.callbackCreationFailed(callbackStatus)
            }
            self.ioProcID = ioProcID

            let startStatus = AudioDeviceStart(aggregate.id, ioProcID)
            guard startStatus == noErr else { throw CaptureError.startFailed(startStatus) }
        } catch let error as CaptureError {
            stop()
            throw error
        } catch {
            stop()
            throw CaptureError.aggregateCreationFailed(error.localizedDescription)
        }
    }

    func stop() {
        if let aggregateDevice, let ioProcID {
            _ = AudioDeviceStop(aggregateDevice.id, ioProcID)
            _ = AudioDeviceDestroyIOProcID(aggregateDevice.id, ioProcID)
        }
        ioProcID = nil

        if let aggregateDevice {
            try? system.destroyAggregateDevice(aggregateDevice)
        }
        self.aggregateDevice = nil

        if let tap {
            try? system.destroyProcessTap(tap)
        }
        self.tap = nil
    }

    deinit {
        stop()
    }
}

final class MeetingMicrophoneCapture: @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case microphoneUnavailable

        var errorDescription: String? {
            "No usable microphone input is available for meeting notes."
        }
    }

    private var engine: AVAudioEngine?

    func start(bridge: MeetingAudioBridge) throws {
        guard engine == nil else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.microphoneUnavailable
        }

        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { buffer, _ in
            bridge.consume(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
            self.engine = engine
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    func stop() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    deinit {
        stop()
    }
}
