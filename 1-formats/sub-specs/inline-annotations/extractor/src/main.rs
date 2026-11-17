// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// inline-annotations extractor — reference implementation
//
// Reads source files, finds @trust/@contract/@grade annotations in comments,
// emits an A2ML document to stdout (or --out file). See 1-formats/sub-specs/inline-annotations/SPEC.adoc.

use std::collections::HashMap;
use std::env;
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::{SystemTime, UNIX_EPOCH};

use walkdir::WalkDir;

const GRAMMAR_VERSION: &str = "0.1.0";
const EXTRACTOR_VERSION: &str = env!("CARGO_PKG_VERSION");

/// Recognised annotation kinds.
const KINDS: &[&str] = &["trust", "contract", "grade"];

/// Comment prefix associated with a file extension.
/// Languages that use `//` or `#` or `--` — we match any of these prefixes on each line.
fn comment_prefixes_for(ext: &str) -> &'static [&'static str] {
    match ext {
        "rs" | "zig" | "gleam" | "ml" | "mli" | "js" | "mjs" | "ts" | "res" | "resi" | "idr"
        | "idr2" | "scala" | "java" | "kt" | "swift" | "go" | "c" | "h" | "cpp" | "hpp" | "cs" => {
            &["//"]
        }
        "sh" | "bash" | "ncl" | "scm" | "jl" | "py" | "rb" | "toml" | "yaml" | "yml" => &["#"],
        "adb" | "ads" | "agda" | "hs" | "lhs" | "lean" | "elm" => &["--"],
        _ => &[],
    }
}

#[derive(Debug)]
struct Annotation {
    file: String,
    line: usize,
    target_line: usize,
    kind: String,
    attrs: HashMap<String, String>,
}

fn main() -> ExitCode {
    let args: Vec<String> = env::args().skip(1).collect();
    let (out_path, lang_filter, paths) = match parse_args(&args) {
        Ok(x) => x,
        Err(msg) => {
            eprintln!("inline-annotations: {msg}");
            eprintln!("usage: inline-annotations [--out PATH] [--lang EXT] <paths...>");
            return ExitCode::from(2);
        }
    };

    if paths.is_empty() {
        eprintln!("inline-annotations: no input paths");
        return ExitCode::from(2);
    }

    let mut annotations: Vec<Annotation> = Vec::new();
    for root in &paths {
        for entry in WalkDir::new(root).into_iter().filter_map(Result::ok) {
            if !entry.file_type().is_file() {
                continue;
            }
            let path = entry.path();
            let ext = path
                .extension()
                .and_then(|e| e.to_str())
                .unwrap_or("")
                .to_lowercase();
            if let Some(filter) = &lang_filter {
                if &ext != filter {
                    continue;
                }
            }
            if comment_prefixes_for(&ext).is_empty() {
                continue;
            }
            if let Ok(contents) = fs::read_to_string(path) {
                extract_from_file(path, &ext, &contents, &mut annotations);
            }
        }
    }

    let rendered = render_a2ml(&annotations);
    match out_path {
        Some(p) => {
            if let Err(e) = fs::write(&p, rendered) {
                eprintln!("inline-annotations: write {}: {e}", p.display());
                return ExitCode::FAILURE;
            }
        }
        None => {
            if let Err(e) = io::stdout().write_all(rendered.as_bytes()) {
                eprintln!("inline-annotations: stdout: {e}");
                return ExitCode::FAILURE;
            }
        }
    }
    ExitCode::SUCCESS
}

/// Parse `[--out PATH] [--lang EXT] <paths...>`.
fn parse_args(args: &[String]) -> Result<(Option<PathBuf>, Option<String>, Vec<PathBuf>), String> {
    let mut out: Option<PathBuf> = None;
    let mut lang: Option<String> = None;
    let mut paths: Vec<PathBuf> = Vec::new();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--out" => {
                i += 1;
                let v = args.get(i).ok_or("missing value after --out")?;
                out = Some(PathBuf::from(v));
            }
            "--lang" => {
                i += 1;
                let v = args.get(i).ok_or("missing value after --lang")?;
                lang = Some(v.to_lowercase());
            }
            "-h" | "--help" => return Err("help".into()),
            s if s.starts_with("--") => return Err(format!("unknown flag: {s}")),
            s => paths.push(PathBuf::from(s)),
        }
        i += 1;
    }
    Ok((out, lang, paths))
}

/// Walk a file's lines, pulling annotations from comments.
fn extract_from_file(path: &Path, ext: &str, contents: &str, out: &mut Vec<Annotation>) {
    let prefixes = comment_prefixes_for(ext);
    let lines: Vec<&str> = contents.lines().collect();

    for (idx, raw) in lines.iter().enumerate() {
        let trimmed = raw.trim_start();
        // Does this line start with a known comment prefix?
        let Some(body) = prefixes
            .iter()
            .find_map(|p| trimmed.strip_prefix(p))
            .map(str::trim_start)
        else {
            continue;
        };

        // Must begin with @<kind>(
        if !body.starts_with('@') {
            continue;
        }
        let after_at = &body[1..];
        let Some(paren_pos) = after_at.find('(') else {
            continue;
        };
        let kind = after_at[..paren_pos].trim().to_lowercase();
        if !KINDS.contains(&kind.as_str()) {
            continue;
        }
        // Find matching close paren on the same line
        let rest = &after_at[paren_pos + 1..];
        let Some(close_pos) = rest.rfind(')') else {
            continue;
        };
        let attrs_str = &rest[..close_pos];
        let attrs = parse_attrs(attrs_str);

        let target_line = resolve_target_line(&lines, idx, prefixes);
        out.push(Annotation {
            file: path.to_string_lossy().into_owned(),
            line: idx + 1,
            target_line,
            kind,
            attrs,
        });
    }
}

/// Next non-comment, non-blank line after `idx` (1-indexed).
fn resolve_target_line(lines: &[&str], idx: usize, prefixes: &[&str]) -> usize {
    let mut j = idx + 1;
    while j < lines.len() {
        let t = lines[j].trim_start();
        if t.is_empty() || prefixes.iter().any(|p| t.starts_with(p)) {
            j += 1;
            continue;
        }
        return j + 1;
    }
    0
}

/// Parse `key=value, key="with spaces", key=42`.
fn parse_attrs(s: &str) -> HashMap<String, String> {
    let mut out = HashMap::new();
    let bytes = s.as_bytes();
    let mut i = 0usize;
    while i < bytes.len() {
        while i < bytes.len() && (bytes[i] as char).is_whitespace() {
            i += 1;
        }
        // key
        let k_start = i;
        while i < bytes.len() && bytes[i] != b'=' && bytes[i] != b',' {
            i += 1;
        }
        if i >= bytes.len() || bytes[i] != b'=' {
            break;
        }
        let key = s[k_start..i].trim().to_string();
        i += 1; // skip =
        while i < bytes.len() && (bytes[i] as char).is_whitespace() {
            i += 1;
        }
        // value — quoted or bare
        let value = if i < bytes.len() && (bytes[i] == b'"' || bytes[i] == b'\'') {
            let quote = bytes[i];
            i += 1;
            let v_start = i;
            while i < bytes.len() && bytes[i] != quote {
                if bytes[i] == b'\\' && i + 1 < bytes.len() {
                    i += 2;
                } else {
                    i += 1;
                }
            }
            let v = s[v_start..i].to_string();
            if i < bytes.len() {
                i += 1;
            } // skip close quote
            v
        } else {
            let v_start = i;
            while i < bytes.len() && bytes[i] != b',' {
                i += 1;
            }
            s[v_start..i].trim().to_string()
        };
        if !key.is_empty() {
            out.insert(key, value);
        }
        // skip comma
        while i < bytes.len() && (bytes[i] == b',' || (bytes[i] as char).is_whitespace()) {
            i += 1;
        }
    }
    out
}

fn render_a2ml(anns: &[Annotation]) -> String {
    let now = iso8601_now();
    let mut s = String::new();
    s.push_str("# SPDX-License-Identifier: MPL-2.0\n");
    s.push_str("# Emitted by inline-annotations extractor\n\n");
    s.push_str("@metadata:\n");
    s.push_str(&format!("extractor: inline-annotations\n"));
    s.push_str(&format!("extractor_version: {EXTRACTOR_VERSION}\n"));
    s.push_str(&format!("grammar_version: {GRAMMAR_VERSION}\n"));
    s.push_str(&format!("extracted_at: {now}\n"));
    s.push_str(&format!("count: {}\n", anns.len()));
    s.push_str("@end\n\n");

    for (i, a) in anns.iter().enumerate() {
        s.push_str(&format!(
            "@annotation(kind=\"{}\", id=\"ann-{i:06}\"):\n",
            a.kind
        ));
        s.push_str(&format!("file: {}\n", a.file));
        s.push_str(&format!("line: {}\n", a.line));
        s.push_str(&format!("target_line: {}\n", a.target_line));
        let mut keys: Vec<&String> = a.attrs.keys().collect();
        keys.sort();
        for k in keys {
            let v = &a.attrs[k];
            // quote values that contain spaces or punctuation
            let needs_quote = v.chars().any(|c| c == ' ' || c == ',' || c == ':');
            if needs_quote {
                s.push_str(&format!("{k}: \"{v}\"\n"));
            } else {
                s.push_str(&format!("{k}: {v}\n"));
            }
        }
        s.push_str("@end\n\n");
    }
    s
}

fn iso8601_now() -> String {
    // Minimal ISO-8601 UTC formatter — avoids chrono dependency.
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let (y, mo, d, h, mi, se) = epoch_to_ymd_hms(secs);
    format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{se:02}Z")
}

/// Civil-from-days algorithm (Howard Hinnant, public domain).
fn epoch_to_ymd_hms(secs: u64) -> (i64, u32, u32, u32, u32, u32) {
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    let h = (rem / 3_600) as u32;
    let mi = ((rem % 3_600) / 60) as u32;
    let se = (rem % 60) as u32;
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d, h, mi, se)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_trust_annotation() {
        let src = "// @trust(level=proven, prover=idris2, since=2026-03-12)\npub fn f() {}\n";
        let mut out = Vec::new();
        extract_from_file(Path::new("t.rs"), "rs", src, &mut out);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].kind, "trust");
        assert_eq!(out[0].attrs.get("level").unwrap(), "proven");
        assert_eq!(out[0].attrs.get("prover").unwrap(), "idris2");
        assert_eq!(out[0].attrs.get("since").unwrap(), "2026-03-12");
        assert_eq!(out[0].line, 1);
        assert_eq!(out[0].target_line, 2);
    }

    #[test]
    fn parses_quoted_values() {
        let src = "-- @contract(kind=dust, clause=\"provable constructively\", severity=high)\npostulate x : A\n";
        let mut out = Vec::new();
        extract_from_file(Path::new("t.agda"), "agda", src, &mut out);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].kind, "contract");
        assert_eq!(
            out[0].attrs.get("clause").unwrap(),
            "provable constructively"
        );
        assert_eq!(out[0].attrs.get("severity").unwrap(), "high");
    }

    #[test]
    fn skips_unknown_kinds() {
        let src = "// @bogus(x=1)\nfn f() {}\n// @trust(level=tested)\nfn g() {}\n";
        let mut out = Vec::new();
        extract_from_file(Path::new("t.rs"), "rs", src, &mut out);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].kind, "trust");
    }

    #[test]
    fn skips_comment_lines_for_target() {
        let src = "// @grade(value=B)\n// more prose\n\npub fn f() {}\n";
        let mut out = Vec::new();
        extract_from_file(Path::new("t.rs"), "rs", src, &mut out);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].target_line, 4);
    }

    #[test]
    fn hash_prefix_bash() {
        let src = "# @trust(level=reviewed, prover=manual)\nset -e\n";
        let mut out = Vec::new();
        extract_from_file(Path::new("t.sh"), "sh", src, &mut out);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].kind, "trust");
    }

    #[test]
    fn render_includes_metadata_header() {
        let anns = vec![Annotation {
            file: "x.rs".into(),
            line: 1,
            target_line: 2,
            kind: "grade".into(),
            attrs: [("value".to_string(), "B".to_string())].into(),
        }];
        let out = render_a2ml(&anns);
        assert!(out.contains("@metadata:"));
        assert!(out.contains("count: 1"));
        assert!(out.contains("@annotation(kind=\"grade\""));
        assert!(out.contains("value: B"));
    }

    #[test]
    fn epoch_converts_known_date() {
        // 2026-01-01T00:00:00Z = 1767225600
        let (y, m, d, h, mi, s) = epoch_to_ymd_hms(1_767_225_600);
        assert_eq!((y, m, d, h, mi, s), (2026, 1, 1, 0, 0, 0));
    }
}
