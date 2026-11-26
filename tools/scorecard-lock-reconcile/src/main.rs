// SPDX-License-Identifier: MPL-2.0
//! Usage: scorecard-lock-reconcile INPUT OUTPUT AUDIT_JSON [ROOT]
//!
//! Exit codes:
//!   0  every eligible workflow verified; OUTPUT and AUDIT_JSON written.
//!   3  OUTPUT and AUDIT_JSON written, but at least one workflow failed native
//!      verification. Only that workflow's findings are retained; findings in
//!      verified workflows are still removed. Callers must treat this as failure.
//!   2  usage or SARIF structure error; OUTPUT is NOT written.

use scorecard_lock_reconcile::{expand_path, reconcile};
use std::path::Path;
use std::process::ExitCode;

fn pretty(value: &serde_json::Value) -> String {
    serde_json::to_string_pretty(value).expect("serialisable") + "\n"
}

fn run() -> Result<u8, String> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if !(3..=4).contains(&args.len()) {
        return Err("Usage: INPUT OUTPUT AUDIT_JSON [ROOT]".to_owned());
    }
    let (input, output, audit_path) = (&args[0], &args[1], &args[2]);
    if expand_path(Path::new(input)) == expand_path(Path::new(output)) {
        return Err("Keep the original SARIF as a separate artifact".to_owned());
    }
    let root = args.get(3).map_or(".", String::as_str);
    let text = std::fs::read_to_string(input).map_err(|e| format!("{input}: {e}"))?;
    let mut document: serde_json::Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
    let outcome = reconcile(&mut document, Path::new(root))?;
    std::fs::write(output, pretty(&document)).map_err(|e| format!("{output}: {e}"))?;
    std::fs::write(
        audit_path,
        pretty(&serde_json::Value::Array(outcome.audit.clone())),
    )
    .map_err(|e| format!("{audit_path}: {e}"))?;
    println!(
        "Reconciled {} verified native action-pin false positives; all other findings retained.",
        outcome.audit.len()
    );
    if outcome.failures.is_empty() {
        return Ok(0);
    }
    for (relative, reason) in &outcome.failures {
        eprintln!("Scorecard reconciliation kept findings for {relative}: {reason}");
    }
    eprintln!(
        "Scorecard reconciliation incomplete: {} workflow(s) failed native action-lock verification; \
         their findings are retained in the reconciled SARIF.",
        outcome.failures.len()
    );
    Ok(3)
}

fn main() -> ExitCode {
    match run() {
        Ok(code) => ExitCode::from(code),
        Err(message) => {
            eprintln!("Scorecard reconciliation failed: {message}");
            ExitCode::from(2)
        }
    }
}
