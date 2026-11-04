# gitbot-fleet report-backs

One JSON envelope per enrolled fleet member, `<member>.json`, in the shape
`docs/VERDICT-GRID-SPEC.adoc` defines (section "The report-back envelope").

**This directory is empty in git on purpose, and stays so.** The envelopes
are produced per run by the `fleet` job of `.github/workflows/fork-governance.yml`
(gitbot-fleet's `scripts/fleet-report-back.sh`), uploaded as the
`fleet-report-backs` artifact, and downloaded here by
`hypatia-scan-reusable.yml` only at render time. A committed envelope would be
stale evidence about an older commit, so none is ever committed; an enrolled
member with no envelope renders **orange** ("enrolled, but no report-back was
received"), and only a real run may change that.

Which members apply to this repository, and why the others do not, is stated
in `../enrolment.json`. Only `*.json` files are read, so this README is inert.
