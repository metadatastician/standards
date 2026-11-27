// SPDX-License-Identifier: MPL-2.0
//! Prove native-lock reconciliation is narrow and verifier failures stay
//! failures. Ported from scripts/tests/reconcile-scorecard-actions-lock-test.rb.
//!
//! Every case runs the built binary as scorecard-reusable.yml does, with a stub
//! `gh` first on that child's PATH. The stub records each call and replays
//! canned verifier output (shared, or per workflow from responses/). Nothing
//! changes this process's environment, so the cases can run in parallel.

use serde_json::{json, Value};
use std::fs;
use std::os::unix::fs::{symlink, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;

const STUB_GH: &str = r#"#!/bin/sh
printf '%s\n' "$*" >> invocation
case "$*" in
  actions-lock\ .github/workflows/*.yml\ --verify\ --no-interactive\ --json=valid,findings) ;;
  *) exit 97 ;;
esac
name=$(basename "$2")
if [ -f "responses/$name.json" ]; then
  cat "responses/$name.json"
  exit "$(cat "responses/$name.exit" 2>/dev/null || echo 0)"
fi
printf '%s' "$TEST_LOCK_JSON"
exit "${TEST_LOCK_EXIT:-0}"
"#;

struct Fixture {
    dir: tempfile::TempDir,
    lock_json: String,
    lock_exit: Option<String>,
}

struct Run {
    status: i32,
    stderr: String,
    output: Option<Value>,
    audit: Option<Value>,
}

impl Run {
    fn results(&self) -> &Vec<Value> {
        self.output.as_ref().expect("output written")["runs"][0]["results"]
            .as_array()
            .expect("results")
    }
    fn audit_len(&self) -> usize {
        self.audit
            .as_ref()
            .expect("audit written")
            .as_array()
            .expect("array")
            .len()
    }
    /// Workflows reported as failed, in the order the CLI printed them.
    fn failures(&self) -> Vec<String> {
        self.stderr
            .lines()
            .filter_map(|l| l.strip_prefix("Scorecard reconciliation kept findings for "))
            .map(|l| l.split(": ").next().unwrap_or_default().to_owned())
            .collect()
    }
}

impl Fixture {
    fn new() -> Self {
        let dir = tempfile::Builder::new()
            .prefix("scorecard-lock-")
            .tempdir()
            .expect("tempdir");
        let f = Fixture {
            dir,
            lock_json: r#"{"valid":true,"findings":[]}"#.to_owned(),
            lock_exit: None,
        };
        fs::create_dir_all(f.path(".github/workflows")).unwrap();
        f.write(
            ".github/workflows/ci.yml",
            "jobs:\n  check:\n    steps:\n      - uses: actions/checkout@v7\n      - run: \"echo 'uses: untrusted/action@main'\"\n",
        );
        f.write(
            ".github/workflows/actions.lock",
            "fixture; semantics belong to gh actions-lock",
        );
        f.write("gh", STUB_GH);
        fs::set_permissions(f.path("gh"), fs::Permissions::from_mode(0o755)).unwrap();
        f
    }

    fn path(&self, rel: &str) -> PathBuf {
        self.dir.path().join(rel)
    }

    fn write(&self, rel: &str, body: &str) {
        fs::write(self.path(rel), body).unwrap();
    }

    fn invocations(&self) -> usize {
        fs::read_to_string(self.path("invocation")).map_or(0, |s| s.lines().count())
    }

    fn run_raw(&self, input: &str) -> Run {
        let (inp, out, audit) = (
            self.path("results.sarif"),
            self.path("out.sarif"),
            self.path("audit.json"),
        );
        let _ = fs::remove_file(&out);
        let _ = fs::remove_file(&audit);
        fs::write(&inp, input).unwrap();
        let path = format!(
            "{}:{}",
            self.dir.path().display(),
            std::env::var("PATH").unwrap_or_default()
        );
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_scorecard-lock-reconcile"));
        cmd.args([&inp, &out, &audit, &self.dir.path().to_path_buf()])
            .env("PATH", path)
            .env("TEST_LOCK_JSON", &self.lock_json)
            .env_remove("TEST_LOCK_EXIT");
        if let Some(code) = &self.lock_exit {
            cmd.env("TEST_LOCK_EXIT", code);
        }
        let o = cmd.output().expect("run binary");
        let read = |p: &Path| {
            fs::read_to_string(p)
                .ok()
                .map(|s| serde_json::from_str(&s).expect("json"))
        };
        Run {
            status: o.status.code().expect("exit code"),
            stderr: String::from_utf8_lossy(&o.stderr).into_owned(),
            output: read(&out),
            audit: read(&audit),
        }
    }

    fn run(&self, doc: &Value) -> Run {
        self.run_raw(&doc.to_string())
    }

    /// Add a second workflow whose per-file verifier response FAILS (a real
    /// lock desync, as on metadatastician/ZenodoDeposits.jl quality.yml).
    fn add_failing_workflow(&self, name: &str) -> String {
        self.write(
            &format!(".github/workflows/{name}"),
            "jobs:\n  lint:\n    steps:\n      - uses: actions/checkout@v7.0.0\n",
        );
        fs::create_dir_all(self.path("responses")).unwrap();
        self.write(
            &format!("responses/{name}.json"),
            &json!({"valid": false, "findings": [{"category": "ref-changed", "severity": "error",
                    "dependency": "actions/checkout@v7.0.0"}]})
            .to_string(),
        );
        self.write(&format!("responses/{name}.exit"), "1");
        format!(".github/workflows/{name}")
    }
}

const PIN_MESSAGE: &str = "score is 3: GitHub-owned GitHubAction not pinned by hash\nRemediation";

fn finding_with(rule: &str, message: &str, path: &str, line: u64) -> Value {
    json!({"ruleId": rule, "message": {"text": message}, "locations": [
        {"physicalLocation": {"artifactLocation": {"uri": path}, "region": {"startLine": line}}}
    ]})
}

fn finding_at(path: &str, line: u64) -> Value {
    finding_with("PinnedDependenciesID", PIN_MESSAGE, path, line)
}

fn finding() -> Value {
    finding_at(".github/workflows/ci.yml", 4)
}

fn document_by(tool: &str, results: Vec<Value>) -> Value {
    json!({"version": "2.1.0", "runs": [{"tool": {"driver": {"name": tool}}, "results": results}]})
}

fn document(results: Vec<Value>) -> Value {
    document_by("Scorecard", results)
}

/// Reconciling `doc` removes nothing, records no audit entry and reports
/// `relative` as the one failed workflow.
fn assert_verification_failed(f: &Fixture, doc: &Value, relative: &str) {
    let r = f.run(doc);
    assert_eq!(r.status, 3, "{}", r.stderr);
    assert_eq!(r.output.as_ref(), Some(doc));
    assert_eq!(r.audit_len(), 0);
    assert_eq!(r.failures(), vec![relative.to_owned()]);
}

#[test]
fn only_verified_action_pin_findings_are_removed() {
    let f = Fixture::new();
    let other = vec![
        finding_with(
            "TokenPermissionsID",
            PIN_MESSAGE,
            ".github/workflows/ci.yml",
            4,
        ),
        finding_with(
            "PinnedDependenciesID",
            "score is 3: container not pinned by hash\n",
            ".github/workflows/ci.yml",
            4,
        ),
        finding_at(".github/workflows/ci.yml", 5),
        finding_at("../outside.yml", 4),
        finding_at(".github/workflows/missing.yml", 4),
    ];
    let mut all = vec![finding(), finding()];
    all.extend(other.clone());
    let r = f.run(&document(all));
    assert_eq!(r.status, 0, "{}", r.stderr);
    assert_eq!(r.results(), &other);
    assert_eq!(r.audit_len(), 2);
    assert_eq!(f.invocations(), 1);
}

#[test]
fn missing_lock_and_foreign_tools_are_not_filtered() {
    let f = Fixture::new();
    fs::remove_file(f.path(".github/workflows/actions.lock")).unwrap();
    let original = document(vec![finding()]);
    let r = f.run(&original);
    assert_eq!(r.output.as_ref(), Some(&original));
    assert_eq!(r.audit_len(), 0);
    let r = f.run(&document_by("CodeQL", vec![finding()]));
    assert_eq!(r.audit_len(), 0);
    assert!(!f.path("invocation").exists());
}

/// A verifier result that is malformed, invalid or paired with a non-zero exit
/// never removes a finding: the finding is kept, no audit record is written,
/// and the workflow is reported as a failure.
#[test]
fn invalid_verification_never_becomes_a_clean_result() {
    for invalid in [
        "{}",
        r#"{"valid":false,"findings":[]}"#,
        r#"{"valid":true}"#,
        "[]",
        "not JSON",
    ] {
        let mut f = Fixture::new();
        f.lock_json = invalid.to_owned();
        assert_verification_failed(&f, &document(vec![finding()]), ".github/workflows/ci.yml");
    }
    let mut f = Fixture::new();
    f.lock_exit = Some("1".to_owned());
    assert_verification_failed(&f, &document(vec![finding()]), ".github/workflows/ci.yml");
}

#[test]
fn workflow_symlinks_are_not_filtered() {
    let f = Fixture::new();
    fs::rename(f.path(".github/workflows/ci.yml"), f.path("actual.yml")).unwrap();
    symlink("../../actual.yml", f.path(".github/workflows/ci.yml")).unwrap();
    let r = f.run(&document(vec![finding()]));
    assert_eq!(r.audit_len(), 0);
    assert!(!f.path("invocation").exists());
}

#[test]
fn mixed_workflow_with_job_level_reusable_ref_is_not_rejected_as_stale() {
    let mut f = Fixture::new();
    let slsa = "f7dd8c54c2067bafc12ca7a55595d5ee9b75204a";
    let checkout = "3d3c42e5aac5ba805825da76410c181273ba90b1";
    f.write(
        ".github/workflows/release.yml",
        &format!(
            "name: Release\non: [push]\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@{checkout}\n  provenance:\n    uses: slsa-framework/slsa-github-generator/.github/workflows/generator_generic_slsa3.yml@{slsa} # v2.1.0\n"
        ),
    );
    f.write(
        ".github/workflows/actions.lock",
        &format!(
            "version: 'v0.0.2'\nworkflows:\n  '.github/workflows/release.yml':\n    - 'actions/checkout@{checkout}'\n    - 'slsa-framework/slsa-github-generator@{slsa}'\ndependencies:\n  'actions/checkout@{checkout}':\n    ref: 'v7.0.1'\n    commit: 'sha1-{checkout}'\n  'slsa-framework/slsa-github-generator@{slsa}':\n    ref: 'v2.1.0'\n    commit: 'sha1-{slsa}'\n"
        ),
    );
    f.lock_json = json!({"valid": false, "findings": [{"category": "stale", "severity": "warning",
        "workflow": ".github/workflows/release.yml",
        "dependency": format!("slsa-framework/slsa-github-generator@{slsa}")}]})
    .to_string();
    f.lock_exit = Some("1".to_owned());
    let r = f.run(&document(vec![finding_at(
        ".github/workflows/release.yml",
        7,
    )]));
    assert_eq!(r.status, 0, "{}", r.stderr);
    assert!(r.results().is_empty());
    assert_eq!(r.audit_len(), 1);
}

/// Arm D of standards#1036: a job-level reusable ref absent from actions.lock
/// is a verification failure even though gh actions-lock passes it vacuously;
/// the finding is kept and the workflow reported, never silently dropped.
#[test]
fn arm_d_job_level_reusable_ref_absent_from_lock_is_kept_and_reported() {
    let mut f = Fixture::new();
    let missing = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef";
    f.write(
        ".github/workflows/scorecard.yml",
        &format!("name: Scorecard\non: [push]\njobs:\n  analysis:\n    uses: hyperpolymath/standards/.github/workflows/scorecard-reusable.yml@{missing}\n"),
    );
    f.write(
        ".github/workflows/actions.lock",
        "version: 'v0.0.2'\nworkflows:\n  '.github/workflows/scorecard.yml': []\ndependencies: {}\n",
    );
    f.lock_exit = Some("0".to_owned());
    assert_verification_failed(
        &f,
        &document(vec![finding_at(".github/workflows/scorecard.yml", 5)]),
        ".github/workflows/scorecard.yml",
    );
}

/// The regression for the whole-document abort: one workflow failing native
/// verification must not stop reconciliation of any other workflow. The
/// failing file comes FIRST so an abort (or a "stop filtering after the first
/// failure" variant) leaves the verified file's findings in place.
#[test]
fn one_failing_workflow_does_not_unreconcile_the_others() {
    let f = Fixture::new();
    let bad = f.add_failing_workflow("quality.yml");
    let bad_findings = vec![finding_at(&bad, 4), finding_at(&bad, 4)];
    let mut all = bad_findings.clone();
    all.extend([finding(), finding()]);
    let r = f.run(&document(all));
    assert_eq!(r.status, 3);
    assert_eq!(
        r.results(),
        &bad_findings,
        "failing workflow keeps every finding; verified one loses its"
    );
    let files: Vec<&str> = r
        .audit
        .as_ref()
        .unwrap()
        .as_array()
        .unwrap()
        .iter()
        .map(|a| a["file"].as_str().unwrap())
        .collect();
    assert_eq!(files, vec![".github/workflows/ci.yml"; 2]);
    assert_eq!(r.failures(), vec![bad.clone()]);
    assert!(
        r.stderr
            .contains(&format!("Native action-lock verification failed for {bad}")),
        "{}",
        r.stderr
    );
    assert_eq!(
        f.invocations(),
        2,
        "gh runs once per workflow, failures included"
    );
}

/// A workflow whose YAML cannot be parsed is a failure of that workflow only.
#[test]
fn unparseable_workflow_is_confined_to_itself() {
    let f = Fixture::new();
    f.write(".github/workflows/broken.yml", "jobs: [unclosed\n");
    let broken = finding_at(".github/workflows/broken.yml", 1);
    let r = f.run(&document(vec![broken.clone(), finding()]));
    assert_eq!(r.status, 3);
    assert_eq!(r.results(), &vec![broken]);
    assert_eq!(r.audit_len(), 1);
    assert_eq!(
        r.failures(),
        vec![".github/workflows/broken.yml".to_owned()]
    );
}

/// Workflow contract: on a partial failure the reconciled SARIF IS written (so
/// the select step uploads it, not the raw SARIF) and the exit is 3 (so the run
/// still fails by design).
#[test]
fn cli_partial_failure_writes_output_and_exits_nonzero() {
    let f = Fixture::new();
    let bad = f.add_failing_workflow("quality.yml");
    let r = f.run(&document(vec![finding_at(&bad, 4), finding()]));
    assert_eq!(r.status, 3);
    let kept: Vec<&str> = r
        .results()
        .iter()
        .map(|x| {
            x.pointer("/locations/0/physicalLocation/artifactLocation/uri")
                .unwrap()
                .as_str()
                .unwrap()
        })
        .collect();
    assert_eq!(kept, vec![bad.as_str()]);
    assert_eq!(r.audit_len(), 1);
    assert!(r.stderr.contains(&format!("kept findings for {bad}")));
}

/// Workflow contract: success exits 0; a structural error exits 2 and writes no
/// output, so the workflow falls back to the raw SARIF and fails.
#[test]
fn cli_success_and_structural_error_exit_codes() {
    let f = Fixture::new();
    let r = f.run(&document(vec![finding()]));
    assert_eq!(r.status, 0);
    assert!(r.results().is_empty());

    let r = f.run_raw(r#"{"version":"2.0.0","runs":[]}"#);
    assert_eq!(r.status, 2);
    assert!(
        r.output.is_none(),
        "no reconciled SARIF on a structural error"
    );
    assert!(r.stderr.contains("Scorecard reconciliation failed"));
}

/// The CLI refuses to overwrite its input, so the raw SARIF stays available.
#[test]
fn cli_refuses_to_overwrite_input() {
    let f = Fixture::new();
    let inp = f.path("results.sarif");
    fs::write(&inp, document(vec![finding()]).to_string()).unwrap();
    let o = Command::new(env!("CARGO_BIN_EXE_scorecard-lock-reconcile"))
        .args([&inp, &inp, &f.path("audit.json")])
        .output()
        .unwrap();
    assert_eq!(o.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&o.stderr).contains("Keep the original SARIF"));
}
