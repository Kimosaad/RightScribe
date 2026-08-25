import Foundation

enum CustomVocabulary {
    static let maximumEntryCount = 100
    static let maximumEntryLength = 80

    static func normalizedEntry(_ input: String) -> String? {
        let normalized = input
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !normalized.isEmpty, normalized.count <= maximumEntryLength else { return nil }
        return normalized
    }

    static func adding(_ input: String, to entries: [String]) -> [String] {
        guard entries.count < maximumEntryCount,
              let normalized = normalizedEntry(input),
              !entries.contains(where: { $0.localizedCaseInsensitiveCompare(normalized) == .orderedSame }) else {
            return entries
        }
        return entries + [normalized]
    }

    static func sanitized(_ entries: [String]) -> [String] {
        entries.reduce(into: [String]()) { result, entry in
            result = adding(entry, to: result)
        }
    }
}
