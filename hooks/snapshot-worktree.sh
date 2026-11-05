#!/bin/sh
# Claude Code hook (UserPromptSubmit): records the session's git worktree as
# a tree object, so the GUI can diff everything changed since a prompt —
# Bash edits included, which Claude Code's own file history misses. Appends
# {v, session_id, cwd, toplevel, tree, at} to prompt-snapshots.jsonl.
#
# The tree is written through a throwaway copy of the worktree's index
# (GIT_INDEX_FILE): the real index, refs, stash and working tree are never
# touched. Plain sh, never prints, always exits 0; skips outside git, under
# QM_SKIP and in an aside (QM_ASIDE). The git work is capped at
# QM_SNAPSHOT_TIMEOUT seconds (default 5) so a huge worktree can't hold up a
# prompt — a killed snapshot writes no line.
{
  [ -n "$QM_SKIP" ] && exit 0
  [ -n "$QM_ASIDE" ] && exit 0
  payload=$(cat)
  field() {
    # Keys inside string values (the prompt) are escaped (\"), so they never match.
    printf '%s' "$payload" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n 1 |
      sed 's/.*:[[:space:]]*"\([^"]*\)"$/\1/' | tr -d '\\'
  }
  json_string() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
  session_id=$(field session_id)
  cwd=$(field cwd)
  [ -n "$session_id" ] && [ -n "$cwd" ] || exit 0
  cd "$cwd" || exit 0
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
  toplevel=$(git rev-parse --show-toplevel) || exit 0
  [ -n "$toplevel" ] || exit 0
  cd "$toplevel" || exit 0
  index=$(git rev-parse --path-format=absolute --git-path index) || exit 0
  root=${QM_ROOT:-$HOME/.claude/quartermaster}
  mkdir -p "$root" || exit 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/qm-snapshot.XXXXXX") || exit 0
  # An absent index (fresh repo) means start empty; git refuses an empty file.
  if [ -f "$index" ]; then cp "$index" "$tmp" || { rm -f "$tmp"; exit 0; }; else rm -f "$tmp"; fi
  at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  (
    GIT_INDEX_FILE=$tmp git add -A || exit 0
    tree=$(GIT_INDEX_FILE=$tmp git write-tree) || exit 0
    [ -n "$tree" ] || exit 0
    printf '{"v":1,"session_id":"%s","cwd":"%s","toplevel":"%s","tree":"%s","at":"%s"}\n' \
      "$(json_string "$session_id")" "$(json_string "$cwd")" "$(json_string "$toplevel")" \
      "$tree" "$at" >> "$root/prompt-snapshots.jsonl"
  ) &
  work=$!
  limit=${QM_SNAPSHOT_TIMEOUT:-5}
  (
    sleep "$limit"
    if kill -0 "$work" 2>/dev/null; then pkill -P "$work"; kill "$work"; fi
  ) &
  watchdog=$!
  wait "$work"
  # The watchdog is stopped, never waited for.
  pkill -P "$watchdog"
  kill "$watchdog"
  rm -f "$tmp" "$tmp.lock"
} >/dev/null 2>&1
exit 0
