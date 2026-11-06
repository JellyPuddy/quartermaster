#!/usr/bin/env ruby
# Claude Code status line - robbyrussell (Oh My Zsh) style
# Left:  ➜ dir git:(branch) ✗ | [Model]
# Right: ctx [bar] XX% | 5h [bar] XX% (2h15m) · wk [bar] XX% (3d4h)
#
# Ruby port of statusline-command.sh (kept in place for rollback). Behavior is
# intended to be a 1:1 match; see the "differences" note at the end of the
# accompanying commit/PR description for the couple of edge cases where Ruby
# and bash/printf/tput can diverge (rounding mode, tput fallback).
#
# Runs under /usr/bin/ruby (macOS system Ruby 2.6): the one file in this repo
# exempt from the 3.3 syntax floor, and it loads nothing from lib/. Pinned by
# test/statusline_test.rb.

require 'json'
require 'shellwords'
require 'time'
require 'fileutils'

# Colors (dimmed-friendly, ANSI)
GREEN = "\033[0;32m"
YELLOW = "\033[0;33m"
CYAN = "\033[0;36m"
BLUE = "\033[0;34m"
VIVID_BLUE = "\033[1;94m"
MAGENTA = "\033[0;35m"
RED = "\033[0;31m"
DIM = "\033[2m"
RESET = "\033[0m"

# Title of the Quartermaster work item this session is linked to, or nil. Shells out
# to the `qm` CLI so it stays the single source of truth for the session→item mapping;
# any failure (qm missing, unlinked, error) degrades silently to no second line.
def work_item_title(session_id)
  return nil unless session_id && !session_id.empty?

  qm = ['~/bin/qm', '~/bin/quartermaster', '~/code/quartermaster/quartermaster'].map { |p| File.expand_path(p) }.find { |p| File.executable?(p) }
  return nil unless qm

  title = `#{qm.shellescape} session-item #{session_id.shellescape} 2>/dev/null`.strip
  title.empty? ? nil : title
rescue StandardError
  nil
end

# Where qm keeps its data; the rate-limits snapshot goes there.
def qm_root
  File.expand_path(ENV['QM_ROOT'] || '~/.claude/quartermaster')
end

# Writes the account's rate limits to <qm root>/rate-limits.json for the qm GUI
# and the work-items page. Whole-file replace via tmp + rename, so a reader
# never sees a torn file and the last session to render wins (limits are per
# account, every session sees the same numbers). Never creates qm's data dir,
# and never lets a failure reach the status line.
def write_rate_limits_snapshot(rate_limits)
  return unless rate_limits.is_a?(Hash)

  root = qm_root
  return unless File.directory?(root)

  window = lambda do |key|
    w = rate_limits[key]
    w.is_a?(Hash) ? { 'used_percentage' => w['used_percentage'], 'resets_at' => w['resets_at'] } : nil
  end
  snapshot = {
    'v' => 1,
    'five_hour' => window.call('five_hour'),
    'seven_day' => window.call('seven_day'),
    'captured_at' => Time.now.utc.iso8601
  }
  tmp = File.join(root, ".rate-limits.json.#{Process.pid}.tmp")
  File.write(tmp, JSON.generate(snapshot))
  File.rename(tmp, File.join(root, 'rate-limits.json'))
rescue StandardError
  nil
ensure
  begin
    FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
  rescue StandardError
    nil
  end
end

# How many qm.log errors the user hasn't marked seen: lib's ErrorLog parse,
# repeated because this file never loads lib/. A header line not tagged
# transient or recovered, newer than <qm root>/errors-seen-at (else the last
# day), within the log's last 256 KB. A log untouched since then is skipped
# unread. Any failure counts as none.
def qm_error_count
  log = File.join(qm_root, 'qm.log')
  since =
    begin
      Time.iso8601(File.read(File.join(qm_root, 'errors-seen-at')).strip)
    rescue StandardError
      Time.now - 86_400
    end
  return 0 unless File.file?(log) && File.mtime(log) > since

  text = File.open(log, 'rb') do |f|
    start = [f.size - 262_144, 0].max
    f.seek(start)
    chunk = f.read.to_s
    start.zero? ? chunk : chunk.partition("\n").last
  end
  text.each_line.count do |line|
    header = /\A(\S+) \[[^\]]*\] (.*)/.match(line)
    next false if header.nil? || header[2] =~ /\A(?:transient |recovered after )/

    begin
      Time.iso8601(header[1]) > since
    rescue ArgumentError
      false
    end
  end
rescue StandardError
  0
end

# True inside a chat qm runs in its own tmux server (`tmux -L qm`, or the
# QM_TMUX_SOCKET a test GUI uses). $TMUX is "<socket path>,<pid>,<session>".
def in_qm_chat?
  socket_path = ENV['TMUX'].to_s.split(',').first.to_s
  return false if socket_path.empty?

  names = ['qm', ENV['QM_TMUX_SOCKET']].compact.reject(&:empty?)
  names.include?(File.basename(socket_path))
end

# Formats remaining seconds as "XhYm" (hours+minutes, no seconds).
def format_hours_minutes(remaining_seconds)
  remaining_seconds = 0 if remaining_seconds < 0
  h = remaining_seconds / 3600
  m = (remaining_seconds % 3600) / 60
  format('%dh%dm', h, m)
end

# Formats remaining seconds as "XdYh" (days+hours). Falls back to hours+minutes
# when under 24h remaining.
def format_days_hours(remaining_seconds)
  remaining_seconds = 0 if remaining_seconds < 0
  return format_hours_minutes(remaining_seconds) if remaining_seconds < 86_400

  d = remaining_seconds / 86_400
  h = (remaining_seconds % 86_400) / 3600
  format('%dd%dh', d, h)
end

# Renders a small filled/empty block bar for a 0-100 percentage, colored
# green/yellow/red by how much headroom remains.
def make_bar(pct)
  width = 8
  pct = 0 if pct < 0
  pct = 100 if pct > 100
  filled = (pct * width + 50) / 100
  empty = width - filled
  bar = ('█' * filled) + ('░' * empty)

  color =
    if pct >= 80
      RED
    elsif pct >= 50
      YELLOW
    else
      GREEN
    end

  "#{color}#{bar}#{RESET}"
end

# Returns the visible (post-ANSI-stripping) character count of a string.
def visible_length(str)
  str.gsub(/\x1b\[[0-9;]*m/, '').length
end

# Mimics `printf '%.0f'` (round-half-to-even at the C library level) closely
# enough for status-line purposes using standard round-half-up.
def round_pct(value)
  value.round
end

input = JSON.parse($stdin.read)

cwd = (input.dig('workspace', 'current_dir') || input['cwd']).to_s
dir = File.basename(cwd)

model = input.dig('model', 'display_name')

write_rate_limits_snapshot(input['rate_limits'])

# A qm GUI chat already shows its item and the limits around the terminal.
qm_chat = in_qm_chat?

# Second status line: the Quartermaster work item this session is linked to (blank if none).
item_title = qm_chat ? nil : work_item_title(input['session_id'])
item_line = item_title ? "\n#{MAGENTA}◆#{RESET} #{DIM}#{item_title}#{RESET}" : ''

used = input.dig('context_window', 'used_percentage')

five_hour = qm_chat ? nil : input.dig('rate_limits', 'five_hour', 'used_percentage')
seven_day = qm_chat ? nil : input.dig('rate_limits', 'seven_day', 'used_percentage')
five_hour_resets_at = input.dig('rate_limits', 'five_hour', 'resets_at')
seven_day_resets_at = input.dig('rate_limits', 'seven_day', 'resets_at')

now = Time.now.to_i

git_part = ''
if system('git', '-C', cwd, '--no-optional-locks', 'rev-parse', '--is-inside-work-tree',
          out: File::NULL, err: File::NULL)
  branch = `git -C #{cwd.shellescape} --no-optional-locks symbolic-ref --short HEAD 2>/dev/null`.strip
  if branch.empty?
    branch = `git -C #{cwd.shellescape} --no-optional-locks rev-parse --short HEAD 2>/dev/null`.strip
  end

  if !branch.empty?
    dirty = !`git -C #{cwd.shellescape} --no-optional-locks status --porcelain 2>/dev/null`.strip.empty?
    git_part =
      if dirty
        " #{BLUE}git:(#{RED}#{branch}#{BLUE})#{RESET} #{RED}✗#{RESET}"
      else
        " #{BLUE}git:(#{RED}#{branch}#{BLUE})#{RESET}"
      end
  end
end

left = "#{GREEN}➜#{RESET} #{CYAN}#{dir}#{RESET}#{git_part}"

left = "#{left} | #{VIVID_BLUE}[#{model}]#{RESET}" if model && !model.empty?

# Unseen qm errors; a qm chat has the GUI's badge right above it.
error_count = qm_chat ? 0 : qm_error_count
left = "#{left} #{RED}⚠ #{error_count} qm error#{'s' unless error_count == 1}#{RESET}" if error_count > 0

# Build the usage segment (ctx / 5h / weekly), omitted entirely when no data present.
usage_part = ''

if used
  used_rounded = round_pct(used)
  used_bar = make_bar(used_rounded)
  ctx_chunk = "ctx [#{used_bar}] #{used_rounded}%"
  usage_part = used_rounded >= 80 ? "#{RED}#{ctx_chunk}#{RESET}" : ctx_chunk
end

if five_hour
  five_hour_rounded = round_pct(five_hour)
  five_hour_bar = make_bar(five_hour_rounded)
  five_hour_chunk = "5h [#{five_hour_bar}] #{five_hour_rounded}%"
  if five_hour_resets_at
    five_hour_countdown = format_hours_minutes(five_hour_resets_at.to_i - now)
    five_hour_chunk = "#{five_hour_chunk} (#{five_hour_countdown})"
  end
  usage_part = "#{usage_part} | " unless usage_part.empty?
  usage_part += five_hour_rounded >= 80 ? "#{RED}#{five_hour_chunk}#{RESET}" : five_hour_chunk
end

if seven_day
  seven_day_rounded = round_pct(seven_day)
  seven_day_bar = make_bar(seven_day_rounded)
  seven_day_chunk = "wk [#{seven_day_bar}] #{seven_day_rounded}%"
  if seven_day_resets_at
    seven_day_countdown = format_days_hours(seven_day_resets_at.to_i - now)
    seven_day_chunk = "#{seven_day_chunk} (#{seven_day_countdown})"
  end
  usage_part = "#{usage_part} · " unless usage_part.empty?
  usage_part += seven_day_rounded >= 80 ? "#{RED}#{seven_day_chunk}#{RESET}" : seven_day_chunk
end

if usage_part.empty?
  print left + item_line
  exit 0
end

# Claude Code renders the status line with some of its own margin/chrome that
# terminal-width detection doesn't account for, so leave a safety buffer to
# avoid truncation.
SAFETY_MARGIN = 5

term_width =
  begin
    cols = `tput cols 2>/dev/null`.strip
    cols.empty? ? nil : Integer(cols)
  rescue StandardError
    nil
  end
term_width ||= Integer(ENV['COLUMNS'] || 80)
term_width -= SAFETY_MARGIN

left_len = visible_length(left)
usage_len = visible_length(usage_part)
padding = term_width - left_len - usage_len
padding = 1 if padding < 1

print left + (' ' * padding) + usage_part + item_line
