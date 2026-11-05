---
name: draft-issues
description: Draft one or more GitHub issues for the user to review in qm's Issues pane (or a live artifact page outside qm), one issue per tab with copyable markdown, revised in place until they say to create them. Use when they ask to draft, write up or split work into issues.
---

# Draft issues

The user reviews issue drafts on one page instead of in chat, so a revision to one issue never makes them scroll past the others.

**Where the drafts live.** When the `[qm]` injection linked this session to a work item, the page is qm's Issues pane: run `qm issues-dir <slug>` for the directory and write one file per issue there, `NN-short-name.md` (the `NN-` prefix sets the order), YAML frontmatter then the exact issue body:

```markdown
---
title: AAU I can do the thing
kind: feature        # or bug
group: Import        # nav section; sections appear in first-seen order
parent: 120          # epic number, or leave empty
deps: [123, "AAU I can other thing"]   # numbers, or titles of other drafts; [] for none
change: ""           # what changed in the latest revision; "" when unchanged
---
```

The user reads and annotates them in qm; their comments arrive in the chat as one pasted message. Steps 4–5 then become "write the files and tell the user they are in the Issues pane", step 6 edits only the changed files, and step 7 ends by adding `number: <n>` to each created file's frontmatter and a `qm note <slug> --kind history` listing the numbers. Anywhere else (no linked item), use the artifact page [`helpers/issue-drafts.html`](helpers/issue-drafts.html), as below; each issue is one `<script type="text/markdown">` block in it, holding the exact issue body.

## Steps

1. **Settle the list.** Each issue is a **vertical slice**: a thin but complete path through every layer (schema, API, UI, tests), demoable on its own; name each by its title (see [Titles](#titles)). A wide refactor (one mechanical change fanning across the codebase) goes **expand–contract** instead: an issue adding the new form beside the old, migrate issues in batches that each depend on it, and a contract issue removing the old form that depends on every batch. Ask which epic the issues belong to when the user hasn't said. Done when every piece of the work maps to exactly one issue, each issue has its parent (or none), and the user has agreed the split.
2. **Check every claim against main.** `git fetch origin`, then read what the draft states as current behavior with `git show origin/main:<path>`. Work that exists only on an unmerged branch is written as an instruction ("Give `FileDownloader` a `max_size:`"), never as a fact ("`FileDownloader` takes `max_size:`"). A bug that only appears after the branch's own change is not a bug on main; fold it into the issue that introduces it. Done when every "today …" sentence in every draft is true on `origin/main`.
3. **Write each body** from the repo's issue template when it has one (`.github/ISSUE_TEMPLATE/*.md`, e.g. a feature and a bug-report template; keep their headings, drop their HTML comments). Rules in [Writing the body](#writing-the-body). Done when each draft has the template's sections and nothing beyond them.
4. **Build the page.** Copy the helper into the session scratchpad as `<topic>-issue-drafts.html`, fill `{{PAGE_TITLE}}` (a 2–4 word name) and `{{HEADING}}`, and replace the example block with one block per issue, in order. The attributes are documented in the comment above the example block. Leave every `data-change` empty on the first publish.
5. **Publish.** The Artifact tool wants `action: "quickstart"` (intent `other`, `design_systems: false`) before a new artifact; then publish the file with `icon: "list"` and a one-sentence description. Give the user the link.
6. **Revise in place** on every round of feedback: edit only the blocks that change, set their `data-change` to one sentence saying what changed, clear `data-change` on every block that did not change this round, and republish the same file path (same URL). Reply with one line per changed issue and the link; the page holds the text.
7. **Create on GitHub only when the user says so.**
   - Per issue: `gh issue create --title … --body-file …`, extracting the body from its block; add the labels its template sets.
   - Link the parents and dependencies where the project tracks them. When the session has an issue tracker's MCP tools (a project board that keeps parents and blockers), use those: find each new issue there by searching its title and taking the result whose number matches (a just-created issue can take a moment to arrive; search again if it is missing), set each `parent`'s children, and add one blocking relation per `deps` entry (the issue blocked by the one it depends on). Otherwise make each issue a GitHub sub-issue of its parent (`gh api --method POST repos/{owner}/{repo}/issues/<parent>/sub_issues -F sub_issue_id=<the child's id>`) and list the dependencies in your report for the user to set.

   Done when each new issue shows its parent and dependencies where they were set. Report the issue numbers and links.

## Titles

An issue title is a user story, never a commit subject. Bugs are the one exception.

- **Feature**: who gains what, in the product's words. The role is always abbreviated: `AA` plus the initial of each word of the role, so "As a user" is `AAU`, "As an admin" is `AAA` and "As a power user" is `AAPU`. `AAU I can comment on a shared draft`, `AAA I can choose which external contents are imported`.
- **Bug**: no user story; the title states what is wrong or what should happen. `Sent feedback page does not show a comment until the page is reloaded`, `Page through a teacher's courses correctly`.

## Writing the body

- **Short.** Context is one or two paragraphs of why. Development notes name the decisions and the places in the code, not the implementation; an endpoint list is a table with one link to the docs, not prose.
- **Acceptance criteria are what a tester checks** in the product. A code-level safeguard (a validation rule, a lock, a migration's rollback limit) goes in the development notes.
- **Dependencies are links, not text.** The body carries no "requires #…", "prerequisite for #…" or "builds on #…"; put the dependency in the block's `data-deps` (issue numbers, or names of other drafts before they have numbers); step 7 sets them. A link that explains related work stays ("Imports moved to a background job in #123").
- **Facts from testing carry their source**: what was tested, where, and when ("with the student token the external API answers 403, tested 2026-10-16 on its staging server"). Anything not verified is phrased as a question or left out.
- **Open decisions go under `# Questions`**, with what is already known that helps answer them.
- **Out of scope** names what a reader would otherwise ask about, nothing more.
