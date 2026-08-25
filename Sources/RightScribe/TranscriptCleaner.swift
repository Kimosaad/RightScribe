import Foundation

enum TranscriptCleaner {
    static func removingFillers(from transcript: String) -> String {
        var result = transcript

        let replacements: [(String, String)] = [
            (#"(?i)(?<![\p{L}\p{N}])(?:um+|uh+|erm+|ah+)(?![\p{L}\p{N}])\s*,?\s*"#, " "),
            (#"(?i)(?:^|,)\s*you\s+know\s*,\s*"#, " "),
            (#"(?i)^\s*like\s*,\s*"#, ""),
            (#"(?i)([.!?])\s+like\s*,\s*"#, "$1 "),
            (#"\s+([,.;:!?])"#, "$1"),
            (#",\s*([.!?])"#, "$1"),
            (#"^\s*[,;:]\s*"#, ""),
            (#"[ \t]{2,}"#, " "),
            (#"\s+\n"#, "\n")
        ]

        for (pattern, replacement) in replacements {
            result = result.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }

        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstLetter = result.firstIndex(where: { $0.isLetter }) else { return result }
        result.replaceSubrange(firstLetter...firstLetter, with: String(result[firstLetter]).uppercased())
        return result
    }
}
