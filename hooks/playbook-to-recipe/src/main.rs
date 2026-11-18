// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// playbook-to-recipe — convert PLAYBOOK.a2ml runbook procedures into
// Hypatia-compatible A2ML recipes (one file per procedure).
//
// PLAYBOOK.a2ml v1 (Scheme) shape:
//   (procedures
//     ((deploy . (("build" . "just build") ("test" . "just test") ...))
//      (rollback . (...))))
//
// Each procedure becomes a recipe file:
//   recipes/recipe-<repo>-<procedure>.a2ml

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = env::args().skip(1).collect();
    let (playbook, out_dir, repo_hint) = match parse_args(&args) {
        Ok(x) => x,
        Err(msg) => {
            eprintln!("playbook-to-recipe: {msg}");
            eprintln!("usage: playbook-to-recipe --playbook PATH --out DIR [--repo NAME]");
            return ExitCode::from(2);
        }
    };

    let text = match fs::read_to_string(&playbook) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("playbook-to-recipe: read {}: {e}", playbook.display());
            return ExitCode::FAILURE;
        }
    };

    if let Err(e) = fs::create_dir_all(&out_dir) {
        eprintln!("playbook-to-recipe: mkdir {}: {e}", out_dir.display());
        return ExitCode::FAILURE;
    }

    let repo = repo_hint.unwrap_or_else(|| infer_repo(&playbook));
    let procedures = extract_procedures(&text);
    if procedures.is_empty() {
        eprintln!(
            "playbook-to-recipe: no procedures found in {}",
            playbook.display()
        );
        return ExitCode::SUCCESS;
    }

    let mut written = 0usize;
    for (name, steps) in &procedures {
        let file = out_dir.join(format!("recipe-{repo}-{name}.a2ml"));
        let body = render_recipe(&repo, name, steps);
        match fs::write(&file, body) {
            Ok(()) => {
                println!("wrote {} ({} steps)", file.display(), steps.len());
                written += 1;
            }
            Err(e) => eprintln!("playbook-to-recipe: write {}: {e}", file.display()),
        }
    }
    println!("playbook-to-recipe: {written} recipes written");
    ExitCode::SUCCESS
}

fn parse_args(args: &[String]) -> Result<(PathBuf, PathBuf, Option<String>), String> {
    let mut pb: Option<PathBuf> = None;
    let mut out: Option<PathBuf> = None;
    let mut repo: Option<String> = None;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--playbook" => {
                i += 1;
                pb = Some(PathBuf::from(
                    args.get(i).ok_or("missing value after --playbook")?,
                ));
            }
            "--out" => {
                i += 1;
                out = Some(PathBuf::from(
                    args.get(i).ok_or("missing value after --out")?,
                ));
            }
            "--repo" => {
                i += 1;
                repo = Some(args.get(i).ok_or("missing value after --repo")?.clone());
            }
            "-h" | "--help" => return Err("help".into()),
            s => return Err(format!("unexpected arg: {s}")),
        }
        i += 1;
    }
    Ok((
        pb.ok_or("--playbook is required")?,
        out.ok_or("--out is required")?,
        repo,
    ))
}

fn infer_repo(playbook: &Path) -> String {
    // Find the repo name: look up from .machine_readable/ grandparent.
    let mut cur = playbook.parent();
    while let Some(p) = cur {
        if p.file_name().and_then(|s| s.to_str()) == Some(".machine_readable") {
            if let Some(parent) = p.parent() {
                if let Some(name) = parent.file_name().and_then(|s| s.to_str()) {
                    return name.to_string();
                }
            }
        }
        cur = p.parent();
    }
    "unknown".to_string()
}

/// Find the `(procedures ...)` block, then pull each `(name . ((k . v) ...))`.
fn extract_procedures(text: &str) -> Vec<(String, Vec<(String, String)>)> {
    let Some(start) = text.find("(procedures") else {
        return Vec::new();
    };
    let tail = &text[start..];
    let region = balanced_sexp(tail);
    let bytes = region.as_bytes();
    let mut out = Vec::new();

    // Scan for `(<name> . (` — a procedure entry.
    let mut i = 0usize;
    while i < bytes.len() {
        if bytes[i] != b'(' {
            i += 1;
            continue;
        }
        // skip whitespace, read identifier
        let mut j = i + 1;
        while j < bytes.len() && (bytes[j] as char).is_whitespace() {
            j += 1;
        }
        let id_start = j;
        while j < bytes.len() {
            let c = bytes[j];
            if c.is_ascii_alphanumeric() || c == b'-' || c == b'_' {
                j += 1;
            } else {
                break;
            }
        }
        if j == id_start {
            i += 1;
            continue;
        }
        let name = region[id_start..j].to_string();
        // skip whitespace, require '.'
        while j < bytes.len() && (bytes[j] as char).is_whitespace() {
            j += 1;
        }
        if j >= bytes.len() || bytes[j] != b'.' {
            i += 1;
            continue;
        }
        j += 1;
        while j < bytes.len() && (bytes[j] as char).is_whitespace() {
            j += 1;
        }
        if j >= bytes.len() || bytes[j] != b'(' {
            // not a procedure-body start; skip
            i += 1;
            continue;
        }
        // capture the value s-expression
        let value_region = balanced_sexp(&region[j..]);
        // filter: skip the outer "procedures" node itself
        if name == "procedures" {
            i = j + value_region.len();
            continue;
        }
        let steps = extract_steps(value_region);
        if !steps.is_empty() {
            out.push((name, steps));
        }
        i = j + value_region.len();
    }
    out
}

/// Pull `("key" . "value")` pairs from a procedure body.
fn extract_steps(region: &str) -> Vec<(String, String)> {
    let bytes = region.as_bytes();
    let mut out = Vec::new();
    let mut i = 0usize;
    while i < bytes.len() {
        if bytes[i] != b'(' {
            i += 1;
            continue;
        }
        // skip whitespace, expect quote
        let mut j = i + 1;
        while j < bytes.len() && (bytes[j] as char).is_whitespace() {
            j += 1;
        }
        if j >= bytes.len() || bytes[j] != b'"' {
            i += 1;
            continue;
        }
        let ks = j + 1;
        let Some(k_end) = region[ks..].find('"') else {
            break;
        };
        let key = region[ks..ks + k_end].to_string();
        j = ks + k_end + 1;
        while j < bytes.len() && (bytes[j] as char).is_whitespace() {
            j += 1;
        }
        if j >= bytes.len() || bytes[j] != b'.' {
            i += 1;
            continue;
        }
        j += 1;
        while j < bytes.len() && (bytes[j] as char).is_whitespace() {
            j += 1;
        }
        if j >= bytes.len() || bytes[j] != b'"' {
            i += 1;
            continue;
        }
        let vs = j + 1;
        let Some(v_end) = region[vs..].find('"') else {
            break;
        };
        let val = region[vs..vs + v_end].to_string();
        out.push((key, val));
        i = vs + v_end + 1;
    }
    out
}

/// Consume a balanced S-expression starting at byte 0 of `s` (must begin with `(`).
fn balanced_sexp(s: &str) -> &str {
    let bytes = s.as_bytes();
    if bytes.is_empty() || bytes[0] != b'(' {
        return "";
    }
    let mut depth: i32 = 0;
    let mut in_str = false;
    for (i, &b) in bytes.iter().enumerate() {
        if in_str {
            if b == b'"' {
                in_str = false;
            }
            continue;
        }
        match b {
            b'"' => in_str = true,
            b'(' => depth += 1,
            b')' => {
                depth -= 1;
                if depth == 0 {
                    return &s[..=i];
                }
            }
            _ => {}
        }
    }
    s
}

fn render_recipe(repo: &str, proc_name: &str, steps: &[(String, String)]) -> String {
    let mut s = String::new();
    s.push_str("# SPDX-License-Identifier: MPL-2.0\n");
    s.push_str("# Hypatia recipe (A2ML) — generated from PLAYBOOK.a2ml\n\n");
    s.push_str("@recipe(version=\"1.0\"):\n");
    s.push_str(&format!("id: recipe-{repo}-{proc_name}\n"));
    s.push_str(&format!(
        "name: \"{} procedure for {}\"\n",
        title_case(proc_name),
        repo
    ));
    s.push_str(&format!(
        "description: \"Auto-generated from PLAYBOOK.a2ml procedures.{proc_name}\"\n"
    ));
    s.push_str("source: playbook-to-recipe\n");
    s.push_str("auto_fixable: false\n");
    s.push_str("confidence: 0.70\n");
    s.push_str(&format!("target_repos: [\"{repo}\"]\n"));
    s.push_str("\n@steps:\n");
    for (k, v) in steps {
        s.push_str(&format!("- name: \"{k}\"\n"));
        s.push_str(&format!("  command: \"{v}\"\n"));
    }
    s.push_str("@end\n@end\n");
    s
}

fn title_case(s: &str) -> String {
    let mut out = String::new();
    let mut cap = true;
    for c in s.chars() {
        if c == '-' || c == '_' {
            out.push(' ');
            cap = true;
        } else if cap {
            out.extend(c.to_uppercase());
            cap = false;
        } else {
            out.push(c);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#";; SPDX
(define playbook
  `((version . "1.0.0")
    (procedures
      ((deploy . (("build" . "just build")
                  ("test" . "just test")
                  ("release" . "just release")))
       (rollback . (("revert" . "git revert HEAD")))
       (debug . ())))))
"#;

    #[test]
    fn extracts_procedures() {
        let got = extract_procedures(SAMPLE);
        let names: Vec<&str> = got.iter().map(|(n, _)| n.as_str()).collect();
        assert!(names.contains(&"deploy"));
        assert!(names.contains(&"rollback"));
        // debug has no steps — should be skipped
        assert!(!names.contains(&"debug"));
    }

    #[test]
    fn extracts_deploy_steps() {
        let got = extract_procedures(SAMPLE);
        let deploy = got.iter().find(|(n, _)| n == "deploy").unwrap();
        assert_eq!(deploy.1.len(), 3);
        assert_eq!(deploy.1[0], ("build".into(), "just build".into()));
        assert_eq!(deploy.1[2], ("release".into(), "just release".into()));
    }

    #[test]
    fn render_has_recipe_envelope() {
        let steps = vec![("build".into(), "just build".into())];
        let out = render_recipe("demo", "deploy", &steps);
        assert!(out.contains("@recipe(version=\"1.0\"):"));
        assert!(out.contains("id: recipe-demo-deploy"));
        assert!(out.contains("name: \"Deploy procedure for demo\""));
        assert!(out.contains("command: \"just build\""));
        assert!(out.ends_with("@end\n@end\n"));
    }

    #[test]
    fn balanced_sexp_counts_correctly() {
        assert_eq!(balanced_sexp("(a (b) c)"), "(a (b) c)");
        assert_eq!(balanced_sexp("(a \"b)c\" d)"), "(a \"b)c\" d)");
        assert_eq!(balanced_sexp(""), "");
        assert_eq!(balanced_sexp("x"), "");
    }

    #[test]
    fn title_case_words() {
        assert_eq!(title_case("deploy"), "Deploy");
        assert_eq!(title_case("run-tests"), "Run Tests");
    }
}
