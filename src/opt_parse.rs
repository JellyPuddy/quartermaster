//! The option spellings a command takes, as Ruby's `OptionParser` read them: `--name value`,
//! `--name=value`, `-n 5`, `-n5`, any unambiguous abbreviation of a long option, options anywhere among
//! the arguments. `normalize` rewrites a command's arguments into the one form its own parser reads
//! (`--name`, then its value as the next argument) or says what is wrong the way OptionParser worded it.

use crate::outcome::{abort, Outcome};

struct Opt {
    name: &'static str,
    arg: bool,
    int: bool,
}

const fn flag(name: &'static str) -> Opt {
    Opt { name, arg: false, int: false }
}
const fn val(name: &'static str) -> Opt {
    Opt { name, arg: true, int: false }
}
const fn num(name: &'static str) -> Opt {
    Opt { name, arg: true, int: true }
}

/// How a command words a refusal of its options.
#[derive(Clone, Copy)]
enum Say {
    /// `qm: MESSAGE`
    Plain,
    /// `PREFIX: MESSAGE` and then the usage line
    WithUsage(&'static str, &'static str),
    /// `PREFIX: MESSAGE`
    Prefixed(&'static str),
}

struct Spec {
    opts: &'static [Opt],
    /// The command takes its first argument (the slug) before any option is read.
    slug_first: bool,
    say: Say,
}

macro_rules! opts {
    ($($o:expr),* $(,)?) => {{
        const O: &[Opt] = &[$($o),*];
        O
    }};
}

const SESSION: &[Opt] = &[val("--session")];
const PR_REQUIRES_USAGE: &str = "usage: qm pr-requires PR-OR-SHA [--pr PR] [--note TEXT] | --remove PR-OR-SHA [--pr PR] | --list [--pr PR]";
const DRAFT_USAGE: &str = "usage: qm draft add SLUG --path P --line N [options] (--body TEXT | --body-file F) | qm draft list SLUG [--json]";

fn spec(command: &str, args: &[String]) -> Option<Spec> {
    let plain = |opts, slug_first| Some(Spec { opts, slug_first, say: Say::Plain });
    match command {
        "new" => plain(opts![val("--project"), val("--branch"), val("--session"), val("--description"), val("--pf-mode")], false),
        "attach" | "detach" | "pane-resume" => plain(SESSION, true),
        "resume" => plain(opts![val("--session"), flag("--here")], true),
        "start" => plain(opts![flag("--here")], true),
        "note" => plain(opts![val("--kind")], true),
        "link-branch" => plain(opts![flag("--temp")], false),
        "board" => plain(opts![val("--answers-dir")], false),
        "sessions" | "inbox" => plain(opts![num("-n")], false),
        "pf-switch" | "work-on" => plain(opts![val("--mode"), val("--worktree")], true),
        "ide" | "term" => plain(opts![val("--worktree")], true),
        "rotate" => plain(opts![flag("--close"), flag("--self")], false),
        "distill" => plain(opts![val("--session"), flag("--force")], true),
        "cleanup" | "sweep" => plain(opts![flag("--yes"), val("--force")], false),
        "open-chat" => plain(opts![val("--benchmark")], false),
        "start-issue" => plain(opts![val("--project")], false),
        "loose" => plain(opts![val("--project"), val("--model"), val("--starter")], false),
        "feature-use" => plain(opts![num("--days")], false),
        "viewer-rows" => plain(opts![val("--state")], false),
        "pr-requires" => Some(Spec { opts: opts![val("--pr"), flag("--remove"), flag("--list"), val("--session"), val("--note")], slug_first: false, say: Say::WithUsage("qm", PR_REQUIRES_USAGE) }),
        "draft" => match args.first().map(String::as_str) {
            Some("add") => Some(Spec {
                opts: opts![val("--path"), num("--line"), num("--start-line"), val("--side"), val("--commit"), flag("--file"), val("--reply-to"), val("--pr"), val("--branch"), val("--body"), val("--body-file")],
                slug_first: false,
                say: Say::WithUsage("qm draft add", DRAFT_USAGE),
            }),
            Some("list") => Some(Spec { opts: opts![flag("--json")], slug_first: false, say: Say::Prefixed("qm draft list") }),
            _ => None,
        },
        _ => None,
    }
}

/// `Some(Ok(args))` rewritten for the command's parser, `Some(Err(outcome))` when OptionParser would have
/// refused them, `None` for a command that reads no options.
pub fn normalize(command: &str, args: &[String]) -> Option<Result<Vec<String>, Outcome>> {
    let spec = spec(command, args)?;
    // `draft add|list` keeps its subcommand word out of the way
    let (head, rest): (&[String], &[String]) = if command == "draft" { (&args[..1], &args[1..]) } else { (&[], args) };
    let (first, rest): (&[String], &[String]) = if spec.slug_first && !rest.is_empty() { (&rest[..1], &rest[1..]) } else { (&[], rest) };
    Some(match canonical(rest, spec.opts) {
        Ok(out) => Ok(head.iter().chain(first).cloned().chain(out).collect()),
        Err(message) => Err(match spec.say {
            Say::Plain => abort(&format!("qm: {message}")),
            Say::WithUsage(prefix, usage) => abort(&format!("{prefix}: {message}\n{usage}")),
            Say::Prefixed(prefix) => abort(&format!("{prefix}: {message}")),
        }),
    })
}

fn canonical(args: &[String], opts: &[Opt]) -> Result<Vec<String>, String> {
    let mut out = vec![];
    let mut i = 0;
    while i < args.len() {
        let a = &args[i];
        i += 1;
        if a == "--" {
            out.extend(args[i..].iter().cloned());
            break;
        }
        if let Some(long) = a.strip_prefix("--") {
            let (name, inline) = match long.split_once('=') {
                Some((n, v)) => (n, Some(v.to_string())),
                None => (long, None),
            };
            let full = format!("--{name}");
            let exact = opts.iter().find(|o| o.name == full);
            let found = match exact {
                Some(o) => o,
                None => {
                    let candidates: Vec<&Opt> = opts.iter().filter(|o| o.name.starts_with("--") && o.name.starts_with(&full) && !name.is_empty()).collect();
                    match candidates[..] {
                        [only] => only,
                        [] => return Err(format!("invalid option: {a}")),
                        _ => return Err(format!("ambiguous option: {a}")),
                    }
                }
            };
            if found.arg {
                let value = match inline {
                    Some(v) => v,
                    None => match args.get(i) {
                        Some(v) => {
                            i += 1;
                            v.clone()
                        }
                        None => return Err(format!("missing argument: {a}")),
                    },
                };
                if found.int && !integer(&value) {
                    return Err(format!("invalid argument: {} {value}", found.name));
                }
                out.push(found.name.to_string());
                out.push(value);
            } else {
                if inline.is_some() {
                    return Err(format!("needless argument: {a}"));
                }
                out.push(found.name.to_string());
            }
        } else if a.len() > 1 && a.starts_with('-') {
            let short = &a[..2];
            let Some(found) = opts.iter().find(|o| o.name == short) else { return Err(format!("invalid option: {a}")) };
            let attached = &a[2..];
            let value = if !attached.is_empty() {
                attached.to_string()
            } else {
                match args.get(i) {
                    Some(v) => {
                        i += 1;
                        v.clone()
                    }
                    None => return Err(format!("missing argument: {a}")),
                }
            };
            if found.int && !integer(&value) {
                return Err(format!("invalid argument: {short} {value}"));
            }
            out.push(found.name.to_string());
            out.push(value);
        } else {
            out.push(a.clone());
        }
    }
    Ok(out)
}

/// What `Integer()` takes from an option value, in the plain decimal spellings.
fn integer(v: &str) -> bool {
    let digits = v.strip_prefix('-').or_else(|| v.strip_prefix('+')).unwrap_or(v);
    !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit())
}
