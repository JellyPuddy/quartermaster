//! PR state per work-item branch, via `gh`, cached in `pr-cache.json` so repaints don't hit the
//! network on every render. Synchronous: an expired entry blocks on `gh`.

use std::process::{Command, Stdio};

use serde_json::{Map, Value};

use crate::data_root;
use crate::project_config::ProjectConfig;
use crate::work_item::WorkItem;

const CACHE_TTL_SECONDS: i64 = 6 * 3600;
const OPEN_TTL_SECONDS: i64 = 5 * 60;
const NO_PR_TTL_SECONDS: i64 = 10 * 60;

pub struct PrStatus {
    now: i64,
    config: ProjectConfig,
}

fn cache_path() -> std::path::PathBuf {
    data_root::root().join("pr-cache.json")
}

fn read_cache() -> Map<String, Value> {
    match std::fs::read_to_string(cache_path()).ok().and_then(|t| serde_json::from_str::<Value>(&t).ok()) {
        Some(Value::Object(m)) => m,
        _ => Map::new(),
    }
}

fn write_cache(cache: &Map<String, Value>) {
    let _ = data_root::ensure_setup();
    let path = cache_path();
    let temp = path.with_file_name(format!(".pr-cache.json.tmp-{}", std::process::id()));
    if std::fs::write(&temp, Value::Object(cache.clone()).to_string()).is_ok() {
        let _ = std::fs::rename(&temp, &path);
    }
}

fn ttl(entry: &Value) -> i64 {
    match entry.get("state") {
        None | Some(Value::Null) => NO_PR_TTL_SECONDS,
        Some(Value::String(s)) if s == "OPEN" => OPEN_TTL_SECONDS,
        _ => CACHE_TTL_SECONDS,
    }
}

impl PrStatus {
    pub fn new(now: i64) -> PrStatus {
        PrStatus { now, config: ProjectConfig::current() }
    }

    pub fn root_for(&self, project: Option<&str>) -> Option<&str> {
        let name = project?;
        self.config.roots().into_iter().find(|(n, _)| *n == name).map(|(_, r)| r)
    }

    /// The branch's PR state ("OPEN", "MERGED", "CLOSED") or None; fetches when the cache has expired.
    pub fn state_for(&self, item: &WorkItem, branch: &str) -> Option<String> {
        let key = format!("{}#{branch}", item.project().unwrap_or_default());
        let cache = read_cache();
        if let Some(entry) = cache.get(&key) {
            if let Some(ts) = entry.get("ts").and_then(Value::as_i64) {
                if self.now - ts < ttl(entry) {
                    return entry.get("state").and_then(Value::as_str).map(String::from);
                }
            }
        }
        self.store(&key, self.fetch_via_gh(item, branch))
    }

    fn fetch_via_gh(&self, item: &WorkItem, branch: &str) -> Option<Value> {
        let root = self.root_for(item.project().as_deref())?;
        let out = Command::new("gh")
            .args(["pr", "view", branch, "--json", "state,number,url"])
            .current_dir(root)
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output()
            .ok()?;
        if !out.status.success() {
            return None;
        }
        serde_json::from_slice(&out.stdout).ok()
    }

    fn store(&self, key: &str, fetched: Option<Value>) -> Option<String> {
        let mut pr = Map::new();
        match &fetched {
            Some(Value::Object(o)) => {
                for k in ["state", "number", "url"] {
                    if let Some(v) = o.get(k) {
                        pr.insert(k.into(), v.clone());
                    }
                }
            }
            Some(other) => {
                pr.insert("state".into(), other.clone());
            }
            None => {
                pr.insert("state".into(), Value::Null);
            }
        }
        pr.insert("ts".into(), Value::from(self.now));
        let state = pr.get("state").and_then(Value::as_str).map(String::from);
        let mut cache = read_cache();
        cache.insert(key.to_string(), Value::Object(pr));
        write_cache(&cache);
        state
    }
}
