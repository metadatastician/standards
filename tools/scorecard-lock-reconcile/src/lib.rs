// SPDX-License-Identifier: MPL-2.0
//! Reconcile only Scorecard's inline action-pin findings with native lock
//! coverage. No lock semantics are reimplemented: `gh actions-lock --verify`
//! verifies each workflow. This is a port of the former
//! `scripts/reconcile-scorecard-actions-lock.rb`, with the same rules.

use regex::Regex;
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::OnceLock;
use yaml_rust2::parser::{Event, MarkedEventReceiver, Parser};
use yaml_rust2::scanner::Marker;
use yaml_rust2::{Yaml, YamlLoader};

/// The audit reason recorded for every removed finding.
pub const REASON: &str =
    "False positive: native direct and transitive pins verified by gh actions-lock --verify";

fn re(cell: &'static OnceLock<Regex>, pattern: &str) -> &'static Regex {
    cell.get_or_init(|| Regex::new(pattern).expect("static regex"))
}
fn pin_message() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    re(
        &R,
        r"\Ascore is [0-9]+: (?:GitHub-owned |third-party )?GitHubAction not pinned by hash\n",
    )
}
fn remote_action() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    re(&R, r"\A[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[^\s]+\z")
}
fn reusable_ref() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    re(
        &R,
        r"\A([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/\.github/workflows/[^@\s]+\.ya?ml@([^\s#]+)\z",
    )
}
fn sha_commit() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    re(&R, r"(?i)\Asha1-([0-9a-f]{40})\z")
}
fn hex_sha() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    re(&R, r"(?i)\A[0-9a-f]{40}\z")
}
fn workflow_uri() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    re(&R, r"\A\.github/workflows/[^/]+\.ya?ml\z")
}

/// A scalar `uses:` value found in a mapping, with the one-based line of its key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UsesEntry {
    pub line: usize,
    pub value: String,
}

enum Frame {
    Seq,
    /// A mapping waiting for a key (`None`) or for the value of the given key.
    /// The key is `Some(Some(..))` for a scalar key and `Some(None)` otherwise.
    Map(Option<Option<(String, usize)>>),
}

#[derive(Default)]
struct UsesCollector {
    stack: Vec<Frame>,
    found: Vec<UsesEntry>,
}

impl UsesCollector {
    /// A node starts (`scalar` is its text when it is a scalar). Returns
    /// whether that node fills a mapping value whose key is `uses`.
    fn node(&mut self, scalar: Option<&str>, mark: Marker) {
        if let Some(Frame::Map(slot)) = self.stack.last_mut() {
            match slot.take() {
                None => {
                    *slot = Some(scalar.map(|s| (s.to_owned(), mark.line())));
                }
                Some(key) => {
                    if let (Some((k, line)), Some(v)) = (key, scalar) {
                        if k == "uses" {
                            self.found.push(UsesEntry {
                                line,
                                value: v.to_owned(),
                            });
                        }
                    }
                }
            }
        }
    }
}

impl MarkedEventReceiver for UsesCollector {
    fn on_event(&mut self, ev: Event, mark: Marker) {
        match ev {
            Event::Scalar(value, ..) => self.node(Some(&value), mark),
            Event::Alias(_) => self.node(None, mark),
            Event::SequenceStart(..) => {
                self.node(None, mark);
                self.stack.push(Frame::Seq);
            }
            Event::MappingStart(..) => {
                self.node(None, mark);
                self.stack.push(Frame::Map(None));
            }
            Event::SequenceEnd | Event::MappingEnd => {
                self.stack.pop();
            }
            _ => {}
        }
    }
}

/// Every scalar `uses:` entry in a YAML stream, in document order.
pub fn uses_entries(source: &str) -> Result<Vec<UsesEntry>, String> {
    let mut collector = UsesCollector::default();
    let mut parser = Parser::new_from_str(source);
    parser
        .load(&mut collector, true)
        .map_err(|e| e.to_string())?;
    Ok(collector.found)
}

/// One-based lines of remote GitHub Action `uses:` entries. Local actions,
/// containers and text that merely contains `uses` are excluded.
pub fn action_lines(source: &str) -> Result<Vec<usize>, String> {
    Ok(uses_entries(source)?
        .into_iter()
        .filter(|e| remote_action().is_match(&e.value))
        .map(|e| e.line)
        .collect())
}

/// Normalised `owner/repo@ref` for every job-level reusable-workflow `uses:`.
/// `gh actions-lock --verify` ignores these in both directions (standards#1036):
/// it falsely flags present lock entries as `stale`, and vacuously passes
/// workflows whose job-level ref is absent from `actions.lock` (Arm D).
pub fn reusable_workflow_deps(source: &str) -> Result<Vec<String>, String> {
    let mut deps: Vec<String> = Vec::new();
    for entry in uses_entries(source)? {
        if let Some(c) = reusable_ref().captures(entry.value.trim()) {
            let dep = format!("{}@{}", &c[1], &c[2]);
            if !deps.contains(&dep) {
                deps.push(dep);
            }
        }
    }
    Ok(deps)
}

fn has_alias(source: &str) -> Result<bool, String> {
    struct A(bool);
    impl MarkedEventReceiver for A {
        fn on_event(&mut self, ev: Event, _: Marker) {
            if matches!(ev, Event::Alias(_)) {
                self.0 = true;
            }
        }
    }
    let mut a = A(false);
    Parser::new_from_str(source)
        .load(&mut a, true)
        .map_err(|e| e.to_string())?;
    Ok(a.0)
}

/// Whether every dep is recorded under `workflows[relative]` and `dependencies`
/// in the lock with an immutable `sha1-<40 hex>` commit (matching the ref when
/// the ref is itself a 40-hex SHA). Aliases are refused, as a safe YAML load does.
pub fn lock_covers_reusable_deps(
    lock_source: &str,
    relative: &str,
    deps: &[String],
) -> Result<bool, String> {
    if deps.is_empty() {
        return Ok(true);
    }
    if has_alias(lock_source)? {
        return Err("actions.lock uses YAML aliases".to_owned());
    }
    let docs = YamlLoader::load_from_str(lock_source).map_err(|e| e.to_string())?;
    let Some(lock @ Yaml::Hash(_)) = docs.first() else {
        return Ok(false);
    };
    let wf_entries = &lock["workflows"][relative];
    let deps_map = &lock["dependencies"];
    let (Yaml::Array(wf_entries), Yaml::Hash(_)) = (wf_entries, deps_map) else {
        return Ok(false);
    };
    Ok(deps.iter().all(|dep| {
        if !wf_entries.iter().any(|e| e.as_str() == Some(dep)) {
            return false;
        }
        let entry = &deps_map[dep.as_str()];
        if !matches!(entry, Yaml::Hash(_)) {
            return false;
        }
        let Some(commit) = entry["commit"].as_str() else {
            return false;
        };
        let Some(m) = sha_commit().captures(commit) else {
            return false;
        };
        let reference = dep.split_once('@').map_or("", |(_, r)| r);
        !hex_sha().is_match(reference) || m[1].eq_ignore_ascii_case(reference)
    }))
}

/// Whether one workflow's verifier result is clean enough to suppress its pin
/// findings: valid with no findings and a zero exit, valid with only
/// `sha-as-ref` findings, or invalid only through `stale` entries for job-level
/// reusable refs the verifier cannot see (plus any `sha-as-ref`).
pub fn verification_accepted(verification: &Value, success: bool, deps: &[String]) -> bool {
    let Some(obj) = verification.as_object() else {
        return false;
    };
    let Some(findings) = obj.get("findings").and_then(Value::as_array) else {
        return false;
    };
    let category = |f: &Value| f.get("category").cloned();
    match obj.get("valid") {
        Some(Value::Bool(true)) => {
            if findings.is_empty() {
                success
            } else {
                findings
                    .iter()
                    .all(|f| f.is_object() && category(f) == Some(json!("sha-as-ref")))
            }
        }
        Some(Value::Bool(false)) if !findings.is_empty() => {
            let mut accepted_stale = 0;
            for f in findings {
                if !f.is_object() {
                    return false;
                }
                let dep_known = f
                    .get("dependency")
                    .and_then(Value::as_str)
                    .is_some_and(|d| deps.iter().any(|x| x == d));
                if category(f) == Some(json!("stale")) && dep_known {
                    accepted_stale += 1;
                } else if category(f) != Some(json!("sha-as-ref")) {
                    return false;
                }
            }
            accepted_stale > 0
        }
        _ => false,
    }
}

/// Verify one workflow against `actions.lock`. Returns the verifier's JSON, or
/// the reason it failed, so the caller can confine the failure to this file.
pub fn verify_workflow(root: &Path, relative: &str) -> Result<Value, String> {
    let source = fs::read_to_string(root.join(relative)).map_err(|e| e.to_string())?;
    let lock_source = fs::read_to_string(root.join(".github/workflows/actions.lock"))
        .map_err(|e| e.to_string())?;
    let deps = reusable_workflow_deps(&source)?;
    if !lock_covers_reusable_deps(&lock_source, relative, &deps)? {
        return Err(format!(
            "Native action-lock verification failed for {relative}: job-level reusable ref absent from actions.lock"
        ));
    }
    let out = Command::new("gh")
        .args([
            "actions-lock",
            relative,
            "--verify",
            "--no-interactive",
            "--json=valid,findings",
        ])
        .current_dir(root)
        .stdin(Stdio::null())
        .output()
        .map_err(|e| format!("cannot run gh: {e}"))?;
    if !out.stderr.is_empty() {
        let _ = std::io::stderr().write_all(&out.stderr);
    }
    let verification: Value = serde_json::from_slice(&out.stdout).map_err(|e| e.to_string())?;
    if !verification_accepted(&verification, out.status.success(), &deps) {
        return Err(format!(
            "Native action-lock verification failed for {relative}"
        ));
    }
    Ok(verification)
}

/// The outcome of reconciling one SARIF document.
#[derive(Debug, Default)]
pub struct Outcome {
    /// One record per removed finding.
    pub audit: Vec<Value>,
    /// Workflows whose findings were kept, in first-seen order, with the reason.
    pub failures: Vec<(String, String)>,
}

fn location(result: &Map<String, Value>) -> Option<(String, u64)> {
    let locations = result.get("locations")?.as_array()?;
    if locations.len() != 1 {
        return None;
    }
    let empty = Value::Object(Map::new());
    let physical = locations[0]
        .as_object()?
        .get("physicalLocation")
        .filter(|v| !v.is_null())
        .unwrap_or(&empty);
    let relative = physical.pointer("/artifactLocation/uri")?.as_str()?;
    let line = physical.pointer("/region/startLine")?.as_u64()?;
    (workflow_uri().is_match(relative) && line > 0).then(|| (relative.to_owned(), line))
}

fn eligible_file(root: &Path, relative: &str) -> bool {
    let path = root.join(relative);
    let Ok(meta) = fs::symlink_metadata(&path) else {
        return false;
    };
    if !meta.is_file() {
        return false;
    }
    let Ok(real) = fs::canonicalize(&path) else {
        return false;
    };
    real.starts_with(root) && real != root && root.join(".github/workflows/actions.lock").is_file()
}

/// Remove Scorecard action-pin findings only when they name a remote action
/// entry in a regular workflow below `root` and native verification of THAT
/// workflow succeeds. Verification is per file. The document is updated in
/// place. Errors only when the SARIF structure itself is invalid.
pub fn reconcile(document: &mut Value, root: &Path) -> Result<Outcome, String> {
    let structure_ok = document.get("version") == Some(&json!("2.1.0"))
        && document
            .get("runs")
            .and_then(Value::as_array)
            .is_some_and(|r| !r.is_empty());
    if !document.is_object() || !structure_ok {
        return Err("Expected a SARIF 2.1.0 document with runs".to_owned());
    }
    let runs = document["runs"].as_array_mut().expect("checked");
    if !runs
        .iter()
        .all(|r| r.get("results").is_some_and(Value::is_array))
    {
        return Err("Expected a results array".to_owned());
    }
    let root: PathBuf = fs::canonicalize(root).map_err(|e| format!("{}: {e}", root.display()))?;
    let mut verified: HashMap<String, Value> = HashMap::new();
    let mut failed: HashMap<String, ()> = HashMap::new();
    let mut outcome = Outcome::default();

    for run in runs.iter_mut() {
        if run.pointer("/tool/driver/name") != Some(&json!("Scorecard")) {
            continue;
        }
        let results = std::mem::take(run["results"].as_array_mut().expect("checked"));
        let mut kept = Vec::with_capacity(results.len());
        for result in results {
            let remove = (|| {
                let r = result.as_object()?;
                if r.get("ruleId") != Some(&json!("PinnedDependenciesID")) {
                    return None;
                }
                let text = r
                    .get("message")
                    .and_then(|m| m.get("text"))
                    .and_then(Value::as_str)
                    .unwrap_or("");
                if !pin_message().is_match(text) {
                    return None;
                }
                let (relative, line) = location(r)?;
                if !eligible_file(&root, &relative) || failed.contains_key(&relative) {
                    return None;
                }
                let source = match fs::read_to_string(root.join(&relative)) {
                    Ok(s) => s,
                    Err(e) => {
                        outcome.failures.push((
                            relative.clone(),
                            format!("Unparseable workflow {relative}: {e}"),
                        ));
                        failed.insert(relative, ());
                        return None;
                    }
                };
                let lines = match action_lines(&source) {
                    Ok(l) => l,
                    Err(e) => {
                        outcome.failures.push((
                            relative.clone(),
                            format!("Unparseable workflow {relative}: {e}"),
                        ));
                        failed.insert(relative, ());
                        return None;
                    }
                };
                if !lines.iter().any(|&l| l as u64 == line) {
                    return None;
                }
                if !verified.contains_key(&relative) {
                    match verify_workflow(&root, &relative) {
                        Ok(v) => {
                            verified.insert(relative.clone(), v);
                        }
                        Err(reason) => {
                            outcome.failures.push((relative.clone(), reason));
                            failed.insert(relative, ());
                            return None;
                        }
                    }
                }
                Some(json!({
                    "file": relative,
                    "line": line,
                    "rule": "PinnedDependenciesID",
                    "reason": REASON,
                    "verification": verified[&relative].clone(),
                }))
            })();
            match remove {
                Some(record) => outcome.audit.push(record),
                None => kept.push(result),
            }
        }
        run["results"] = Value::Array(kept);
    }
    Ok(outcome)
}

/// Lexical absolute path, like Ruby's `File.expand_path` (no symlinks resolved).
pub fn expand_path(p: &Path) -> PathBuf {
    let base = if p.is_absolute() {
        PathBuf::new()
    } else {
        std::env::current_dir().unwrap_or_default()
    };
    let mut out = PathBuf::new();
    for c in base.join(p).components() {
        match c {
            std::path::Component::ParentDir => {
                out.pop();
            }
            std::path::Component::CurDir => {}
            other => out.push(other),
        }
    }
    out
}
