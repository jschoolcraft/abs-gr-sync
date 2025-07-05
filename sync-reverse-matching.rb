#!/usr/bin/env ruby

require "bundler/inline"

gemfile do
  source "https://rubygems.org"
  gem "http"
  gem "ostruct"
  gem "pry"
  gem "csv"
  gem "json"
  gem "logger"
  gem "yaml"
end

require "http"
require "csv"
require "json"
require "date"
require "fileutils"
require "logger"
require "yaml"

# Load configuration
def load_config
  config_file = "config.yml"
  
  unless File.exist?(config_file)
    puts "Error: #{config_file} not found!"
    puts "Please copy config.example.yml to config.yml and configure your settings."
    exit 1
  end
  
  config = YAML.load_file(config_file)
  
  # Validate required fields
  unless config["servers"] && config["servers"].is_a?(Array) && !config["servers"].empty?
    puts "Error: No servers configured in #{config_file}"
    exit 1
  end
  
  config["servers"].each_with_index do |server, index|
    unless server["base_url"] && server["onepassword_item"]
      puts "Error: Server #{index + 1} missing base_url or onepassword_item"
      exit 1
    end
  end
  
  config
end

# Load configuration
CONFIG = load_config

# Configuration constants
BATCH_SIZE = CONFIG["batch_size"] || 10
DRY_RUN = (CONFIG["dry_run"] || ENV["DRY_RUN"]) == "true" || (CONFIG["dry_run"] || ENV["DRY_RUN"]) == true
MAPPINGS_DIR = "mappings"
MATCH_RESULTS_FILE = "match_results.json"
FAILED_MATCHES_FILE = "failed_matches_reverse.log"
CONFIDENCE_THRESHOLD = CONFIG["confidence_threshold"] || 0.7
GOODREADS_EXPORT_FILE = CONFIG["goodreads_export_file"] || "goodreads_library_export.csv"

# Setup
FileUtils.mkdir_p(MAPPINGS_DIR)
logger = Logger.new(STDOUT)
logger.level = Logger::INFO

# Fuzzy string matching functions
def levenshtein_distance(str1, str2)
  return str2.length if str1.empty?
  return str1.length if str2.empty?

  matrix = Array.new(str1.length + 1) { Array.new(str2.length + 1) }

  (0..str1.length).each { |i| matrix[i][0] = i }
  (0..str2.length).each { |j| matrix[0][j] = j }

  (1..str1.length).each do |i|
    (1..str2.length).each do |j|
      cost = str1[i-1] == str2[j-1] ? 0 : 1
      matrix[i][j] = [
        matrix[i-1][j] + 1,
        matrix[i][j-1] + 1,
        matrix[i-1][j-1] + cost
      ].min
    end
  end

  matrix[str1.length][str2.length]
end

def string_similarity(str1, str2)
  return 1.0 if str1 == str2
  return 0.0 if str1.empty? || str2.empty?

  distance = levenshtein_distance(str1.downcase, str2.downcase)
  max_length = [str1.length, str2.length].max

  1.0 - (distance.to_f / max_length)
end

# Enhanced title and author cleaning with quick wins
def clean_title(title)
  return nil if title.nil? || title.empty?

  original_title = title.dup

  # QUICK WIN 1: Strip version/subtitle issues (30.4% of failures)
  # Remove (Unabridged), (German edition), etc.
  cleaned = title.gsub(/\s*\([^)]*\bUnabridged\b[^)]*\)/i, '')
  cleaned = cleaned.gsub(/\s*\([^)]*\bGerman edition\b[^)]*\)/i, '')
  cleaned = cleaned.gsub(/\s*\[[^\]]*\bUnabridged\b[^\]]*\]/i, '')

  # Remove long subtitles after colon/dash
  cleaned = cleaned.split(/\s*[:\-—]\s*/).first if cleaned.include?(':') || cleaned.include?(' - ') || cleaned.include?('—')

  # QUICK WIN 2: Strip series numbering (31.3% of failures)
  # Remove "Author - Series NN - Title" patterns
  if cleaned.match(/^[^-]+ - [^-]+ \d+ - /)
    parts = cleaned.split(' - ')
    cleaned = parts.last if parts.length >= 3 # Take the title part
  end

  # Remove "Book N", "Vol N", "Volume N" patterns
  cleaned = cleaned.gsub(/\b(Book|Vol\.?|Volume)\s+\d+\b/i, '').strip

  # Remove series numbering like "01 - Title", "Space Team - 01 - Title"
  cleaned = cleaned.gsub(/^.*\s+\d{2}\s+-\s+/, '') # "Series 01 - Title" -> "Title"
  cleaned = cleaned.gsub(/^\d{2}\s+-?\s*/, '') # "01 - Title" -> "Title"

  # Remove series info in parentheses
  cleaned = cleaned.gsub(/\s*\([^)]*\)/, '')

  # Remove common collection indicators
  cleaned = cleaned.gsub(/\s*(Box Set|Collection|Omnibus|Complete Series|The Complete|Complete Edition)/i, '')

  # Remove "The" from beginning for better matching
  cleaned = cleaned.gsub(/^The\s+/i, '')

  # Clean whitespace
  cleaned.strip
end

def clean_author(author)
  return nil if author.nil? || author.empty?

  # Handle "Last, First" format
  if author.include?(',')
    parts = author.split(',').map(&:strip)
    "#{parts[1]} #{parts[0]}"
  else
    author
  end.strip
end

def normalize_author(author)
  return nil if author.nil?

  # Remove Jr., Sr., etc.
  normalized = author.gsub(/\s+(Jr\.?|Sr\.?|III?|IV)\s*$/i, '')
  # Handle initials
  normalized = normalized.gsub(/\b([A-Z])\.\s*([A-Z])\./, '\1. \2.')
  # Clean whitespace
  normalized.strip
end

# QUICK WIN 3: Extract author from title when author field is empty (2.7% of failures)
def extract_author_from_title(title)
  return nil if title.nil? || title.empty?

  # Pattern: "Author Name - Series/Title"
  if title.match(/^([A-Z][a-z]+ [A-Z][a-z]+(?:\s+[A-Z][a-z]+)*)\s+-\s+/)
    return $1.strip
  end

  # Pattern: "LastName, FirstName - Title"
  if title.match(/^([A-Z][a-z]+,\s+[A-Z][a-z]+)\s+-\s+/)
    parts = $1.split(',').map(&:strip)
    return "#{parts[1]} #{parts[0]}" # Convert to "First Last"
  end

  nil
end

# Enhanced author processing with translator/multi-author handling
def process_author(author, title)
  # QUICK WIN 3: If author is empty, try to extract from title
  if author.nil? || author.empty? || author.strip.empty?
    extracted = extract_author_from_title(title)
    return extracted if extracted
    return nil
  end

  # Handle translator issues: "Author, Translator - translator"
  if author.include?("translator") || author.include?("Translator")
    # Take the first part before translator
    author = author.split(/,\s*[^,]*translator/i).first
  end

  # Handle multi-author: take first author only for matching
  if author.include?(",") && !author.match(/^[^,]+,\s*[^,]+$/) # Not "Last, First" format
    author = author.split(',').first.strip
  end

  normalize_author(author)
end

# Fetch credentials from 1Password
def get_1password_credentials(item_name)
  puts "Fetching credentials for: #{item_name}"

  username = `op item get "#{item_name}" --fields username --reveal 2>&1`.strip
  if $?.exitstatus != 0
    puts "Error fetching username: #{username}"
    raise "Failed to fetch username for #{item_name}"
  end

  password = `op item get "#{item_name}" --fields password --reveal 2>&1`.strip
  if $?.exitstatus != 0
    puts "Error fetching password: #{password}"
    raise "Failed to fetch password for #{item_name}"
  end

  if username.empty? || password.empty?
    raise "Empty credentials for #{item_name}"
  end

  puts "Successfully fetched credentials (username: #{username}, password length: #{password.length})"
  { username: username, password: password }
end

# Fetch unfinished books from ABS library
def fetch_unfinished_abs_books(base_url, token, library_id)
  puts "Fetching books in progress..."

  # Get books currently in progress
  in_progress_response = HTTP.auth("Bearer #{token}").get("#{base_url}/api/me/items-in-progress")
  in_progress_books = []

  if in_progress_response.status.success?
    in_progress_data = JSON.parse(in_progress_response.body)
    in_progress_items = in_progress_data["libraryItems"] || []

    in_progress_items.each do |item|
      next unless item["mediaType"] == "book"

      metadata = item.dig("media", "metadata")
      next unless metadata

      # Process author with our enhanced logic
      processed_author = process_author(metadata["authorName"], metadata["title"])

      book = {
        id: item["id"],
        title: metadata["title"],
        author: processed_author,
        original_author: metadata["authorName"], # Keep original for debugging
        isbn: metadata["isbn"],
        isbn13: metadata["isbn13"],
        series: metadata["seriesName"],
        published_year: metadata["publishedYear"],
        source: "in_progress"
      }

      in_progress_books << book
    end
  end

  puts "Found #{in_progress_books.length} books in progress"

  # Also get books with no progress at all (never started, but might be finished elsewhere)
  puts "Fetching all library books to find untracked ones..."
  all_books = []
  page = 0
  limit = 100

  # Get all books to find ones without any progress tracking
  loop do
    url = "#{base_url}/api/libraries/#{library_id}/items?limit=#{limit}&page=#{page}"

    response = HTTP.auth("Bearer #{token}").get(url)
    unless response.status.success?
      puts "Error fetching books: #{response.status} - #{response.body}"
      break
    end

    data = JSON.parse(response.body)
    library_items = data["results"] || []

    break if library_items.empty?

    library_items.each do |item|
      next unless item["mediaType"] == "book"

      metadata = item.dig("media", "metadata")
      next unless metadata

      # Check if this book has any progress
      progress_response = HTTP.auth("Bearer #{token}").get("#{base_url}/api/me/progress/#{item['id']}")
      has_progress = progress_response.status.success?

      if has_progress
        progress_data = JSON.parse(progress_response.body)
        is_finished = progress_data["isFinished"]

        # Skip finished books
        next if is_finished
      end

      # Skip if already in progress list
      next if in_progress_books.any? { |b| b[:id] == item["id"] }

      # Process author with our enhanced logic
      processed_author = process_author(metadata["authorName"], metadata["title"])

      book = {
        id: item["id"],
        title: metadata["title"],
        author: processed_author,
        original_author: metadata["authorName"],
        isbn: metadata["isbn"],
        isbn13: metadata["isbn13"],
        series: metadata["seriesName"],
        published_year: metadata["publishedYear"],
        source: has_progress ? "unfinished" : "no_progress"
      }

      all_books << book
    end

    page += 1

    # Limit to first 200 books for now to avoid too many API calls
    break if all_books.length + in_progress_books.length >= 200
  end

  puts "Found #{all_books.length} additional unfinished/untracked books"

  # Combine and return
  combined_books = in_progress_books + all_books
  puts "Total unfinished books to process: #{combined_books.length}"

  combined_books
end

# Load Goodreads export into searchable structure
def load_goodreads_data(file_path)
  books = []

  CSV.foreach(file_path, headers: true) do |row|
    next unless row["Exclusive Shelf"] == "read"

    book = {
      title: row["Title"],
      author: row["Author"],
      isbn: row["ISBN"]&.gsub(/[=\"']/, ''),
      isbn13: row["ISBN13"]&.gsub(/[=\"']/, ''),
      date_read: row["Date Read"],
      rating: row["My Rating"]
    }

    next if book[:title].nil? || book[:title].empty?
    next if book[:author].nil? || book[:author].empty?

    books << book
  end

  books
end

# Multi-stage matching pipeline
def find_goodreads_match(abs_book, goodreads_books)
  best_match = nil
  best_confidence = 0.0

  abs_title = clean_title(abs_book[:title])
  abs_author = abs_book[:author] || ""
  abs_isbn = abs_book[:isbn]
  abs_isbn13 = abs_book[:isbn13]

  puts "  ABS: title='#{abs_title}', author='#{abs_author}', isbn='#{abs_isbn}', isbn13='#{abs_isbn13}'"

  goodreads_books.each do |gr_book|
    confidence = 0.0

    # Stage 1: Exact ISBN match (highest confidence)
    if abs_isbn && gr_book[:isbn] && abs_isbn == gr_book[:isbn]
      confidence = 1.0
    elsif abs_isbn13 && gr_book[:isbn13] && abs_isbn13 == gr_book[:isbn13]
      confidence = 1.0

    # Stage 2: Exact title + author match
    elsif clean_title(gr_book[:title]) == abs_title &&
          normalize_author(gr_book[:author]) == normalize_author(abs_author)
      confidence = 0.95

    # Stage 3: Fuzzy title + exact author match
    elsif normalize_author(gr_book[:author]) == normalize_author(abs_author)
      title_similarity = string_similarity(abs_title, clean_title(gr_book[:title]))
      confidence = 0.7 + (title_similarity * 0.2)

    # Stage 4: Fuzzy title + fuzzy author match
    else
      title_similarity = string_similarity(abs_title, clean_title(gr_book[:title]))
      author_similarity = string_similarity(normalize_author(abs_author), normalize_author(gr_book[:author]))

      # Both must be reasonably similar
      if title_similarity > 0.6 && author_similarity > 0.6
        confidence = (title_similarity + author_similarity) / 2 * 0.8
      end
    end

    if confidence > best_confidence
      best_confidence = confidence
      best_match = gr_book.merge(confidence: confidence)
    end
  end

  best_match if best_confidence >= CONFIDENCE_THRESHOLD
end

def send_batch(batch, token, batch_num, total_processed, base_url, dry_run)
  puts "\nProcessing batch #{batch_num} (#{batch.length} updates, #{total_processed} total)"

  if dry_run
    puts "DRY RUN - Would update:"
    batch.each do |update|
      puts "  - Library Item: #{update["libraryItemId"]}"
    end
    return
  end

  puts "Sending batch update..."

  progress_response = HTTP.auth("Bearer #{token}")
    .patch("#{base_url}/api/me/progress/batch/update", json: batch)

  if progress_response.status.success?
    puts "Successfully updated batch #{batch_num}!"
  else
    puts "Failed to update batch #{batch_num}: #{progress_response.body}"
  end

  sleep 1
end

# Main processing
servers = []

CONFIG["servers"].each do |server_config|
  begin
    server = {
      base_url: server_config["base_url"],
      **get_1password_credentials(server_config["onepassword_item"])
    }
    servers << server
  rescue => e
    puts "Error fetching credentials for #{server_config['name'] || server_config['base_url']}: #{e.message}"
  end
end

if servers.empty?
  puts "No servers configured successfully. Exiting."
  exit 1
end

# Load Goodreads data once
puts "Loading Goodreads export..."
unless File.exist?(GOODREADS_EXPORT_FILE)
  puts "Error: #{GOODREADS_EXPORT_FILE} not found!"
  puts "Please export your Goodreads library and place the CSV file in the script directory."
  exit 1
end

goodreads_books = load_goodreads_data(GOODREADS_EXPORT_FILE)
puts "Loaded #{goodreads_books.length} books from Goodreads"

# Process each server
servers.each do |details|
  base_url = details[:base_url]
  username = details[:username]
  password = details[:password]

  puts "\nProcessing server: #{base_url}"

  # Login
  puts "Attempting login with username: #{username}"
  response = HTTP.post("#{base_url}/login", json: { username: username, password: password })
  unless response.status.success?
    puts "Failed to login to #{base_url}"
    puts "Status: #{response.status}"
    puts "Response: #{response.body}"
    next
  end

  token = JSON.parse(response.body).dig("user", "token")

  # Get first library
  libraries_response = HTTP.auth("Bearer #{token}").get("#{base_url}/api/libraries")
  first_library_id = JSON.parse(libraries_response.body).dig("libraries", 0, "id")

  puts "Fetching unfinished ABS books..."
  abs_books = fetch_unfinished_abs_books(base_url, token, first_library_id)
  puts "Found #{abs_books.length} unfinished books in ABS library"

  # Process matches
  current_batch = []
  batch_count = 0
  total_processed = 0
  matched_count = 0
  failed_matches = []

  # For testing, limit books if configured
  test_limit = CONFIG["test_limit"] || ENV["TEST_LIMIT"]
  test_books = test_limit ? abs_books.first(test_limit.to_i) : abs_books

  test_books.each_with_index do |abs_book, index|
    author_info = abs_book[:author] || "(extracted: #{abs_book[:original_author]})"
    puts "\nSearching for ABS book #{index + 1}/#{test_books.length}: #{abs_book[:title]} by #{author_info} [#{abs_book[:source]}]"

    match = find_goodreads_match(abs_book, goodreads_books)

    if match
      puts "Found match: #{match[:title]} by #{match[:author]} (confidence: #{match[:confidence].round(2)})"
      matched_count += 1

      # Add to batch if has read date
      if match[:date_read] && !match[:date_read].empty?
        finished_at = Date.strptime(match[:date_read], "%Y/%m/%d").to_time.to_i * 1000

        current_batch << {
          "libraryItemId" => abs_book[:id],
          "isFinished" => true,
          "finishedAt" => finished_at,
        }

        puts "Added to batch update queue - finished on #{match[:date_read]}"
      end
    else
      puts "No match found"
      failed_matches << {
        title: abs_book[:title],
        author: abs_book[:author],
        isbn: abs_book[:isbn],
        isbn13: abs_book[:isbn13],
        server: base_url
      }
    end

    # Send batch if full
    if current_batch.length >= BATCH_SIZE
      batch_count += 1
      total_processed += current_batch.length
      send_batch(current_batch, token, batch_count, total_processed, base_url, DRY_RUN)
      current_batch = []
    end
  end

  # Send final batch
  if current_batch.any?
    batch_count += 1
    total_processed += current_batch.length
    send_batch(current_batch, token, batch_count, total_processed, base_url, DRY_RUN)
  end

  puts "\nFinished processing #{total_processed} updates in #{batch_count} batches"
  puts "Matched #{matched_count} out of #{test_books.length} books (#{(matched_count.to_f / test_books.length * 100).round(1)}%)"

  # Save failed matches for this server
  if failed_matches.any?
    failed_file = "failed_matches_reverse_#{base_url.gsub(/[^\w]/, '_')}.log"
    File.write(failed_file, JSON.pretty_generate(failed_matches))
    puts "Failed to match #{failed_matches.length} books. See #{failed_file} for details."
  end
end

puts "\nReverse matching sync complete!"
puts "Run with DRY_RUN=true to test without making changes."
