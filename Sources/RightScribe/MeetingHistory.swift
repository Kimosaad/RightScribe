import Foundation

enum MeetingSpeaker: String, Codable, Sendable {
    case you
    case attendee

    var displayName: String {
        switch self {
        case .you: return "You"
        case .attendee: return "Attendee"
        }
    }
}

struct MeetingTranscriptTurn: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let speaker: MeetingSpeaker
    let text: String
    let startedAt: TimeInterval
}

struct MeetingRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    let sourceApplication: String
    let startedAt: Date
    let endedAt: Date
    let turns: [MeetingTranscriptTurn]
    let calendarEvent: CalendarEventSnapshot?

    var duration: TimeInterval {
        max(0, endedAt.timeIntervalSince(startedAt))
    }

    var fullTranscript: String {
        turns.map { "\($0.speaker.displayName): \($0.text)" }.joined(separator: "\n\n")
    }
}

enum MeetingHistoryPersistence {
    private static let directoryName = "RightScribe"
    private static let fileName = "meeting-history.json"

    static func load() -> [MeetingRecord] {
        guard let data = try? Data(contentsOf: historyURL),
              let items = try? JSONDecoder().decode([MeetingRecord].self, from: data) else {
            return []
        }
        return items
    }

    static func save(_ items: [MeetingRecord]) throws {
        let directory = historyURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(items)
        try data.write(to: historyURL, options: .atomic)
    }

    private static var historyURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName)
    }
}
