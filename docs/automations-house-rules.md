# Automation house rules

Every automation's prompt follows these, unless the automation's own description says otherwise.

- **Read-only.** The routine reads and reports; it changes nothing (no pushes, comments, labels,
  issue or PR edits) unless the automation explicitly says it may.
- **Slack only to verified channel ids.** Post only to the channel or DM ids written in the prompt,
  each one checked by hand. Never look up a channel or person by name, and never message anyone else.
- **Fail loudly, never invent.** When a fetch fails, send one short failure line with the error
  instead of the report. Never fill a gap with guessed or made-up data.
- **No GraphQL in the cloud environment.** It is blocked there: use the REST API and page through
  results explicitly (`gh api --paginate` fails past page 1).
- **Short messages.** Keep every message under 5000 characters.
