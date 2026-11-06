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

## Local automations

A local automation (`runner: local`) runs as a Claude Code session on the user's machine. These
hold for it as well, and win over the rules above where they differ.

- **Draft, never post.** Results go into qm: `qm draft add` for PR review comments, `qm note` on
  the work item for everything else. Never post to GitHub, Slack or anywhere else; the user
  reviews and sends.
- **Unattended, on the user's machine.** Nobody watches the run: it uses the user's own
  permissions, files and logins, so it touches nothing outside its task and never stops on a
  question it needs answered to finish.
- **A cheap, deterministic guard.** The yml's `when:` runs on every due tick, so it is a fast
  command (no claude, no long network calls) that prints the same items for the same state. Each
  non-empty stdout line is one item: a JSON object with a string `key` plus the fields the flow
  needs (`url` for `flow: pr-review`), or a plain line that is its own key. A key is run once, ever,
  so make it name the work (a PR url and its head sha, a date), not the run. Exit non-zero only
  when the guard itself failed.
