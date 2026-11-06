# Settings

**Code:** `lib/quartermaster/config_schema.rb`, `lib/quartermaster/config_check.rb`, `lib/quartermaster/config_file.rb`, `lib/quartermaster/cli_config.rb`, `lib/quartermaster/gui_settings.rb`
**Tests:** `test/config_file_test.rb`, `test/config_cli_test.rb`, `test/gui_settings_test.rb`
**Depends on:** [capture](capture.md) (`ProjectConfig` reads the same file), [gui-shell](gui-shell.md) (the router and its Origin guard)

## What it does

`config.yml` (the key reference is [overview §config.yml](../overview.md#configyml)) is edited
through one core, so every editor refuses exactly the same things.

**Schema** — `ConfigSchema` lists every key once: its dotted path (`*` for a map key: a project
name, a starter key, a model), type, help, Settings section, `collapsed` (rarely changed) and
what an unset value falls back to (`inherits` another key, or a `default`). Types: `string`,
`path`, `text` (multi-line), `bool`, `number`, `string_list`, `argv` (an array holding `PATH`)
and `enum` (one of the values `options_from` names: `dev_server.default_mode` from its sibling
`modes`, `default_project` from the project names). `CONTAINERS` are the mappings keys live in:
a `map` takes any key, an `object` only its listed ones; a container's `shorthand` is the key a
plain string stands for (a project given as a path is its `root`, a `dev_server` given as a name
its `command`). `lookup` / `container` / `known?` resolve a concrete dotted path; `payload` is the
schema as JSON for the GUI form. `features(config, issues)` gives the Settings grid: per project,
per feature (dev server, test db, review, ships by release, benchmarks, IDE) a cell
`{state, value, title}`, read through `ProjectSettings` so it says what qm would do: `on` with a
short value (`pf · 4 modes`, the test-DB command, the database), `off`, `inherit` (review →
`default`, IDE → `global`; the title names the real value), or `error` / `warning` when an issue
sits under the feature's keys.

**Check** — `ConfigCheck` returns issues `{level, path, message}`. Errors: unparsable YAML or a
non-mapping file, a value of the wrong type, a key the schema doesn't list under a mapping it
governs (`projects.App.typo`), a project without a root, an argv without `PATH` or a program, a
benchmark with only one of database/skill or a database that isn't `\w+`, a `default_mode` not in
`modes`, a `default_project` that isn't a project, a loose starter without a prompt, `dev_server`
keys without a command. Warnings: a root, benchmark skill or state-file folder missing, a
dev-server or test-DB command not on `PATH` (or `~/bin`), an `ide_label` without `ide_command`. The
folder and PATH checks go through a `Probe`; tests pass a stub.

**File** — `ConfigFile.load` holds the text, the parsed mapping and the text's SHA-256 digest.
`get` / `set` / `unset` take dotted paths (opening a shorthand into its mapping); `set` refuses a
path the schema doesn't know, `unset` also takes an unknown key under a governed mapping (to
drop a typo). `ConfigFile.parse_value` reads a CLI value as YAML (`[dev, ngrok]` a list, `true` a
bool, `4` a number; unreadable text stays a string). `replace` swaps in a whole mapping (the GUI's
draft). `write!(digest:)` refuses with `Invalid` (carrying the issues) while there are errors and
with `Stale` when the file's digest isn't the one the editor loaded; otherwise it writes a temp
file in the same folder, copies the old file to `config.yml.bak` and renames the temp file over.

**Layout** — `ConfigFile.emit`: the header line
`# Edited by qm (Settings view / qm config); key reference: docs/overview.md`, then `projects`
(in the user's order), `default_project`, `ide_command`, `ide_label`, `loose_starters`,
`overview_artifact`, `prices`, then unknown top-level keys as they were. Keys inside a mapping
follow the schema's order; unset values (nil, blank text, empty lists) and emptied sub-mappings are
dropped and a bare `projects:` (the earlier seed's) is `projects: {}` (`ConfigCheck.tidy`); a project holding only its root is written as the plain path; lists
of scalars are flow style (`[dev, tunnel]`); multi-line text is a `|` block; paths stay unquoted.
The first-run seed (`CONFIG_SEED`) is exactly what `emit` writes for `projects: {}`.
`ConfigFile.dump` is the same emitter for any value, with no header.

**CLI** — `qm config` (`CliConfig`, a [cli](cli.md) command group) loads, changes and writes in
one go, so a CLI write is never stale unless the file changes mid-command. `get` with no path
prints the file as it is; with a path, a scalar prints bare (shell-usable) and a subtree as
`dump`ed YAML; an unset key prints nothing and exits 1. `set PATH VALUE` reads VALUE with
`parse_value` and echoes `PATH: value` as written; `unset PATH` of an absent key says so and
writes nothing; `path` prints the file's location. A path the schema doesn't know (`set`, `get`, `unset`, even when absent)
fails as `qm: unknown config key: …`. Every error the edited file has goes to stderr as
`qm: error: <path>: <message>`, exit 1, nothing written; warnings about the changed path (at,
under or above it) go to stderr as `qm: warning: …` after the write, exit 0. `unset projects.X`
warns how many work items still have `project: X` (they keep it; `qm move` reassigns).

**GUI endpoints** (`GuiSettings`, routed by `Gui#respond`). `GET /api/settings` is the form's
payload: `schema` (`ConfigSchema.payload`), `config` (the file's mapping normalized for the form:
tidied, every shorthand opened into its mapping, ungoverned keys as they are; `{}` when the file
doesn't parse, with that error in `issues`), `digest`, `issues`, `features` (the grid's cells per
project), `items` (work items per project name; a name missing is 0), `priceDefaults`
(`PriceTable::DEFAULTS`) and `path` (the file). `POST /api/settings/check {config}` answers
`{issues, features}` for a draft and writes nothing. `POST /api/settings/save {config, digest}`
answers `{ok: true, settings, state}` — the new payload (its new digest) and a state build made
after the write (the cached dev-server status forgotten), so the page's buttons follow at once;
`409 {ok: false, stale: true, error, settings}` when the file changed since `digest`, carrying the
current payload to reload; `422 {ok: false, error, issues, features}` while the draft has errors.

## Rules

- `ConfigSchema` is the one list of config keys: a new key goes there, in docs/overview.md
  §config.yml (a test checks every path is named) and nowhere else as a hand-kept list.
- qm owns the written layout: every write re-emits the whole file and drops comments.
- Keys the schema doesn't govern (unknown top-level keys and their subtrees) are kept verbatim;
  an unknown key under a governed mapping is an error, never silently dropped.
- Errors block a write; warnings never do — a folder or command may be missing only on this
  machine or only right now.
- A write is atomic (temp file + rename in the same folder), keeps the previous file as
  `config.yml.bak`, and is refused as stale when the file changed since the editor loaded it.
- Projects are never renamed (work items store the name): renaming is remove + add.
- Validation lives here only; the GUI never re-implements it in JS: the page posts its draft to
  check.
- The settings POSTs are the page's: they need our `Origin` and are not in
  `LoopbackGuard::LOCAL_ACTIONS` (a local tool edits config through `qm config`).
- The settings routes stay off the action mutex: the write is quick and serialised by
  `GuiSettings`' own lock, the digest keeps editors apart, and the state build after a save runs
  outside every lock.

## Data

- `config.yml` — the file; `config.yml.bak` — the file as it was before qm's last write.
