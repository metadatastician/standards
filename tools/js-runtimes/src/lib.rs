// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
//! One `package.json`, every JavaScript runtime (3-practice/LANGUAGE-POLICY.adoc §1.4).
//!
//! The estate's preference order is Bun, then Deno, then pnpm, then npm (owner
//! ruling 2026-10-14). `package.json` is the only manifest; each runtime that
//! keeps a lockfile writes its own. This library holds the parts that do not
//! shell out: the order, the JCS check (in-process, via `ijson-jcs`), the
//! `scripts.test` lookup, and the reading of a repository's environment
//! definitions (mise, Containerfiles, Guix) to see which runtimes they provision.

use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};

/// A JavaScript runtime the estate recognises, in preference order.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Runtime {
    Bun,
    Deno,
    Pnpm,
    Npm,
}

/// The preference order. The first runtime an environment provides is the
/// one to use.
pub const ORDER: [Runtime; 4] = [Runtime::Bun, Runtime::Deno, Runtime::Pnpm, Runtime::Npm];

/// The runtimes whose generated lock the estate tracks. npm has none:
/// a tracked `package-lock.json` stays refused (standards#67).
pub const LOCKED: [Runtime; 3] = [Runtime::Bun, Runtime::Deno, Runtime::Pnpm];

impl Runtime {
    /// The runtime's command-line binary name.
    pub fn name(self) -> &'static str {
        match self {
            Runtime::Bun => "bun",
            Runtime::Deno => "deno",
            Runtime::Pnpm => "pnpm",
            Runtime::Npm => "npm",
        }
    }

    /// Looks up a runtime by its binary name, e.g. `"bun"`.
    pub fn parse(s: &str) -> Option<Runtime> {
        ORDER.iter().copied().find(|r| r.name() == s)
    }

    /// The lockfile this runtime writes, if the estate tracks one.
    pub fn lockfile(self) -> Option<&'static str> {
        match self {
            Runtime::Bun => Some("bun.lock"),
            Runtime::Deno => Some("deno.lock"),
            Runtime::Pnpm => Some("pnpm-lock.yaml"),
            Runtime::Npm => None,
        }
    }

    /// The command that runs a `package.json` script under this runtime.
    pub fn run_script(self) -> [&'static str; 2] {
        match self {
            Runtime::Bun => ["bun", "run"],
            Runtime::Deno => ["deno", "task"],
            Runtime::Pnpm => ["pnpm", "run"],
            Runtime::Npm => ["npm", "run"],
        }
    }
}

impl fmt::Display for Runtime {
    /// Displays the runtime using its binary name.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.name())
    }
}

/// The JCS state of a document.
#[derive(Debug, PartialEq, Eq)]
pub enum Canon {
    /// The bytes are JCS, optionally followed by one line feed.
    Canonical,
    /// Valid I-JSON, not in canonical form; carries the canonical bytes + LF.
    NotCanonical(Vec<u8>),
    /// Not I-JSON (or not JSON at all).
    Invalid(String),
}

/// Classify a document exactly as `ijson-jcs check` does: canonical when the
/// bytes, less one trailing line feed, equal the JCS serialisation.
pub fn canon(bytes: &[u8]) -> Canon {
    let value = match ijson_jcs::parse_json_bytes(bytes, ijson_jcs::JsonMode::Canonical) {
        Ok(v) => v,
        Err(e) => return Canon::Invalid(e.to_string()),
    };
    let jcs = match ijson_jcs::canonicalize(&value) {
        Ok(b) => b,
        Err(e) => return Canon::Invalid(e.to_string()),
    };
    let body = bytes.strip_suffix(b"\n").unwrap_or(bytes);
    if body == jcs.as_slice() {
        Canon::Canonical
    } else {
        let mut wanted = jcs;
        wanted.push(b'\n');
        Canon::NotCanonical(wanted)
    }
}

/// Does this `package.json` declare a string `scripts.test`?
pub fn has_test_script(bytes: &[u8]) -> bool {
    match ijson_jcs::parse_json_bytes(bytes, ijson_jcs::JsonMode::Loose) {
        Ok(v) => v
            .get("scripts")
            .and_then(|s| s.get("test"))
            .is_some_and(|t| t.is_string()),
        Err(_) => false,
    }
}

/// The `package.json` fields that declare dependencies a lock would pin.
pub const DEPENDENCY_FIELDS: [&str; 4] = [
    "dependencies",
    "devDependencies",
    "optionalDependencies",
    "peerDependencies",
];

/// Is this `package.json` a zero-dependency package (owner ruling
/// 2026-11-14, 3-practice/LANGUAGE-POLICY.adoc §1.4)? Such a package needs
/// no lock: Bun deletes the empty `bun.lock` it would write, and Deno writes
/// no `deno.lock`.
///
/// It is one where each of [`DEPENDENCY_FIELDS`] is absent or an empty
/// object, a `bundleDependencies` / `bundledDependencies` list is absent,
/// `false` or empty, and `workspaces` is absent, an empty list or an empty
/// object (a workspace root resolves its members' dependencies into one
/// lock). Fail closed: any other value, or a document that does not parse,
/// is not zero-dependency, so the lock rule applies. A `pnpm-workspace.yaml`
/// beside the manifest is the caller's to check: this sees only the bytes.
pub fn is_zero_dependency(bytes: &[u8]) -> bool {
    let Ok(v) = ijson_jcs::parse_json_bytes(bytes, ijson_jcs::JsonMode::Loose) else {
        return false;
    };
    let Some(obj) = v.as_object() else {
        return false;
    };
    let empty_object = |k: &str| match obj.get(k) {
        None => true,
        Some(x) => x.as_object().is_some_and(|o| o.is_empty()),
    };
    let empty_list = |k: &str| match obj.get(k) {
        None => true,
        Some(x) => x.as_array().is_some_and(|a| a.is_empty()) || x.as_bool() == Some(false),
    };
    DEPENDENCY_FIELDS.iter().all(|k| empty_object(k))
        && empty_list("bundleDependencies")
        && empty_list("bundledDependencies")
        && match obj.get("workspaces") {
            None => true,
            Some(x) => {
                x.as_array().is_some_and(|a| a.is_empty())
                    || x.as_object().is_some_and(|o| o.is_empty())
            }
        }
}

/// The first runtime in preference order for which `available` holds.
pub fn pick(available: impl Fn(Runtime) -> bool) -> Option<Runtime> {
    ORDER.iter().copied().find(|&r| available(r))
}

// ── Environment definitions ────────────────────────────────────────────────

/// The kinds of environment definition the estate provisions through.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EnvKind {
    Mise,
    Container,
    Guix,
}

impl EnvKind {
    /// The short label used in output, e.g. `"mise"`.
    pub fn name(self) -> &'static str {
        match self {
            EnvKind::Mise => "mise",
            EnvKind::Container => "container",
            EnvKind::Guix => "guix",
        }
    }

    /// Whether Bun can always be provisioned through this kind, so that a
    /// definition that settles for less is a finding, not a fallback. mise
    /// has a bun backend and container images can always add Bun; whether a
    /// Guix channel packages Bun is not something this tool can know, so for
    /// Guix the best runtime it does provision is accepted, and reported.
    pub fn bun_always_possible(self) -> bool {
        !matches!(self, EnvKind::Guix)
    }
}

/// One environment definition and the runtimes it provisions.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EnvDef {
    pub kind: EnvKind,
    pub path: PathBuf,
    pub provides: Vec<Runtime>,
}

impl EnvDef {
    /// The most-preferred runtime this definition provisions, if any.
    pub fn best(&self) -> Option<Runtime> {
        pick(|r| self.provides.contains(&r))
    }
}

/// Lower-case alphanumeric (plus `.`, `-`, `_`, `/`, `:`) tokens of a line,
/// so `oven/bun:1.4` and `bun.sh/install` survive as single tokens.
fn tokens(line: &str) -> Vec<String> {
    line.to_ascii_lowercase()
        .split(|c: char| !(c.is_ascii_alphanumeric() || "._-/:@=".contains(c)))
        .filter(|t| !t.is_empty())
        .map(str::to_string)
        .collect()
}

/// Runtimes named by the `[tools]` table of a mise.toml.
pub fn mise_provides(text: &str) -> Vec<Runtime> {
    let mut in_tools = false;
    let mut found = Vec::new();
    for raw in text.lines() {
        let line = raw.split('#').next().unwrap_or("").trim();
        if line.starts_with('[') {
            in_tools = line == "[tools]";
            continue;
        }
        if !in_tools || !line.contains('=') {
            continue;
        }
        let key = line
            .split('=')
            .next()
            .unwrap_or("")
            .trim()
            .trim_matches('"')
            .to_ascii_lowercase();
        let r = match key.as_str() {
            "bun" => Some(Runtime::Bun),
            "deno" => Some(Runtime::Deno),
            "pnpm" | "npm:pnpm" => Some(Runtime::Pnpm),
            "node" | "nodejs" => Some(Runtime::Npm),
            _ => None,
        };
        if let Some(r) = r {
            if !found.contains(&r) {
                found.push(r);
            }
        }
    }
    found.sort();
    found
}

/// Join a Containerfile's backslash-continued lines into instructions.
fn instructions(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    for raw in text.lines() {
        let line = raw.trim();
        if cur.is_empty() && (line.starts_with('#') || line.is_empty()) {
            continue;
        }
        if let Some(stripped) = line.strip_suffix('\\') {
            cur.push_str(stripped);
            cur.push(' ');
        } else {
            cur.push_str(line);
            out.push(std::mem::take(&mut cur));
        }
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

/// Runtimes a Containerfile provisions: a base or `COPY --from` image that
/// ships the runtime, or a `RUN` that installs it. Merely *using* a runtime
/// (`RUN bun install`, `COPY bun.lock`) does not count.
pub fn container_provides(text: &str) -> Vec<Runtime> {
    let mut found = Vec::new();
    let mut add = |r: Runtime| {
        if !found.contains(&r) {
            found.push(r);
        }
    };
    for ins in instructions(text) {
        let toks = tokens(&ins);
        let Some(op) = toks.first().map(String::as_str) else {
            continue;
        };
        let image_has = |name: &str| {
            toks.iter().any(|t| {
                let img = t.strip_prefix("--from=").unwrap_or(t);
                let base = img.split(['@', ':']).next().unwrap_or(img);
                base == name || base.ends_with(&format!("/{name}"))
            })
        };
        match op {
            "from" | "copy" => {
                if op == "copy" && !toks.iter().any(|t| t.starts_with("--from=")) {
                    continue;
                }
                if image_has("oven/bun") || image_has("bun") {
                    add(Runtime::Bun);
                }
                if image_has("denoland/deno") || image_has("deno") {
                    add(Runtime::Deno);
                }
                if image_has("node") {
                    add(Runtime::Npm);
                }
            }
            "run" => {
                let installs = |pkg: &str| {
                    let pm = [
                        "apk", "apt-get", "apt", "dnf", "yum", "zypper", "guix", "brew",
                    ];
                    let has_pm = toks.iter().any(|t| pm.contains(&t.as_str()));
                    let has_verb = toks.iter().any(|t| t == "add" || t == "install");
                    has_pm && has_verb && toks.iter().any(|t| t == pkg)
                };
                let mise = |pkg: &str| {
                    toks.iter().any(|t| t == "mise")
                        && toks.iter().any(|t| t == "use" || t == "install")
                        && toks
                            .iter()
                            .any(|t| t == pkg || t.starts_with(&format!("{pkg}@")))
                };
                if installs("bun")
                    || mise("bun")
                    || toks
                        .iter()
                        .any(|t| t.contains("bun.sh/install") || t.contains("oven-sh/bun/releases"))
                {
                    add(Runtime::Bun);
                }
                if installs("deno")
                    || mise("deno")
                    || toks.iter().any(|t| {
                        t.contains("deno.land/install") || t.contains("denoland/deno/releases")
                    })
                {
                    add(Runtime::Deno);
                }
                let corepack_pnpm = toks.iter().any(|t| t == "corepack")
                    && toks.iter().any(|t| t == "pnpm" || t.starts_with("pnpm@"));
                let npm_g_pnpm = toks.iter().any(|t| t == "npm")
                    && toks.iter().any(|t| t == "-g" || t == "--global")
                    && toks.iter().any(|t| t == "pnpm" || t.starts_with("pnpm@"));
                if installs("pnpm") || mise("pnpm") || corepack_pnpm || npm_g_pnpm {
                    add(Runtime::Pnpm);
                }
                if installs("nodejs") || installs("node") || mise("node") {
                    add(Runtime::Npm);
                }
            }
            _ => {}
        }
    }
    found.sort();
    found
}

/// Runtimes a Guix manifest or package file names as packages. Comments
/// (`;`) are ignored; a runtime counts when its package name appears as a
/// quoted specification or a bare symbol.
pub fn guix_provides(text: &str) -> Vec<Runtime> {
    let mut found = Vec::new();
    for raw in text.lines() {
        let line = raw.split(';').next().unwrap_or("");
        for t in tokens(line) {
            let t = t.trim_matches('"');
            let r = match t {
                "bun" => Some(Runtime::Bun),
                "deno" => Some(Runtime::Deno),
                "pnpm" => Some(Runtime::Pnpm),
                "node" | "node-lts" => Some(Runtime::Npm),
                _ => None,
            };
            if let Some(r) = r {
                if !found.contains(&r) {
                    found.push(r);
                }
            }
        }
    }
    found.sort();
    found
}

const SKIP_DIRS: [&str; 7] = [
    ".git",
    "node_modules",
    "target",
    "_build",
    "vendor",
    ".deno",
    "9-archive",
];

/// Every environment definition under `root`: `mise.toml` / `.mise.toml`,
/// `Containerfile*` / `Dockerfile*`, and Guix's `guix.scm` / `manifest.scm`
/// (also under `.guix/`).
pub fn find_env_defs(root: &Path) -> Vec<EnvDef> {
    let mut out = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(rd) = fs::read_dir(&dir) else { continue };
        let mut entries: Vec<_> = rd.flatten().collect();
        entries.sort_by_key(|e| e.file_name());
        for e in entries {
            let path = e.path();
            let name = e.file_name().to_string_lossy().to_string();
            if path.is_dir() {
                if !SKIP_DIRS.contains(&name.as_str()) {
                    stack.push(path);
                }
                continue;
            }
            let kind = if name == "mise.toml" || name == ".mise.toml" {
                Some(EnvKind::Mise)
            } else if name.starts_with("Containerfile")
                || name.starts_with("Dockerfile")
                || name.ends_with(".Containerfile")
            {
                Some(EnvKind::Container)
            } else if name == "guix.scm" || name == "manifest.scm" {
                Some(EnvKind::Guix)
            } else {
                None
            };
            let Some(kind) = kind else { continue };
            let Ok(text) = fs::read_to_string(&path) else {
                continue;
            };
            let provides = match kind {
                EnvKind::Mise => mise_provides(&text),
                EnvKind::Container => container_provides(&text),
                EnvKind::Guix => guix_provides(&text),
            };
            let rel = path.strip_prefix(root).unwrap_or(&path).to_path_buf();
            out.push(EnvDef {
                kind,
                path: rel,
                provides,
            });
        }
    }
    out.sort_by(|a, b| a.path.cmp(&b.path));
    out
}

/// The verdict on one environment definition.
#[derive(Debug, PartialEq, Eq)]
pub enum Verdict {
    /// Provisions Bun: the preference order is satisfied.
    Best,
    /// Provisions only a lower runtime, and Bun is not always possible here
    /// (Guix): accepted, reported.
    Fallback(Runtime),
    /// Provisions only a lower runtime where Bun is always possible: a finding.
    Below(Runtime),
    /// Provisions no JavaScript runtime at all.
    None,
}

/// Classifies one environment definition against the preference order.
pub fn verdict(def: &EnvDef) -> Verdict {
    match def.best() {
        Some(Runtime::Bun) => Verdict::Best,
        Some(r) if def.kind.bun_always_possible() => Verdict::Below(r),
        Some(r) => Verdict::Fallback(r),
        None => Verdict::None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The preference order is Bun, Deno, pnpm, npm, and `pick` honours it.
    #[test]
    fn order_is_bun_deno_pnpm_npm() {
        assert_eq!(ORDER.map(Runtime::name), ["bun", "deno", "pnpm", "npm"]);
        assert_eq!(pick(|_| true), Some(Runtime::Bun));
        assert_eq!(pick(|r| r != Runtime::Bun), Some(Runtime::Deno));
        assert_eq!(
            pick(|r| r == Runtime::Npm || r == Runtime::Pnpm),
            Some(Runtime::Pnpm)
        );
        assert_eq!(pick(|r| r == Runtime::Npm), Some(Runtime::Npm));
        assert_eq!(pick(|_| false), None);
    }

    /// npm has no tracked lock; every `LOCKED` runtime does.
    #[test]
    fn npm_keeps_no_lock() {
        assert_eq!(Runtime::Npm.lockfile(), None);
        assert!(LOCKED.iter().all(|r| r.lockfile().is_some()));
    }

    /// `canon` classifies documents the same way `ijson-jcs check` does.
    #[test]
    fn canon_matches_ijson_jcs_check() {
        assert_eq!(canon(b"{\"a\":1,\"b\":[true,null]}\n"), Canon::Canonical);
        assert_eq!(canon(b"{\"a\":1}"), Canon::Canonical);
        assert_eq!(
            canon(b"{\"b\":1,\"a\":2}\n"),
            Canon::NotCanonical(b"{\"a\":2,\"b\":1}\n".to_vec())
        );
        assert!(matches!(
            canon(b"{\n  \"a\": 1\n}\n"),
            Canon::NotCanonical(_)
        ));
        assert!(matches!(canon(b"{\"a\":1,\"a\":2}"), Canon::Invalid(_)));
        assert!(matches!(canon(b"not json"), Canon::Invalid(_)));
    }

    /// `has_test_script` finds a string `scripts.test`, and only that.
    #[test]
    fn test_script_lookup() {
        assert!(has_test_script(br#"{"scripts":{"test":"echo ok"}}"#));
        assert!(!has_test_script(br#"{"scripts":{"build":"x"}}"#));
        assert!(!has_test_script(br#"{"scripts":{"test":1}}"#));
        assert!(!has_test_script(br#"{}"#));
    }

    /// A zero-dependency package declares no dependency in any field, no
    /// bundle list and no workspace; anything else, or anything malformed,
    /// keeps the lock rule (owner ruling 2026-11-14).
    #[test]
    fn zero_dependency_definition() {
        // Zero-dependency: fields absent, or empty.
        assert!(is_zero_dependency(br#"{"name":"x"}"#));
        assert!(is_zero_dependency(
            br#"{"dependencies":{},"devDependencies":{},"optionalDependencies":{},"peerDependencies":{}}"#
        ));
        assert!(is_zero_dependency(
            br#"{"bundleDependencies":[],"bundledDependencies":false,"workspaces":[]}"#
        ));
        assert!(is_zero_dependency(
            b"{\n  \"name\": \"x\",\n  \"workspaces\": {}\n}\n"
        ));
        // Any one dependency field with an entry is a dependency.
        for f in DEPENDENCY_FIELDS {
            let doc = format!(r#"{{"{f}":{{"is-number":"7.0.0"}}}}"#);
            assert!(!is_zero_dependency(doc.as_bytes()), "{f}");
        }
        // A bundle list or a workspace keeps the lock rule.
        assert!(!is_zero_dependency(br#"{"bundleDependencies":["a"]}"#));
        assert!(!is_zero_dependency(br#"{"bundledDependencies":true}"#));
        assert!(!is_zero_dependency(br#"{"workspaces":["packages/*"]}"#));
        assert!(!is_zero_dependency(br#"{"workspaces":{"packages":["a"]}}"#));
        // Fail closed on a malformed field or document.
        assert!(!is_zero_dependency(br#"{"dependencies":["is-number"]}"#));
        assert!(!is_zero_dependency(br#"{"dependencies":null}"#));
        assert!(!is_zero_dependency(br#"[]"#));
        assert!(!is_zero_dependency(b"not json"));
    }

    /// Only the `[tools]` table of a mise.toml is read for runtimes.
    #[test]
    fn mise_tools_table_only() {
        let t = "[settings]\nbun = \"no\"\n[tools]\nzig = \"latest\"\nbun = \"1.4.2\" # js\n\"npm:pnpm\" = \"10\"\n[env]\ndeno = \"x\"\n";
        assert_eq!(mise_provides(t), vec![Runtime::Bun, Runtime::Pnpm]);
        assert_eq!(
            mise_provides("[tools]\nnode = \"22\"\n"),
            vec![Runtime::Npm]
        );
        assert!(mise_provides("[tools]\njust = \"latest\"\n").is_empty());
    }

    /// Provisioning requires a base/copied image or install step, not mere use.
    #[test]
    fn container_provisioning_not_mere_use() {
        assert_eq!(
            container_provides("FROM oven/bun:1.4.2-alpine\nRUN bun install\n"),
            vec![Runtime::Bun]
        );
        assert_eq!(
            container_provides(
                "FROM alpine\nCOPY --from=oven/bun:1.4 /usr/local/bin/bun /usr/local/bin/\n"
            ),
            vec![Runtime::Bun]
        );
        assert_eq!(
            container_provides("FROM alpine\nRUN apk add --no-cache \\\n    bun\n"),
            vec![Runtime::Bun]
        );
        assert_eq!(
            container_provides("FROM node:22\nRUN corepack enable pnpm\n"),
            vec![Runtime::Pnpm, Runtime::Npm]
        );
        assert_eq!(
            container_provides("FROM denoland/deno:2.9.6\n"),
            vec![Runtime::Deno]
        );
        // Using bun, or copying its lockfile, is not provisioning it.
        assert!(container_provides(
            "FROM alpine\nCOPY package.json bun.lock ./\nRUN bun install\n"
        )
        .is_empty());
        assert!(container_provides("# FROM oven/bun\nFROM alpine\n").is_empty());
    }

    /// Guix package names are matched ignoring commented-out lines.
    #[test]
    fn guix_names_packages_ignoring_comments() {
        assert_eq!(
            guix_provides("(specifications->manifest\n  (list \"node\" \"bun\"))\n"),
            vec![Runtime::Bun, Runtime::Npm]
        );
        assert!(
            guix_provides("; bun would be nice\n(specifications->manifest (list \"zig\"))\n")
                .is_empty()
        );
    }

    /// `verdict` covers the Best, Below, Fallback and None outcomes.
    #[test]
    fn verdicts() {
        let d = |kind, provides: Vec<Runtime>| EnvDef {
            kind,
            path: PathBuf::from("x"),
            provides,
        };
        assert_eq!(
            verdict(&d(EnvKind::Mise, vec![Runtime::Bun, Runtime::Npm])),
            Verdict::Best
        );
        assert_eq!(
            verdict(&d(EnvKind::Mise, vec![Runtime::Deno])),
            Verdict::Below(Runtime::Deno)
        );
        assert_eq!(
            verdict(&d(EnvKind::Container, vec![Runtime::Npm])),
            Verdict::Below(Runtime::Npm)
        );
        assert_eq!(
            verdict(&d(EnvKind::Guix, vec![Runtime::Npm])),
            Verdict::Fallback(Runtime::Npm)
        );
        assert_eq!(verdict(&d(EnvKind::Guix, vec![])), Verdict::None);
    }
}
