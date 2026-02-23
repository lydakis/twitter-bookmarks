import ArgumentParser
import Dispatch
import Foundation

enum FormatOption: String, CaseIterable, ExpressibleByArgument {
    case json
    case markdown

    var outputFormat: OutputFormat {
        switch self {
        case .json:
            return .json
        case .markdown:
            return .markdown
        }
    }
}

struct TwitterBookmarksCLI {
    private struct ExtractOptions {
        let output: String
        let format: FormatOption
        let maxScrolls: Int
        let cdpPort: Int
        let folder: String?
    }

    static func main() async {
        do {
            let options = try parseArguments(Array(CommandLine.arguments.dropFirst()))
            try await runExtract(options: options)
        } catch let error as ValidationError {
            fputs("Error: \(error.message)\n", stderr)
            printUsage()
            Foundation.exit(1)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func runExtract(options: ExtractOptions) async throws {
        let client = try CDPClient(port: options.cdpPort)
        defer {
            Task {
                await client.disconnect()
            }
        }

        try await client.connect()

        let scraper = TwitterBookmarksScraper(
            client: client,
            configuration: .init(
                maxScrolls: options.maxScrolls,
                folder: options.folder
            )
        )

        let bookmarks = try await scraper.scrapeBookmarks()
        let content = try OutputFormatters.render(bookmarks: bookmarks, format: options.format.outputFormat)
        try OutputFormatters.write(content: content, to: options.output)

        print("Extracted \(bookmarks.count) bookmarks to \(options.output)")
    }

    private static func parseArguments(_ arguments: [String]) throws -> ExtractOptions {
        guard let first = arguments.first else {
            throw ValidationError("Missing subcommand. Use 'extract'.")
        }

        if first == "--help" || first == "-h" {
            printUsage()
            Foundation.exit(0)
        }

        guard first == "extract" else {
            throw ValidationError("Unsupported subcommand '\(first)'. Use 'extract'.")
        }

        var output: String?
        var format: FormatOption = .markdown
        var maxScrolls = 10
        var cdpPort = 18792
        var folder: String?

        var index = 1
        while index < arguments.count {
            let argument = arguments[index]

            switch argument {
            case "--help", "-h":
                printUsage()
                Foundation.exit(0)
            case "--output", "-o":
                output = try consumeValue(arguments, index: &index, option: argument)
            case "--format", "-f":
                let value = try consumeValue(arguments, index: &index, option: argument)
                guard let parsed = FormatOption(argument: value) else {
                    throw ValidationError("Invalid --format '\(value)'. Expected 'json' or 'markdown'.")
                }
                format = parsed
            case "--max-scrolls", "-s":
                let value = try consumeValue(arguments, index: &index, option: argument)
                guard let parsed = Int(value), parsed >= 0 else {
                    throw ValidationError("Invalid --max-scrolls '\(value)'. Use an integer >= 0.")
                }
                maxScrolls = parsed
            case "--cdp-port", "-p":
                let value = try consumeValue(arguments, index: &index, option: argument)
                guard let parsed = Int(value), (1...65535).contains(parsed) else {
                    throw ValidationError("Invalid --cdp-port '\(value)'. Use a valid port number (1-65535).")
                }
                cdpPort = parsed
            case "--folder", "-F":
                let value = try consumeValue(arguments, index: &index, option: argument)
                let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
                folder = cleaned.isEmpty ? nil : cleaned
            default:
                if let (name, value) = splitInlineOption(argument), let parsed = try parseInlineOption(name: name, value: value) {
                    output = parsed.output ?? output
                    format = parsed.format ?? format
                    maxScrolls = parsed.maxScrolls ?? maxScrolls
                    cdpPort = parsed.cdpPort ?? cdpPort
                    folder = parsed.folder ?? folder
                } else {
                    throw ValidationError("Unknown argument '\(argument)'.")
                }
            }

            index += 1
        }

        guard let output else {
            throw ValidationError("Missing required option --output <path>.")
        }

        let cleanedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedOutput.isEmpty else {
            throw ValidationError("Output path cannot be empty.")
        }

        return ExtractOptions(
            output: cleanedOutput,
            format: format,
            maxScrolls: maxScrolls,
            cdpPort: cdpPort,
            folder: folder
        )
    }

    private struct InlineOptionValues {
        var output: String?
        var format: FormatOption?
        var maxScrolls: Int?
        var cdpPort: Int?
        var folder: String?
    }

    private static func parseInlineOption(name: String, value: String) throws -> InlineOptionValues? {
        var parsed = InlineOptionValues()

        switch name {
        case "--output":
            parsed.output = value
        case "--format":
            guard let format = FormatOption(argument: value) else {
                throw ValidationError("Invalid --format '\(value)'. Expected 'json' or 'markdown'.")
            }
            parsed.format = format
        case "--max-scrolls":
            guard let maxScrolls = Int(value), maxScrolls >= 0 else {
                throw ValidationError("Invalid --max-scrolls '\(value)'. Use an integer >= 0.")
            }
            parsed.maxScrolls = maxScrolls
        case "--cdp-port":
            guard let port = Int(value), (1...65535).contains(port) else {
                throw ValidationError("Invalid --cdp-port '\(value)'. Use a valid port number (1-65535).")
            }
            parsed.cdpPort = port
        case "--folder":
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            parsed.folder = cleaned.isEmpty ? nil : cleaned
        default:
            return nil
        }

        return parsed
    }

    private static func splitInlineOption(_ argument: String) -> (String, String)? {
        guard argument.hasPrefix("--"), let equalIndex = argument.firstIndex(of: "=") else {
            return nil
        }

        let name = String(argument[..<equalIndex])
        let valueIndex = argument.index(after: equalIndex)
        let value = String(argument[valueIndex...])
        return (name, value)
    }

    private static func consumeValue(_ arguments: [String], index: inout Int, option: String) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw ValidationError("Missing value for option \(option).")
        }
        let value = arguments[valueIndex]
        index = valueIndex
        return value
    }

    private static func printUsage() {
        let lines = [
            "Usage:",
            "  twitter-bookmarks extract --output <path> [--format json|markdown] [--max-scrolls N] [--cdp-port N] [--folder NAME]",
            "",
            "Options:",
            "  --output, -o        Output file path (required)",
            "  --format, -f        Output format: json or markdown (default: markdown)",
            "  --max-scrolls, -s   Number of scrolls to load more bookmarks (default: 10)",
            "  --cdp-port, -p      Chrome DevTools port (default: 18792)",
            "  --folder, -F        Optional bookmark folder filter",
            "  --help, -h          Show this help"
        ]
        print(lines.joined(separator: "\n"))
    }
}

let semaphore = DispatchSemaphore(value: 0)
Task {
    await TwitterBookmarksCLI.main()
    semaphore.signal()
}
semaphore.wait()
