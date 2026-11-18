// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// k9-init — scaffold a coordination.k9 from a repo's existing descriptile files.
//
// Reads .machine_readable/descriptiles/{AGENTIC,META,NEUROSYM}.a2ml, extracts
// language/banned/practice information, and emits a starter coordination.k9
// that the human then refines. This is a one-shot migration tool — it does
// not try to be a general A2ML parser.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

const SCHEMA_VERSION: &str = "1.0.0";

struct RepoFacts {
    repo_name: String,
    languages: Vec<String>,
    banned: Vec<String>,
    practices: Vec<(String, String)>,
    has_agentic: bool,
    has_meta: bool,
    has_neurosym: bool,
}

fn main() -> ExitCode {
    let args: Vec<String> = env::args().skip(1).collect();
    let (repo_root, out_path, force) = match parse_args(&args) {
        Ok(x) => x,
        Err(msg) => {
            eprintln!("k9-init: {msg}");
            eprintln!("usage: k9-init [--out PATH] [--force] [REPO_ROOT]");
            eprintln!("  REPO_ROOT defaults to current directory");
            eprintln!("  --out defaults to REPO_ROOT/coordination.k9");
            return ExitCode::from(2);
        }
    };

    let out_path = out_path.unwrap_or_else(|| repo_root.join("coordination.k9"));
    if out_path.exists() && !force {
        eprintln!(
            "k9-init: refusing to overwrite {} (pass --force)",
            out_path.display()
        );
        return ExitCode::from(1);
    }

    let facts = gather_facts(&repo_root);
    if !facts.has_agentic && !facts.has_meta && !facts.has_neurosym {
        eprintln!(
            "k9-init: no descriptile A2ML files found under {}/.machine_readable/descriptiles/",
            repo_root.display()
        );
        eprintln!("         emitting a stub template only");
    }

    let rendered = render_k9(&facts);
    match fs::write(&out_path, rendered) {
        Ok(()) => {
            println!("k9-init: wrote {}", out_path.display());
            println!("  languages:  {}", facts.languages.len());
            println!("  banned:     {}", facts.banned.len());
            println!("  practices:  {}", facts.practices.len());
            println!("  NEXT: review the generated file, fill in invariants and architecture");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("k9-init: write {}: {e}", out_path.display());
            ExitCode::FAILURE
        }
    }
}

fn parse_args(args: &[String]) -> Result<(PathBuf, Option<PathBuf>, bool), String> {
    let mut out: Option<PathBuf> = None;
    let mut force = false;
    let mut root: Option<PathBuf> = None;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--out" => {
                i += 1;
                out = Some(PathBuf::from(
                    args.get(i).ok_or("missing value after --out")?,
                ));
            }
            "--force" => force = true,
            "-h" | "--help" => return Err("help".into()),
            s if s.starts_with("--") => return Err(format!("unknown flag: {s}")),
            s => {
                if root.is_some() {
                    return Err("only one REPO_ROOT may be given".into());
                }
                root = Some(PathBuf::from(s));
            }
        }
        i += 1;
    }
    let root = root.unwrap_or_else(|| PathBuf::from("."));
    Ok((root, out, force))
}

fn gather_facts(repo_root: &Path) -> RepoFacts {
    let a2ml_dir = repo_root.join(".machine_readable").join("descriptiles");
    let agentic = a2ml_dir.join("AGENTIC.a2ml");
    let meta = a2ml_dir.join("META.a2ml");
    let neurosym = a2ml_dir.join("NEUROSYM.a2ml");

    let repo_name = repo_root
        .canonicalize()
        .ok()
        .and_then(|p| p.file_name().map(|s| s.to_string_lossy().into_owned()))
        .unwrap_or_else(|| "unknown".into());

    let mut languages: Vec<String> = Vec::new();
    let mut banned: Vec<String> = Vec::new();
    let mut practices: Vec<(String, String)> = Vec::new();

    if let Ok(s) = fs::read_to_string(&agentic) {
        languages = extract_list(&s, "languages");
        banned = extract_list(&s, "banned");
    }
    if let Ok(s) = fs::read_to_string(&meta) {
        practices = extract_pairs(&s, "development-practices");
    }

    RepoFacts {
        repo_name,
        languages,
        banned,
        practices,
        has_agentic: agentic.exists(),
        has_meta: meta.exists(),
        has_neurosym: neurosym.exists(),
    }
}

/// Extract a list of strings from a Scheme-style `(key . ("a" "b" "c"))`.
/// Tolerant: finds `(<key> . (` or `(<key>` then pulls quoted strings until closing `))`.
fn extract_list(text: &str, key: &str) -> Vec<String> {
    let mut out = Vec::new();
    let needle = format!("({key}");
    let Some(start) = text.find(&needle) else {
        return out;
    };
    // find the end of this balanced s-expression
    let tail = &text[start..];
    let mut depth: i32 = 0;
    let mut end = tail.len();
    for (i, ch) in tail.char_indices() {
        match ch {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if depth == 0 {
                    end = i + 1;
                    break;
                }
            }
            _ => {}
        }
    }
    let region = &tail[..end];
    // pull quoted strings
    let mut in_str = false;
    let mut start_q = 0;
    for (i, ch) in region.char_indices() {
        if ch == '"' {
            if in_str {
                out.push(region[start_q..i].to_string());
                in_str = false;
            } else {
                in_str = true;
                start_q = i + 1;
            }
        }
    }
    out
}

/// Extract key/value pairs like `(code-style . "rescript")` within a named section.
fn extract_pairs(text: &str, section: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let needle = format!("({section}");
    let Some(start) = text.find(&needle) else {
        return out;
    };
    let tail = &text[start..];
    let mut depth: i32 = 0;
    let mut end = tail.len();
    for (i, ch) in tail.char_indices() {
        match ch {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if depth == 0 {
                    end = i + 1;
                    break;
                }
            }
            _ => {}
        }
    }
    let region = &tail[..end];
    // Scan for `(ident . "value")` — ident is ascii word chars, dot must
    // come before any new `(` or `)`.
    let bytes = region.as_bytes();
    let mut i = 0usize;
    while i < bytes.len() {
        if bytes[i] != b'(' {
            i += 1;
            continue;
        }
        let k_start = i + 1;
        // skip whitespace
        let mut j = k_start;
        while j < bytes.len() && (bytes[j] as char).is_whitespace() {
            j += 1;
        }
        // read identifier (ascii letters, digits, hyphen, underscore)
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
        let key = region[id_start..j].to_string();
        // skip whitespace, then require '.'
        while j < bytes.len() && (bytes[j] as char).is_whitespace() {
            j += 1;
        }
        if j >= bytes.len() || bytes[j] != b'.' {
            i += 1;
            continue;
        }
        j += 1; // past dot
        while j < bytes.len() && (bytes[j] as char).is_whitespace() {
            j += 1;
        }
        if j >= bytes.len() || bytes[j] != b'"' {
            i += 1;
            continue;
        }
        let vs = j + 1;
        if let Some(q2) = region[vs..].find('"') {
            let val = region[vs..vs + q2].to_string();
            out.push((key, val));
            i = vs + q2 + 1;
        } else {
            i += 1;
        }
    }
    out
}

fn render_k9(f: &RepoFacts) -> String {
    let today = "TODO-DATE";
    let mut s = String::new();
    s.push_str("K9!\n");
    s.push_str("# SPDX-License-Identifier: AGPL-3.0-or-later\n");
    s.push_str(&format!(
        "# coordination.k9 — AI Coordination Protocol for {}\n",
        f.repo_name
    ));
    s.push_str("# Generated by k9-init from descriptile A2ML files. REVIEW BEFORE USE.\n\n");
    s.push_str("---\n");
    s.push_str("metadata:\n");
    s.push_str(&format!("  schema: k9-coordination\n"));
    s.push_str(&format!("  schema_version: {SCHEMA_VERSION}\n"));
    s.push_str("  generated_by: k9-init\n");
    s.push_str(&format!("  last_updated: {today}\n\n"));

    s.push_str("project:\n");
    s.push_str(&format!("  name: \"{}\"\n", f.repo_name));
    s.push_str("  description: \"TODO — fill in\"\n");
    s.push_str("  license: PMPL-1.0-or-later\n");
    s.push_str("  languages:\n");
    if f.languages.is_empty() {
        s.push_str("    # TODO — list project languages\n");
    } else {
        for l in &f.languages {
            s.push_str(&format!("    - {l}\n"));
        }
    }
    s.push_str("  build_system: just\n\n");

    // Invariants from practices + banned
    s.push_str("invariants:\n");
    if !f.banned.is_empty() {
        s.push_str("  - id: banned-languages\n");
        s.push_str(&format!(
            "    rule: \"No files in banned languages: {}\"\n",
            f.banned.join(", ")
        ));
        s.push_str(
            "    reason: \"Repo inherited language policy from descriptile AGENTIC.a2ml\"\n",
        );
        s.push_str("    severity: high\n");
    }
    for (k, v) in &f.practices {
        s.push_str(&format!("  - id: practice-{}\n", slug(k)));
        s.push_str(&format!("    rule: \"{k}: {v}\"\n"));
        s.push_str("    reason: \"Development practice inherited from META.a2ml\"\n");
        s.push_str("    severity: medium\n");
    }
    if f.banned.is_empty() && f.practices.is_empty() {
        s.push_str("  # TODO — declare repo-level invariants\n");
    }
    s.push_str("\n");

    s.push_str("protected:\n");
    s.push_str("  # TODO — list paths that must not be mutated without review\n");
    s.push_str("  - path: LICENSE\n");
    s.push_str("    reason: \"License file is legal boilerplate\"\n\n");

    s.push_str("architecture:\n");
    s.push_str("  # TODO — record key architecture decisions here\n\n");

    s.push_str("innervation:\n");
    s.push_str("  afferent:\n");
    s.push_str("    # TODO — what signals does this repo emit?\n");
    s.push_str("  efferent:\n");
    s.push_str("    # TODO — what signals does this repo respond to?\n");
    s.push_str("  reflex:\n");
    s.push_str("    - trigger: \"pre-commit\"\n");
    s.push_str("      guard: \"panic-attack assail\"\n");
    s.push_str("      action: \"Block commit on critical findings\"\n\n");

    if !f.banned.is_empty() {
        s.push_str("do_not_create:\n");
        for b in &f.banned {
            s.push_str(&format!("  - pattern: \"**/*.{}\"\n", lang_ext(b)));
            s.push_str(&format!("    reason: \"{b} is banned\"\n"));
        }
        s.push_str("\n");
    }

    s.push_str("ecosystem:\n");
    s.push_str("  depends_on:\n");
    s.push_str("    # TODO — derive from actual imports\n");
    s.push_str("  consumed_by:\n");
    s.push_str("    # TODO — fill after ecosystem ingest pipeline runs\n");

    s
}

fn slug(s: &str) -> String {
    s.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' {
                c.to_ascii_lowercase()
            } else {
                '-'
            }
        })
        .collect()
}

fn lang_ext(name: &str) -> String {
    match name.to_ascii_lowercase().as_str() {
        "typescript" => "ts".into(),
        "python" => "py".into(),
        "go" => "go".into(),
        "java" => "java".into(),
        "kotlin" => "kt".into(),
        "swift" => "swift".into(),
        "makefile" => "mk".into(),
        other => other.into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_list_from_scheme() {
        let src = r#"((languages . ("rescript" "rust" "gleam"))
                      (banned . ("typescript" "go")))"#;
        assert_eq!(
            extract_list(src, "languages"),
            vec!["rescript", "rust", "gleam"]
        );
        assert_eq!(extract_list(src, "banned"), vec!["typescript", "go"]);
    }

    #[test]
    fn extracts_pairs_from_scheme() {
        let src = r#"(development-practices
                       ((code-style . "rescript")
                        (testing . "property-based")))"#;
        let got = extract_pairs(src, "development-practices");
        assert!(got
            .iter()
            .any(|(k, v)| k == "code-style" && v == "rescript"));
        assert!(got
            .iter()
            .any(|(k, v)| k == "testing" && v == "property-based"));
    }

    #[test]
    fn missing_key_returns_empty() {
        assert!(extract_list("(foo . 1)", "bar").is_empty());
        assert!(extract_pairs("(foo . 1)", "bar").is_empty());
    }

    #[test]
    fn render_includes_header_and_sections() {
        let f = RepoFacts {
            repo_name: "demo".into(),
            languages: vec!["rust".into()],
            banned: vec!["python".into()],
            practices: vec![("code-style".into(), "rescript".into())],
            has_agentic: true,
            has_meta: true,
            has_neurosym: false,
        };
        let out = render_k9(&f);
        assert!(out.starts_with("K9!"));
        assert!(out.contains("project:"));
        assert!(out.contains("name: \"demo\""));
        assert!(out.contains("- rust"));
        assert!(out.contains("banned-languages"));
        assert!(out.contains("practice-code-style"));
        assert!(out.contains("*.py"));
    }

    #[test]
    fn slug_normalises() {
        assert_eq!(slug("code-style"), "code-style");
        assert_eq!(slug("Test Case"), "test-case");
    }
}
