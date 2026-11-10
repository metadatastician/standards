# Security Policy

`metadatastician/standards` is the policy-and-tooling canon for the estate: it
ships specifications, CI workflows, and small local utilities — no networked
services and no production credentials.

## Supported versions

Only the tip of `main` is supported. The workflows and scripts in this
repository are consumed by pinned commit SHA across the estate; older commits
are superseded, not maintained.

## Reporting a vulnerability

**Do not open a public issue.** Use one of these private channels:

1. [Private vulnerability reporting](https://github.com/metadatastician/standards/security/advisories/new)
   on this repository (preferred — keeps the report linked to the fix), or
2. Email the maintainer: `j.d.a.jewell@open.ac.uk`.

Include the affected file(s) and commit SHA, steps to reproduce, and the
impact you see. Reports are acknowledged within 7 days; fixes land as
ordinary pull requests and are credited in the release notes unless you ask
otherwise.

## Scope notes

- Findings from the estate's own scanners (Hypatia, CodeQL, secret scanning)
  are already tracked: see `.hypatia-baseline.json` for acknowledged items.
- Supply-chain pins live in `.github/workflows/actions.lock`, verified in CI
  on every change — a stale lock fails the build rather than shipping.
