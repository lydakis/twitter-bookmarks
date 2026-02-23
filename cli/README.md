# Twitter Bookmarks CLI

Extract Twitter/X bookmarks using Chrome DevTools Protocol (CDP) via an active browser session.

## What It Does

- Connects to your existing Chrome session (requires OpenClaw Browser Relay or manual CDP)
- Navigates to Twitter bookmarks
- Extracts bookmarked tweets (author, text, URL, date, engagement stats)
- Outputs as JSON or Markdown newsletter format
- Supports filtering by date range, folder, or search terms

## Usage

```bash
# Extract all bookmarks to JSON
./twitter-bookmarks extract --output bookmarks.json

# Extract to Markdown newsletter format
./twitter-bookmarks extract --format markdown --output newsletter.md

# Filter by folder/tag
./twitter-bookmarks extract --folder "AI" --output ai-bookmarks.md

# Filter by date (last 7 days)
./twitter-bookmarks extract --since "7d" --output recent.md
```

## Requirements

- Chrome running with remote debugging enabled
- Or: OpenClaw Browser Relay extension attached to a Twitter tab
- macOS 14+ (uses Swift + ArgumentParser)

## Tech Stack

- Swift 6
- ArgumentParser (CLI interface)
- JSONDecoder/Encoder for data handling
- File I/O for export formats
