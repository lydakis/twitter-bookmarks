# Twitter Bookmarks Exporter

Extract your Twitter/X bookmarks to JSON or Markdown format using Chrome DevTools Protocol.

## What It Does

- Connects to your logged-in Chrome session via CDP
- Navigates to Twitter bookmarks
- Extracts tweet data (author, text, URL, date, engagement stats)
- Outputs as JSON or formatted Markdown newsletter
- Supports filtering by bookmark folders

## Requirements

- macOS 13+
- Chrome with remote debugging enabled, OR
- OpenClaw Browser Relay extension attached to a Twitter tab
- Swift 5.9+

## Installation

```bash
git clone https://github.com/lydakis/twitter-bookmarks-cli
cd twitter-bookmarks-cli
swift build -c release
```

## Usage

### With OpenClaw Browser Relay (Recommended)

1. Open Twitter bookmarks in Chrome
2. Click the OpenClaw Browser Relay extension icon (badge shows "ON")
3. Run the CLI:

```bash
./twitter-bookmarks extract --output bookmarks.md --format markdown
```

### With Chrome Remote Debugging

1. Start Chrome with remote debugging:
```bash
/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome --remote-debugging-port=9222
```

2. Navigate to Twitter bookmarks manually

3. Run the CLI:
```bash
./twitter-bookmarks extract --output bookmarks.md --format markdown --cdp-port 9222
```

## Options

```
--output, -o        Output file path (required)
--format, -f        Output format: json or markdown (default: markdown)
--max-scrolls, -s   Number of scrolls to load more bookmarks (default: 10)
--cdp-port, -p      Chrome DevTools port (default: 18792)
--folder, -F        Optional bookmark folder filter
```

## Output Formats

### Markdown (default)
Creates a newsletter-style digest:

```markdown
# Twitter Bookmarks Digest
*Generated: 2026-02-23*

## @author — [Tweet text...](url)
Posted: time | 👍 likes | 🔄 retweets | 💬 replies

---
```

### JSON
Structured data for further processing:

```json
{
  "bookmarks": [
    {
      "id": "...",
      "authorName": "...",
      "authorHandle": "@...",
      "text": "...",
      "url": "https://x.com/...",
      "timestamp": "...",
      "likes": 351,
      "retweets": 16,
      "replies": 14
    }
  ]
}
```

## Troubleshooting

**"Unable to connect to Chrome CDP endpoint"**
- Ensure Chrome is running with the extension ON for the bookmarks tab
- Check that the port matches (default 18792 for OpenClaw, 9222 for manual)

**No bookmarks extracted**
- Make sure you're logged into Twitter/X
- Check that the bookmarks page is loaded
- Try increasing --max-scrolls

## Future Improvements

- Direct OpenClaw integration (without manual CLI)
- Automatic scheduling/digest generation
- Integration with Notion, Obsidian, etc.
- Incremental sync (only new bookmarks since last run)

## License

MIT
