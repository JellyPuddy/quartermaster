#!/bin/sh
# Claude Code hook (PostToolUse, matcher ArtifactData): appends the full hook
# payload as one line {v, ts, payload} to board-writes.jsonl, so qm can mirror
# delegate-build status boards locally. Never fails, never prints.
{
  [ -n "$QM_SKIP" ] && exit 0
  # JSON never holds a raw newline inside a string, so folding newlines into
  # spaces keeps a pretty-printed payload valid on one line.
  payload=$(tr '\n\r' '  ')
  case "$payload" in
    \{*) ;;
    *) exit 0 ;;
  esac
  root=${QM_ROOT:-$HOME/.claude/quartermaster}
  mkdir -p "$root"
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"v":1,"ts":"%s","payload":%s}\n' "$ts" "$payload" >> "$root/board-writes.jsonl"
} >/dev/null 2>&1
exit 0
