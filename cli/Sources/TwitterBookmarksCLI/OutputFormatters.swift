import Foundation

enum OutputFormat: String, CaseIterable {
    case json
    case markdown
}

enum OutputFormatterError: LocalizedError {
    case invalidOutputPath(String)

    var errorDescription: String? {
        switch self {
        case .invalidOutputPath(let path):
            return "Unable to write output file at path: \(path)"
        }
    }
}

enum OutputFormatters {
    static func render(
        bookmarks: [Bookmark],
        format: OutputFormat,
        generatedAt: Date = Date()
    ) throws -> String {
        switch format {
        case .json:
            return try jsonOutput(from: bookmarks)
        case .markdown:
            return markdownOutput(from: bookmarks, generatedAt: generatedAt)
        }
    }

    static func write(content: String, to outputPath: String) throws {
        let outputURL = URL(fileURLWithPath: outputPath)
        let parentDirectory = outputURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDirectory.path) {
            try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        }

        guard let data = content.data(using: .utf8) else {
            throw OutputFormatterError.invalidOutputPath(outputPath)
        }

        do {
            try data.write(to: outputURL, options: [.atomic])
        } catch {
            throw OutputFormatterError.invalidOutputPath(outputPath)
        }
    }

    private static func jsonOutput(from bookmarks: [Bookmark]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(bookmarks)
        return String(decoding: data, as: UTF8.self)
    }

    private static func markdownOutput(from bookmarks: [Bookmark], generatedAt: Date) -> String {
        let generatedDate = dateOnlyFormatter.string(from: generatedAt)

        var lines: [String] = []
        lines.append("# Twitter Bookmarks Digest")
        lines.append("*Generated: \(generatedDate)*")
        lines.append("")

        for bookmark in bookmarks {
            let headlineHandle = bookmark.authorHandle.isEmpty ? "@unknown" : bookmark.authorHandle
            let headlineText = truncatedHeadLine(bookmark.text)
            lines.append("## \(headlineHandle) — [\(escapeMarkdown(headlineText))](\(bookmark.url))")

            let postedDate = renderTimestamp(bookmark.timestamp)
            lines.append(
                "Posted: \(postedDate) | 👍 \(bookmark.likes) | 🔄 \(bookmark.retweets) | 💬 \(bookmark.replies) | 🔖 \(bookmark.bookmarks)"
            )

            if bookmark.hasMedia {
                lines.append("Media: yes")
            }

            lines.append("---")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private static func truncatedHeadLine(_ value: String, limit: Int = 120) -> String {
        let normalized = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard normalized.count > limit else {
            return normalized.isEmpty ? "Tweet" : normalized
        }
        let endIndex = normalized.index(normalized.startIndex, offsetBy: limit)
        return String(normalized[..<endIndex]) + "..."
    }

    private static func renderTimestamp(_ value: String) -> String {
        guard !value.isEmpty else {
            return "Unknown"
        }

        if let date = iso8601Formatter.date(from: value) {
            return readableDateFormatter.string(from: date)
        }
        return value
    }

    private static func escapeMarkdown(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let readableDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        return formatter
    }()
}
