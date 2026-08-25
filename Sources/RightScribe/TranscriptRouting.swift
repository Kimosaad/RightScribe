import Foundation

enum TranscriptRoute: Equatable, Sendable {
    case insertText(String)
    case actionUnavailable(String)
}

protocol TranscriptRouting: Sendable {
    func route(_ transcript: String) async -> TranscriptRoute
}

/// V1 deliberately has one safe outcome. V2 can replace this router with an
/// explicit-command parser without touching audio capture or text insertion.
struct V1TranscriptRouter: TranscriptRouting {
    func route(_ transcript: String) async -> TranscriptRoute {
        .insertText(transcript)
    }
}

struct TranscriptAccumulator: Sendable {
    private(set) var finalized = ""
    private(set) var volatile = ""

    var displayText: String {
        Self.join(finalized, volatile)
    }

    mutating func receive(_ text: String, isFinal: Bool) {
        if isFinal {
            finalized = Self.join(finalized, text)
            volatile = ""
        } else {
            volatile = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func join(_ lhs: String, _ rhs: String) -> String {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }

        if let first = right.first, ".,!?;:)]}".contains(first) {
            return left + right
        }
        return left + " " + right
    }
}
