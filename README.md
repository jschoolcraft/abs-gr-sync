# AudioBookShelf Sync Reverse Matching

A Ruby script that syncs your Goodreads "read" books with your AudioBookShelf library by marking matching books as finished with the correct completion date.

## Overview

This script takes a unique approach: instead of trying to find Audiobookshelf books from your Goodreads export (which often fails due to title/author variations), it:

1. **Fetches unfinished books from Audiobookshelf** - only books you haven't marked as complete
2. **Searches for matches in your Goodreads export** - using smart fuzzy matching
3. **Updates only matched books** - marks them as finished with the correct read date

This reverse approach is much more effective because Audiobookshelf has cleaner, more consistent metadata than Goodreads exports.

One of the problems I faced was audiobook versions vs. ebook versions, title variations, series
numbering, and author inconsistencies (multiples, narrators, etc).

## Features

### 🎯 Smart Filtering
- **Only processes unfinished books** - reduces scope from 700+ to ~200 books
- Includes books in progress and books with no tracking
- Skips already-finished books automatically

### 🧠 Intelligent Matching (90%+ success rate)
- **Multi-stage matching pipeline**:
  1. Exact ISBN match (highest confidence)
  2. Exact title + author match
  3. Fuzzy title + exact author match
  4. Fuzzy title + fuzzy author match
- **Title cleaning** - removes series numbers, subtitles, version info
- **Author normalization** - handles Jr./Sr., initials, translators
- **Author extraction** - pulls author from title when metadata is missing

### 📊 Detailed Reporting
- Progress tracking for each book
- Confidence scores for matches
- Failed matches saved to log files
- Dry-run mode for testing

## Requirements

- Ruby (tested with 3.0+)
- 1Password CLI (`op`) for credential management
- Goodreads library export CSV
- Audiobookshelf server access

## Setup

1. **Clone this repository**
   ```bash
   git clone <this repository-url>
   cd audiobookshelf-sync
   ```

2. **Configure your settings**
   ```bash
   cp config.example.yml config.yml
   ```

   Edit `config.yml` and fill in:
   - Your AudioBookShelf server URLs
   - Your 1Password item names for each server
   - Optional: Adjust batch size, confidence threshold, etc.

3. **Set up 1Password CLI**
   ```bash
   # Install 1Password CLI if not already installed
   # https://developer.1password.com/docs/cli/get-started/

   # Sign in to your 1Password account
   op signin
   ```

4. **Export your Goodreads library**
   - Go to Goodreads → My Books → Import and export
   - Export your library as CSV
   - Save it as `goodreads_library_export.csv` in the script directory

5. **Create 1Password items for your AudioBookShelf servers**

   For each server, create a 1Password item with:
   - Title: Whatever you specified in `config.yml` (e.g., "abs-primary")
   - Username: Your AudioBookShelf username
   - Password: Your AudioBookShelf password

## Usage

### Test run (recommended first)
```bash
# Test with limited books (set test_limit in config.yml)
ruby sync-reverse-matching.rb
```

### Full sync
```bash
# Remove or increase test_limit in config.yml
ruby sync-reverse-matching.rb
```

### Dry run (see what would be updated without making changes)
```bash
DRY_RUN=true ruby sync-reverse-matching.rb
```

## How It Works

1. **Fetches unfinished books** from your Audiobookshelf library
2. **Loads your Goodreads export** (only "read" books)
3. **Matches books** using intelligent fuzzy matching
4. **Updates progress** in batches of 10 books
5. **Reports results** including match rate and failures

## Matching Algorithm

The script uses sophisticated matching to handle common variations:

- **Series numbering**: "Book 1 - Title" → "Title"
- **Subtitles**: "Title: A Long Subtitle" → "Title"
- **Version info**: "Title (Unabridged)" → "Title"
- **Author variations**: "John Smith Jr." matches "John Smith"
- **Missing authors**: Extracts from "Author Name - Title" format

## Results

Typical results with the reverse matching approach:
- **Match rate**: 85-95% (vs 20-70% with traditional approach)
- **Processing time**: 2-5 minutes for 200 books (but of course, it depends)

## Troubleshooting

### Low Match Rate
- Check if books are in your Goodreads export
- Verify "Exclusive Shelf" is "read" in the CSV
- Look for significant title differences

### Authentication Issues
- Run `op signin` to authenticate 1Password
- Verify item names in `config.yml` match your 1Password items exactly
- Check credentials have `--reveal` permission

### Failed Matches
Check the log files generated for each server:
- `failed_matches_reverse_*.log`

Common reasons:
- Book not in Goodreads export
- Significant title/author differences
- Business/technical books often missing

## Advanced Options

## Configuration Options

In `config.yml`:

- `servers`: Array of server configurations
  - `name`: Friendly name for the server
  - `base_url`: Full URL to your AudioBookShelf server
  - `onepassword_item`: Name of the 1Password item containing credentials
- `batch_size`: Number of books to update in each batch (default: 10)
- `dry_run`: Set to true to test without making changes (default: false)
- `confidence_threshold`: Minimum confidence for matches (default: 0.7)
- `test_limit`: Limit number of books for testing (remove for full sync)
- `goodreads_export_file`: Path to your Goodreads CSV export

### Do I have to use 1Password?

No, you can modify the script to use environment variables or a different credential management system.

### Why multiple servers?

Maybe you have a friend that shares their AudioBookShelf with you, or you have multiple servers for
different purposes. This script supports syncing across multiple servers by defining them in the
`config.yml` file.

### Extending Matching
To improve matches, enhance these functions:
- `clean_title()` - Add more title normalization rules
- `process_author()` - Handle additional author formats
- `find_goodreads_match()` - Adjust confidence thresholds

## Disclaimer

This project is not affiliated with, endorsed by, or sponsored by Goodreads, AudioBookShelf, or any of their respective owners, subsidiaries, or affiliates. All trademarks, service marks, and company names mentioned in this project are the property of their respective owners.

This software is provided for educational and personal use only. Users are responsible for ensuring their use of this software complies with the terms of service of any third-party services they interact with, including but not limited to Goodreads and AudioBookShelf.

The author(s) of this software make no warranties or representations about the accuracy, reliability, or suitability of this software for any particular purpose. Use at your own risk.

## License

MIT - Feel free to adapt for your own use!
