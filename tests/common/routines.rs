#![allow(dead_code)]
//! A stand-in routines API held in memory, shared by the GUI tests: it records every call, applies creates and
//! updates the way the API would (through the real request body) and stamps a new updated_at on each write.
//! `client()` hands the GUI's jobs a client over the one stub in play (`install`). No keychain, no network.

use quartermaster::error::{QmError, Res};
use quartermaster::routines_client::{self as rc, Deleted, Routines};
use serde_json::{json, Map, Value};
use std::collections::BTreeMap;
use std::sync::mpsc::Receiver;
use std::sync::{Arc, Mutex};

const DEFAULT_MODEL: &str = "claude-default-model";

pub fn digest() -> Value {
    let list: Value = serde_json::from_str(include_str!("../fixtures/routines-list-response.json")).unwrap();
    list["data"][0].clone()
}

pub fn id() -> String {
    digest()["id"].as_str().unwrap().to_string()
}

#[derive(Default)]
pub struct Inner {
    pub routines: BTreeMap<String, Value>,
    pub calls: Vec<Value>,
    stamp: u32,
    pub fail_with: Option<(&'static str, String)>,
    /// The next list call waits for this to say go.
    pub gate: Option<Receiver<()>>,
}

#[derive(Clone, Default)]
pub struct Stub(pub Arc<Mutex<Inner>>);

static CURRENT: Mutex<Option<Stub>> = Mutex::new(None);

/// A fresh stub holding the digest routine, the one `client()` answers for.
pub fn install() -> Stub {
    let stub = Stub::default();
    stub.0.lock().unwrap().routines.insert(id(), digest());
    *CURRENT.lock().unwrap() = Some(stub.clone());
    stub
}

pub fn client() -> Box<dyn Routines> {
    Box::new(CURRENT.lock().unwrap().clone().expect("a stub is installed"))
}

impl Stub {
    fn inner(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.0.lock().unwrap_or_else(|p| p.into_inner())
    }

    pub fn calls(&self) -> Vec<Value> {
        self.inner().calls.clone()
    }

    pub fn clear_calls(&self) {
        self.inner().calls.clear();
    }

    pub fn calls_named(&self, name: &str) -> Vec<Value> {
        self.calls().into_iter().filter(|c| c[0] == name).collect()
    }

    pub fn routine(&self, id: &str) -> Option<Value> {
        self.inner().routines.get(id).cloned()
    }

    pub fn forget_routines(&self) {
        self.inner().routines.clear();
    }

    pub fn touch(&self, id: &str) {
        self.inner().routines.get_mut(id).unwrap()["updated_at"] = json!("2026-11-06T10:00:00Z");
    }

    pub fn fail_with(&self, class: &'static str, message: &str) {
        self.inner().fail_with = Some((class, message.to_string()));
    }

    pub fn gate(&self, rx: Receiver<()>) {
        self.inner().gate = Some(rx);
    }

    fn record(&self, call: Value) -> Res<()> {
        let mut inner = self.inner();
        if let Some((class, message)) = inner.fail_with.clone() {
            return Err(QmError::new(class, message));
        }
        inner.calls.push(call);
        Ok(())
    }

    fn apply(&self, mut routine: Value, body: Value) -> Value {
        let mut inner = self.inner();
        for (k, v) in body.as_object().unwrap() {
            if k != "clear_mcp_connections" {
                routine[k] = v.clone();
            }
        }
        inner.stamp += 1;
        routine["updated_at"] = json!(format!("2026-11-06T09:00:0{}Z", inner.stamp));
        inner.routines.insert(routine["id"].as_str().unwrap().to_string(), routine.clone());
        routine
    }

    fn missing(&self, id: &str) -> Res<Value> {
        self.routine(id).ok_or_else(|| QmError::new(rc::ROUTINE_MISSING, format!("routine {id} isn't on claude.ai any more — delete the automation in qm")))
    }
}

impl Routines for Stub {
    fn list(&self) -> Res<Vec<Value>> {
        let gate = self.inner().gate.take();
        if let Some(rx) = gate {
            let _ = rx.recv();
        }
        self.record(json!(["list"]))?;
        Ok(self.inner().routines.values().cloned().collect())
    }
    fn get(&self, id: &str) -> Res<Value> {
        self.record(json!(["get", id]))?;
        self.missing(id)
    }
    fn create(&self, fields: &Map<String, Value>) -> Res<Value> {
        self.record(json!(["create", fields]))?;
        let mut body = rc::request_body(fields, "00000000-0000-4000-8000-000000000009");
        if let Some(context) = body.pointer_mut("/job_config/ccr/session_context").and_then(Value::as_object_mut) {
            context.entry("model").or_insert(json!(DEFAULT_MODEL));
        }
        Ok(self.apply(json!({"id": "trig_NEW", "enabled": true}), body))
    }
    fn update(&self, id: &str, fields: &Map<String, Value>) -> Res<Value> {
        self.record(json!(["update", id, fields]))?;
        let current = self.missing(id)?;
        Ok(self.apply(current, rc::request_body(fields, "00000000-0000-4000-8000-000000000009")))
    }
    fn run(&self, id: &str) -> Res<Value> {
        self.record(json!(["run", id]))?;
        Ok(json!({"session_id": "cse_RUN"}))
    }
    fn runs(&self, id: &str, limit: usize) -> Res<Vec<Value>> {
        self.record(json!(["runs", id, limit]))?;
        Ok(vec![json!({"id": "cse_1", "title": "Digest run", "status": "completed", "created_at": "2026-11-05T07:10:10Z", "updated_at": null, "url": "https://claude.ai/code/cse_1"})])
    }
    fn delete(&self, id: &str) -> Res<Deleted> {
        self.record(json!(["delete", id]))?;
        Ok(Deleted::Unsupported)
    }
}
