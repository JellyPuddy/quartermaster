---
name: branch-stats
description: Rundown of lines changed on the current branch versus main - totals by category (backend, frontend, tests, generated, docs, ...), largest files, and a per-commit breakdown. Use when the user asks "how big is this PR", "lines changed per commit", "how much of this is tests/generated code", or invokes /branch-stats [base-ref].
---

# Branch stats

Run the bundled script from the repository root and relay its output verbatim as the answer.
It prints markdown that renders as-is in the terminal:

```bash
~/.claude/skills/branch-stats/scripts/branch-stats.sh [base-ref] [head-ref]
```

- `base-ref` defaults to `origin/main` (fetched first; falls back to `main`). Pass another ref
  for stacked branches, e.g. the parent branch of the stack.
- `head-ref` defaults to `HEAD`.
- Line counts are `git diff --numstat` against the merge base. Per-commit rows sum to more than
  the branch total when later commits rework files from earlier ones; the script says so in the
  table caption, do not re-explain it.

qm's diff pane (📊) runs the same script and parses its markdown, so keep its output format when
editing it.

## Categories

Classification is by path, in this priority order: generated (`__generated__/`, a generated API
client under `app/javascript/api/`, `*.generated.*`, `db/schema.rb`, lockfiles), tests (`spec/`,
`test/`, `__tests__/`, `*.spec.*`, `*.test.*`, `e2e/`), openapi (`docs/api/`), docs (`docs/`,
`*.md`), locales (`config/locales/`), migration (`db/migrate/`), frontend (`app/javascript/`,
`.erb`, `.tsx`, `.css`), config (Gemfile, package.json, lint/TS configs, `.github/`), everything
else backend. Edit the `cat()` function in the script to change this for a repository with a
different layout.

## After the tables

Add two or three sentences of what stands out, drawn from the numbers: which commit carries the
real change, whether a big commit is mostly generated fan-out (locale JSON, a generated API
client), and the approximate hand-written non-test surface (backend + frontend + docs + openapi +
locales). Do not restate the tables in prose, and do not editorialize about whether the PR is too
large unless asked.
