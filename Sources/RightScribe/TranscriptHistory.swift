import Foundation

struct TranscriptHistoryItem: Codable, Identifiable, Equatable {
    let id: UUID
    let text: String
    let createdAt: Date
    let applicationName: String?
}

enum TranscriptHistoryPersistence {
    private static let directoryName = "RightScribe"
    private static let fileName = "transcript-history.json"

    static func load() -> [TranscriptHistoryItem] {
        guard let data = try? Data(contentsOf: historyURL),
              let items = try? JSONDecoder().decode([TranscriptHistoryItem].self, from: data) else {
            return []
        }
        return items
    }

    static func save(_ items: [TranscriptHistoryItem]) throws {
        let directory = historyURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(items)
        try data.write(to: historyURL, options: .atomic)
    }

    private static var historyURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return base
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName)
    }
}
