#!/usr/bin/env ruby
# frozen_string_literal: true

require "net/http"
require "json"
require "csv"
require "uri"
require "time"

DISQUS_API   = "https://disqus.com/api/3.0/forums/listThreads.json"
TELEGRAM_API = "https://api.telegram.org/bot%<token>s/sendMessage"
CSV_PATH     = File.expand_path("../data/comments.csv", __dir__)
TITLE_SUFFIX = " | @zhisme :: signal over noise"
MAX_PAGES    = 50
TG_LIMIT     = 4096

def env!(name)
  v = ENV[name]
  abort "missing env #{name}" if v.nil? || v.empty?
  v
end

def fetch_threads(api_key, forum)
  rows = []
  cursor = nil
  pages = 0

  loop do
    pages += 1
    abort "disqus pagination exceeded #{MAX_PAGES} pages" if pages > MAX_PAGES

    params = { api_key: api_key, forum: forum, limit: 100 }
    params[:cursor] = cursor if cursor
    uri = URI(DISQUS_API)
    uri.query = URI.encode_www_form(params)

    res = Net::HTTP.get_response(uri)
    body = res.body.to_s
    raise "disqus http error status=#{res.code} body=#{body[0, 200]}" unless res.code == "200"

    data = JSON.parse(body)
    code = data["code"]
    raise "disqus api error code=#{code} body=#{body[0, 200]}" unless code == 0

    Array(data["response"]).each { |t| rows << t }

    cur = data["cursor"] || {}
    break unless cur["hasNext"]

    cursor = cur["next"]
  end

  rows
end

def clean_title(raw)
  t = raw.to_s
  t = t.sub(/#{Regexp.escape(TITLE_SUFFIX)}\z/, "")
  t.strip
end

def build_rows(threads, checked_at)
  threads.map { |t|
    {
      slug:       t["slug"].to_s,
      title:      clean_title(t["title"]),
      link:       t["link"].to_s,
      posts:      t["posts"].to_i,
      checked_at: checked_at,
    }
  }.sort_by { |r| r[:slug] }
end

def read_prev(path)
  return nil unless File.exist?(path)

  map = {}
  CSV.foreach(path, headers: true) do |row|
    map[row["slug"]] = row["posts"].to_i
  end
  map
end

def write_csv(path, rows)
  CSV.open(path, "w", force_quotes: true) do |csv|
    csv << %w[slug title link posts checked_at]
    rows.each { |r| csv << [r[:slug], r[:title], r[:link], r[:posts], r[:checked_at]] }
  end
end

def compute_deltas(rows, prev_map)
  deltas = []
  rows.each do |r|
    prev = prev_map[r[:slug]]
    if prev.nil?
      deltas << { kind: :new, slug: r[:slug], title: r[:title], link: r[:link], prev: 0, curr: r[:posts] }
    elsif r[:posts] > prev
      deltas << { kind: :inc, slug: r[:slug], title: r[:title], link: r[:link], prev: prev, curr: r[:posts] }
    end
  end
  deltas
end

def build_message(deltas, rows, prev_map, date)
  lines = []
  lines << "\xF0\x9F\x94\x94 New blog comments (#{date})"
  lines << ""

  rendered = []
  deltas.each do |d|
    diff = d[:curr] - d[:prev]
    rendered << "• #{d[:title]}: #{d[:prev]} → #{d[:curr]} (+#{diff})\n  #{d[:link]}"
  end

  prev_total = prev_map.values.sum
  curr_total = rows.sum { |r| r[:posts] }
  total_line = "Total: #{prev_total} → #{curr_total} (+#{curr_total - prev_total})"

  truncated = 0
  loop do
    body_lines = rendered.dup
    body_lines << "...and #{truncated} more" if truncated > 0
    msg = (lines + body_lines + ["", total_line]).join("\n")
    return msg if msg.bytesize <= TG_LIMIT
    break if rendered.empty?

    rendered.pop
    truncated += 1
  end

  (lines + ["...and #{truncated} more", "", total_line]).join("\n")
end

def notify(token, chat_id, text)
  uri = URI(format(TELEGRAM_API, token: token))
  res = Net::HTTP.post_form(uri, {
    "chat_id"                  => chat_id,
    "text"                     => text,
    "disable_web_page_preview" => "true",
  })
  raise "telegram http error status=#{res.code} body=#{res.body.to_s[0, 500]}" unless res.code == "200"
end

api_key = env!("DISQUS_API_KEY")
forum   = ENV["DISQUS_FORUM"] || "zhisme"
tg_tok  = ENV["TELEGRAM_BOT_TOKEN"]
tg_chat = ENV["TELEGRAM_CHAT_ID"]

now = Time.now.utc
checked_at = now.iso8601
date_str   = now.strftime("%Y-%m-%d")

threads = fetch_threads(api_key, forum)
rows    = build_rows(threads, checked_at)
prev    = read_prev(CSV_PATH)

write_csv(CSV_PATH, rows)

if prev.nil?
  puts "first run, seeding #{rows.size} threads to #{CSV_PATH}"
  exit 0
end

deltas = compute_deltas(rows, prev)

puts "threads=#{rows.size} new=#{deltas.count { |d| d[:kind] == :new }} increased=#{deltas.count { |d| d[:kind] == :inc }}"

if deltas.empty?
  puts "no changes"
  exit 0
end

deltas.each do |d|
  marker = d[:kind] == :new ? "NEW" : "INC"
  puts "#{marker} #{d[:slug]} #{d[:prev]}->#{d[:curr]}"
end

if tg_tok && !tg_tok.empty? && tg_chat && !tg_chat.empty?
  msg = build_message(deltas, rows, prev, date_str)
  notify(tg_tok, tg_chat, msg)
  puts "telegram sent bytes=#{msg.bytesize}"
else
  puts "telegram skipped (no TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID)"
end
