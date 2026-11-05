#!/bin/sh
# Claude Code hook (PermissionRequest, Stop, StopFailure, UserPromptSubmit,
# PostToolUse, PostToolUseFailure): appends one slim line
# {v, ts, session_id, event, tool, agent} to events.jsonl, from
# which qm derives each chat's attention state. Plain sh, no Ruby startup:
# PostToolUse fires on every tool call. Never fails, never prints. An aside
# (QM_ASIDE set) logs nothing: it never asks for attention.
{
  [ -n "$QM_SKIP" ] && exit 0
  [ -n "$QM_ASIDE" ] && exit 0
  payload=$(cat)
  # Every field read here is top-level and precedes tool_input (agent_id
  # included, per a captured payload); cutting there keeps a nested object in
  # tool_input/tool_response from supplying a decoy key.
  top=${payload%%\"tool_input\"*}
  field() {
    # Keys inside string values are escaped (\"), so they never match.
    printf '%s' "$top" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n 1 |
      sed 's/.*:[[:space:]]*"\([^"]*\)"$/\1/' | tr -d '\\'
  }
  session_id=$(field session_id)
  [ -n "$session_id" ] || exit 0
  event=$(field hook_event_name)
  tool=$(field tool_name)
  # Present only for a sub-agent's tool call; background sub-agents keep
  # calling tools after the main turn's Stop, which must not read as working.
  agent=$(field agent_id)
  root=${QM_ROOT:-$HOME/.claude/quartermaster}
  mkdir -p "$root"
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"v":1,"ts":"%s","session_id":"%s","event":"%s","tool":"%s","agent":"%s"}\n' \
    "$ts" "$session_id" "$event" "$tool" "$agent" >> "$root/events.jsonl"
} >/dev/null 2>&1
exit 0
