import Foundation

enum TwitterBookmarksScraperError: LocalizedError {
    case timeout(message: String)
    case invalidBookmarkPayload

    var errorDescription: String? {
        switch self {
        case .timeout(let message):
            return message
        case .invalidBookmarkPayload:
            return "Unable to parse bookmark payload from page data."
        }
    }
}

final class TwitterBookmarksScraper {
    struct Configuration {
        let maxScrolls: Int
        let pageLoadTimeout: TimeInterval
        let pollInterval: TimeInterval
        let scrollDelay: TimeInterval
        let retryCount: Int
        let folder: String?

        init(
            maxScrolls: Int = 10,
            pageLoadTimeout: TimeInterval = 30,
            pollInterval: TimeInterval = 0.5,
            scrollDelay: TimeInterval = 1.0,
            retryCount: Int = 2,
            folder: String? = nil
        ) {
            self.maxScrolls = maxScrolls
            self.pageLoadTimeout = pageLoadTimeout
            self.pollInterval = pollInterval
            self.scrollDelay = scrollDelay
            self.retryCount = retryCount
            self.folder = folder
        }
    }

    private struct ParsedBookmark {
        let bookmark: Bookmark
        let folder: String?
    }

    private let client: CDPClient
    private let configuration: Configuration
    private let bookmarksURL = "https://x.com/i/bookmarks"

    init(client: CDPClient, configuration: Configuration = .init()) {
        self.client = client
        self.configuration = configuration
    }

    func scrapeBookmarks() async throws -> [Bookmark] {
        try await withRetry("enable CDP domains") { [self] in
            try await self.enableDomains()
        }

        try await withRetry("navigate to bookmarks") { [self] in
            try await self.navigateToBookmarksPage()
        }

        try await waitForTimelineToLoad(timeout: configuration.pageLoadTimeout)

        // Expand collapsed tweets first so extraction has full text.
        _ = try await expandShowMoreInView()

        for _ in 0..<configuration.maxScrolls {
            _ = try await expandShowMoreInView()
            try await scrollTimeline()
            try await Task.sleep(nanoseconds: UInt64(configuration.scrollDelay * 1_000_000_000))
        }

        _ = try await expandShowMoreInView()

        let parsed = try await withRetry("extract bookmark data") { [self] in
            try await self.extractBookmarks()
        }

        let filtered = applyFolderFilter(parsed)
        return deduplicate(filtered.map(\.bookmark))
    }

    private func enableDomains() async throws {
        _ = try await client.sendCommand("Runtime.enable")
        _ = try await client.sendCommand("Page.enable")
    }

    private func navigateToBookmarksPage() async throws {
        do {
            _ = try await client.sendCommand(
                "Page.navigate",
                params: ["url": bookmarksURL],
                timeout: 20
            )
        } catch {
            // Fallback for relays that don't expose Page.navigate.
            let expression = "window.location.href = '\(bookmarksURL)'; true;"
            _ = try await client.evaluate(expression, timeout: 10)
        }
    }

    private func waitForTimelineToLoad(timeout: TimeInterval) async throws {
        let condition = #"""
        (() => {
          const isBookmarksPage = window.location.href.includes('/i/bookmarks');
          const ready = document.readyState === 'interactive' || document.readyState === 'complete';
          const hasColumn = document.querySelector('[data-testid="primaryColumn"]') !== null;
          const hasTweet = document.querySelector('article[data-testid="tweet"]') !== null;
          const loadingSpinner = document.querySelector('[aria-label="Loading timeline"]') !== null;
          return isBookmarksPage && ready && (hasTweet || hasColumn) && !loadingSpinner;
        })()
        """#

        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            let result = try? await client.evaluate(condition, timeout: 5)
            if boolValue(result) == true {
                return
            }
            try await Task.sleep(nanoseconds: UInt64(configuration.pollInterval * 1_000_000_000))
        }

        throw TwitterBookmarksScraperError.timeout(
            message: "Bookmarks timeline did not load within \(Int(timeout)) seconds."
        )
    }

    private func scrollTimeline() async throws {
        let script = #"""
        (() => {
          const currentHeight = document.documentElement.scrollHeight;
          window.scrollBy({ top: window.innerHeight * 1.5, behavior: 'instant' });
          return currentHeight;
        })()
        """#
        _ = try await client.evaluate(script, timeout: 10)
    }

    private func expandShowMoreInView() async throws -> Int {
        let script = #"""
        (() => {
          const visible = (el) => {
            const rect = el.getBoundingClientRect();
            return rect.bottom > 0 && rect.top < window.innerHeight && rect.width > 0 && rect.height > 0;
          };

          const candidates = Array.from(document.querySelectorAll('div[role="button"], span'));
          let clicks = 0;
          for (const node of candidates) {
            const label = (node.textContent || '').trim().toLowerCase();
            if (label !== 'show more') continue;

            const target = node.closest('div[role="button"]') || node;
            if (!visible(target)) continue;
            target.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
            clicks += 1;
          }
          return clicks;
        })()
        """#

        let result = try await client.evaluate(script, timeout: 10)
        return intValue(result) ?? 0
    }

    private func extractBookmarks() async throws -> [ParsedBookmark] {
        let script = #"""
        (() => {
          const normalize = (value) => (value || '').replace(/\s+/g, ' ').trim();

          const parseCount = (raw) => {
            if (!raw) return 0;
            const cleaned = String(raw).replace(/,/g, '').trim();
            const match = cleaned.match(/([0-9]*\.?[0-9]+)\s*([KMB])?/i);
            if (!match) return 0;
            let number = Number.parseFloat(match[1]);
            const suffix = (match[2] || '').toUpperCase();
            if (suffix === 'K') number *= 1_000;
            if (suffix === 'M') number *= 1_000_000;
            if (suffix === 'B') number *= 1_000_000_000;
            return Number.isFinite(number) ? Math.round(number) : 0;
          };

          const metric = (article, testId) => {
            const metricNode = article.querySelector(`[data-testid="${testId}"]`);
            if (!metricNode) return 0;
            const text = normalize(metricNode.innerText || metricNode.textContent);
            return parseCount(text);
          };

          const rows = [];
          const articles = Array.from(document.querySelectorAll('article[data-testid="tweet"]'));
          for (const article of articles) {
            const statusLink = article.querySelector('a[href*="/status/"]');
            if (!statusLink) continue;

            const permalink = statusLink.href;
            let id = '';
            let handleFromURL = '';

            try {
              const parsed = new URL(permalink, window.location.origin);
              const segments = parsed.pathname.split('/').filter(Boolean);
              const statusIndex = segments.indexOf('status');
              if (statusIndex >= 0 && segments[statusIndex + 1]) {
                id = segments[statusIndex + 1];
              }
              if (statusIndex > 0 && segments[statusIndex - 1]) {
                handleFromURL = segments[statusIndex - 1];
              }
            } catch (_) {}

            const textNode = article.querySelector('[data-testid="tweetText"]');
            const rawText = normalize(textNode ? (textNode.innerText || textNode.textContent) : '');

            const timestampNode = article.querySelector('time');
            const timestamp = timestampNode ? (timestampNode.getAttribute('datetime') || '') : '';

            const userNameNode = article.querySelector('[data-testid="User-Name"]');
            let authorName = '';
            let authorHandle = handleFromURL ? `@${handleFromURL.replace(/^@/, '')}` : '';

            if (userNameNode) {
              const spans = Array.from(userNameNode.querySelectorAll('span')).map((item) => normalize(item.textContent));
              const explicitHandle = spans.find((item) => item.startsWith('@'));
              const explicitName = spans.find((item) => item.length > 0 && !item.startsWith('@'));
              if (explicitName) authorName = explicitName;
              if (explicitHandle) authorHandle = explicitHandle;
            }

            if (!authorName && authorHandle) {
              authorName = authorHandle.replace(/^@/, '');
            }

            const folderNode = article.closest('[data-bookmark-folder], [data-folder-name], [aria-label*="folder"], [aria-label*="Folder"]');
            const folder = folderNode
              ? normalize(
                  folderNode.getAttribute('data-bookmark-folder') ||
                  folderNode.getAttribute('data-folder-name') ||
                  folderNode.getAttribute('aria-label') ||
                  ''
                )
              : null;

            rows.push({
              id: id || permalink,
              authorName: authorName || authorHandle || 'Unknown',
              authorHandle: authorHandle || '@unknown',
              text: rawText,
              url: permalink,
              timestamp: timestamp,
              likes: metric(article, 'like'),
              retweets: metric(article, 'retweet'),
              replies: metric(article, 'reply'),
              bookmarks: metric(article, 'bookmark'),
              hasMedia: article.querySelector('[data-testid="tweetPhoto"], [data-testid="videoPlayer"], video') !== null,
              folder: folder || null
            });
          }

          return rows;
        })()
        """#

        let value = try await client.evaluate(script, timeout: 30)
        guard let dictionaries = normalizeDictionaryArray(value) else {
            throw TwitterBookmarksScraperError.invalidBookmarkPayload
        }

        return dictionaries.compactMap { dictionary in
            guard
                let id = stringValue(dictionary["id"]),
                let authorName = stringValue(dictionary["authorName"]),
                let authorHandle = stringValue(dictionary["authorHandle"]),
                let text = stringValue(dictionary["text"]),
                let url = stringValue(dictionary["url"]),
                let timestamp = stringValue(dictionary["timestamp"])
            else {
                return nil
            }

            let bookmark = Bookmark(
                id: id,
                authorName: authorName,
                authorHandle: authorHandle,
                text: text,
                url: url,
                timestamp: timestamp,
                likes: intValue(dictionary["likes"]) ?? 0,
                retweets: intValue(dictionary["retweets"]) ?? 0,
                replies: intValue(dictionary["replies"]) ?? 0,
                bookmarks: intValue(dictionary["bookmarks"]) ?? 0,
                hasMedia: boolValue(dictionary["hasMedia"]) ?? false
            )

            return ParsedBookmark(
                bookmark: bookmark,
                folder: stringValue(dictionary["folder"])
            )
        }
    }

    private func applyFolderFilter(_ bookmarks: [ParsedBookmark]) -> [ParsedBookmark] {
        guard let folder = configuration.folder?.trimmingCharacters(in: .whitespacesAndNewlines), !folder.isEmpty else {
            return bookmarks
        }

        return bookmarks.filter { parsed in
            guard let bookmarkFolder = parsed.folder, !bookmarkFolder.isEmpty else {
                return false
            }
            return bookmarkFolder.caseInsensitiveCompare(folder) == .orderedSame
        }
    }

    private func deduplicate(_ bookmarks: [Bookmark]) -> [Bookmark] {
        var seen = Set<String>()
        var unique: [Bookmark] = []
        for bookmark in bookmarks where seen.insert(bookmark.id).inserted {
            unique.append(bookmark)
        }
        return unique
    }

    private func withRetry<T>(
        _ operationName: String,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        var attempt = 0
        var lastError: Error?

        while attempt <= configuration.retryCount {
            do {
                return try await operation()
            } catch {
                lastError = error
                if attempt == configuration.retryCount {
                    break
                }
                attempt += 1
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        throw lastError ?? CDPClientError.connectionFailed("Unknown error while \(operationName).")
    }

    private func normalizeDictionaryArray(_ value: Any?) -> [[String: Any]]? {
        if let dictionaries = value as? [[String: Any]] {
            return dictionaries
        }
        if let array = value as? [Any] {
            return array.compactMap { $0 as? [String: Any] }
        }
        return nil
    }

    private func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private func intValue(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }

    private func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            return NSString(string: string).boolValue
        default:
            return nil
        }
    }
}
