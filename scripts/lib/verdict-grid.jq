# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# verdict-grid.jq — the findings-family verdict grid (docs/VERDICT-GRID-SPEC.adoc).
#
# Input (one object, assembled by scripts/verdict-grid.sh):
#   { sources:   [ {kind, name, present, valid, doc} ... ],
#     enrolment: object | null,       # .gitbot-fleet/enrolment.json, parsed
#     previous:  object | null,       # baseline embedded in the previous comment
#     identity:  {lane, sha, run, url, pr, repo, dirty, refs: {hypatia, panic, pons}},
#     profile:   "sha256 hex",
#     scope:     {mode: whole-repo|delta, changed: [paths], excluded_prefixes: [prefixes]} }
#
# SCOPE decides what the grid GRADES, and nothing else. Every finding is still
# reported in the artifact and counted in the JSON; scope only chooses which
# ones can move a row's colour. Three buckets:
#
#   graded    the finding counts toward the row state and the table columns
#   standing  outside this change (delta mode): reported, not graded
#   excluded  under a declared out-of-scope prefix (frozen archive): reported,
#             never graded, in either mode
#
# This exists because a findings lane that grades the WHOLE repository produces
# a verdict that cannot change: 57 standing findings meant every pull request,
# including a one-line docs fix, was purple. A verdict that is the same on
# every revision is a verdict nobody reads, which is the same outcome as no
# lane at all -- and worse, because it looks like one.
# Output: the structured report; `render` turns it into Markdown.
#
# Every reporter is normalised to one record
#   { id, title, status: ran|not_run|error|not_applicable, reason, ref, findings }
# and every finding to { id, severity, file, line, message } with severity in
# critical | high | medium | low | info. Anything the adapter does not
# understand becomes status "error" with a reason: unreadable evidence is
# never a clean row.

def rank: {critical: 5, high: 4, medium: 3, low: 2, info: 1}[.] // 0;

def norm_sev:
  (. // "" | tostring | ascii_downcase)
  | if . == "critical" then "critical"
    elif . == "high" or . == "error" then "high"
    elif . == "medium" or . == "warn" or . == "warning" then "medium"
    elif . == "low" then "low"
    elif . == "info" or . == "informational" or . == "note" or . == "suggestion" then "info"
    else "unknown" end;

def finding(id; sev; file; line; msg; class):
  { id: (id // "" | tostring), severity: (sev | norm_sev),
    file: (file // "" | tostring), identity_file: (file // "" | tostring),
    line: (line // 0 | tonumber? // 0),
    message: (msg // "" | tostring), class: (class // "" | tostring) };

# Safe, lexical repository path normalisation. Paths outside the checkout or
# with unresolved leading '..' remain visible but cannot corroborate another
# result: absent identity must never collapse distinct defects.
def norm_path($root):
  (tostring | gsub("\\\\"; "/")) as $p
  | ($root | gsub("\\\\"; "/") | rtrimstr("/")) as $r
  | (if $r != "" and ($p | startswith($r + "/")) then $p | ltrimstr($r + "/") else $p end)
  | if startswith("/") or test("^[A-Za-z]:/") then .
    else reduce (split("/")[]) as $part ([];
      if $part == "" or $part == "." then .
      elif $part == ".." and length > 0 and .[-1] != ".." then .[0:-1]
      else . + [$part] end) | join("/") end;

def norm_class:
  ascii_downcase | gsub("^\\s+|\\s+$"; "")
  | if test("^cwe[-_ ]*[0-9]+$") then
      "cwe-" + (capture("^cwe[-_ ]*(?<n>[0-9]+)$").n | tonumber | tostring)
    else gsub("[^a-z0-9]"; "") end;

def fingerprint:
  (.class | norm_class) as $class
  | .identity_file as $file
  | if $file == "" or $file == "." or ($file | startswith("/")) or
       ($file | test("^[A-Za-z][A-Za-z0-9+.-]*:|^(\\.\\./|\\.\\.$)")) or
       .line <= 0 or (.line | floor != .) or
       ($class | IN("", "unknown", "finding", "error", "none"))
    then null else [$file, .line, $class] | tojson end;

def cwe_or_class($f; $fallback):
  if ($f.cwe // $f.cwe_id // null) != null then
    ($f.cwe // $f.cwe_id | tostring | if test("^[0-9]+$") then "CWE-" + . else . end)
  else ($f.class // $f.category // $fallback // "") end;

def reporter(id; title; status; reason; ref; findings):
  { id: id, title: title, status: status, reason: (reason // ""), ref: (ref // ""), findings: findings }
  | if .status == "ran" and (.findings | any(.severity == "unknown"))
    then .status = "error" | .reason = "a finding carries a severity the grid does not recognise"
    else . end;

# A status envelope shared by panic-attack and pons:
#   {status: ran|not_run|error, tool, ref, reason, exit_code, counts, report}
def envelope(id; title; src; items):
  if src.present | not then reporter(id; title; "not_run"; "no status envelope was produced"; ""; [])
  elif src.valid | not then reporter(id; title; "error"; "the status envelope is not valid JSON"; ""; [])
  elif (src.doc | type) != "object" or (src.doc.status | type) != "string"
    then reporter(id; title; "error"; "the status envelope has no status"; ""; [])
  elif src.doc.status == "ran" then
    (try (src.doc | items) catch null) as $f
    | if $f == null then reporter(id; title; "error"; "the envelope reports a run but carries no readable report"; src.doc.ref; [])
      else reporter(id; title; "ran"; ""; src.doc.ref; $f) end
  elif src.doc.status == "not_run" or src.doc.status == "error"
    then reporter(id; title; src.doc.status; (src.doc.reason // "no reason recorded"); src.doc.ref; [])
  else reporter(id; title; "error"; "unrecognised envelope status \(src.doc.status)"; src.doc.ref; []) end;

# The SARIF is the gate's exact, already-baseline/scope-filtered set. Raw JSON
# is retained separately for alert-derived and opt-in advisory inventory only.
def hypatia(src; ref; baseline_verified):
  if baseline_verified | not then reporter("hypatia"; "Hypatia scan"; "error"; "baseline present but SARIF filtering was not verified"; ref; [])
  elif src.present | not then reporter("hypatia"; "Hypatia scan"; "error"; "the scanner produced no SARIF projection"; ref; [])
  elif src.valid | not then reporter("hypatia"; "Hypatia scan"; "error"; "the SARIF file is not one valid JSON document"; ref; [])
  elif (try (src.doc.version == "2.1.0" and (src.doc.runs | type == "array" and length > 0)
      and all(src.doc.runs[]; .tool.driver.name == "Hypatia" and (.results | type == "array")
        and all(.results[]; type == "object" and (.ruleId | type == "string" and length > 0)
          and ((.properties | type) == "object" or .properties == null)
          and ((.locations | type) == "array" or .locations == null)
          and ((.message | type) == "object" or .message == null)
          and (try ((.locations[0].physicalLocation.artifactLocation.uri // "") | type == "string") catch false)
          and (try ((.message.text // "") | type == "string") catch false)
          and (.level as $l | ["error", "warning", "note", "none"] | index($l) != null)))) catch false) | not
    then reporter("hypatia"; "Hypatia scan"; "error"; "the SARIF projection is malformed"; ref; [])
  else (try [src.doc.runs[].results[]
     | (.properties // {}) as $p
     | (if .level == "error" and $p["hypatia.severity"] == "critical" then "critical"
        elif .level == "error" then "high"
        elif .level == "warning" then "medium" else "info" end) as $severity
     # Match the scope filter's all-locations rule: a mixed-scope SARIF
     # result remains visible, as does any result with an unknown location.
     | [ .locations[]? | (try (.physicalLocation.artifactLocation.uri // "") catch "")
         | if type == "string" then . else "" end ] as $scope_files
     | finding((.ruleId | sub("^hypatia/"; "")); $severity;
         (.locations[0].physicalLocation.artifactLocation.uri // "");
         (if $p | has("hypatia.originalLine") then $p["hypatia.originalLine"] else 0 end);
         (.message.text // ""); ($p["hypatia.class"] // (.ruleId | split("/") | last)))
     # SARIF may collapse an outside absolute path to a basename. Preserve the
     # original scanner path for correlation, but grade the SARIF URI itself.
     | .identity_file = (if ($p["hypatia.originalFile"] | type) == "string"
                          then $p["hypatia.originalFile"] else .file end)
     | .scope_files = $scope_files] catch null) as $findings
    | if $findings == null then
        reporter("hypatia"; "Hypatia scan"; "error"; "SARIF result properties or locations are unreadable"; ref; [])
      else reporter("hypatia"; "Hypatia scan"; "ran"; ""; ref; $findings) end
  end;

def panic(src):
  envelope("panic-attack"; "panic-attack assail"; src;
    [.report.weak_points[] | select(.suppressed != true)
     | . as $f | finding(.category; .severity; .file; .line; .description; cwe_or_class($f; .category))]);

def pons(src):
  envelope("pons-asinorum"; "pons asinorum"; src;
    [.report.findings[] | . as $f
     | finding(.rule_id; .severity; .location.file; .location.line_start;
         "\(.message) (\(.tier // "?"), \(.evidence // "?"))"; cwe_or_class($f; .rule_id))]);

def reportback(src):
  (src.name) as $id
  | if src.valid | not then reporter($id; $id; "error"; "the report-back is not valid JSON"; ""; [])
    elif (src.doc | type) != "object" then reporter($id; $id; "error"; "the report-back is not an object"; ""; [])
    elif (src.doc.reporter != null and ((src.doc.reporter | type) != "string" or src.doc.reporter == "")) or
         (src.doc.title != null and (src.doc.title | type) != "string")
      then reporter($id; $id; "error"; "the report-back identity is not a nonempty string"; ""; [])
    else (src.doc.reporter // $id) as $rid
    | (src.doc.title // $rid) as $title
    | if src.doc.status == "ran" then
        if (src.doc.findings | type) != "array" or any(src.doc.findings[]; type != "object") then
          reporter($rid; $title; "error"; "the report-back has no readable findings array"; src.doc.ref; [])
        else (try [src.doc.findings[] | . as $f | finding(.rule_id // .id; .severity; .file; .line; .message; cwe_or_class($f; (.rule_id // .id)))] catch null) as $fs
          | if $fs == null then reporter($rid; $title; "error"; "the report-back findings are unreadable"; src.doc.ref; [])
            else reporter($rid; $title; "ran"; ""; src.doc.ref; $fs) end
        end
      elif (src.doc.status | IN("not_run", "error", "not_applicable"))
        then reporter($rid; $title; src.doc.status; (src.doc.reason // "no reason recorded"); src.doc.ref; [])
      else reporter($rid; $title; "error"; "unrecognised report-back status \(src.doc.status)"; src.doc.ref; []) end
    end;

def counts_of($fs):
  { critical: ([$fs[] | select(.severity == "critical")] | length),
    high:     ([$fs[] | select(.severity == "high")] | length),
    medium:   ([$fs[] | select(.severity == "medium")] | length),
    minor:    ([$fs[] | select(.severity == "low" or .severity == "info")] | length) };

def counts: counts_of(.findings);

# Exclude a multi-location SARIF result only if every location is excluded,
# matching the authoritative SARIF scope filter. Any unknown location grades.
def path_excluded($sc; $path):
  ($path != "") and any((($sc.excluded_prefixes // [])[]); . as $p | $path | startswith($p));

def scope_paths($f):
  if ($f.scope_files | type) == "array" and ($f.scope_files | length) > 0
  then $f.scope_files else [($f.file // "")] end;

def under_exclusion($sc; $f):
  all(scope_paths($f)[]; path_excluded($sc; .));

def bucket($sc; $f):
  (scope_paths($f)) as $paths
  | if under_exclusion($sc; $f) then "excluded"
    elif any($paths[]; . == "") then "graded"
    elif ($sc.mode // "whole-repo") != "delta" then "graded"
    elif any($paths[]; . as $path | (path_excluded($sc; $path) | not)
             and any((($sc.changed // [])[]); . == $path)) then "graded"
    else "standing" end;

def normalize_finding($root):
  .file |= norm_path($root) | .identity_file |= norm_path($root)
  | if (.scope_files | type) == "array" then .scope_files |= map(norm_path($root)) else . end;

# Only add excluded results from a separate pre-scope, baseline-filtered
# projection. The gate SARIF stays authoritative for every graded finding.
# Subtract already-present results as a multiset so failed-open scope filters
# and repeated same-reporter results are neither hidden nor double-counted.
def extra_excluded($all; $present; $scope; $root):
  ($all.findings | map(normalize_finding($root))
    | map(select(under_exclusion($scope; .)))) as $excluded
  | ($present.findings | map(normalize_finding($root))
    | map(select(under_exclusion($scope; .)))
    | reduce .[] as $f ({}; ($f | tojson) as $k | .[$k] = ((.[$k] // 0) + 1))) as $counts
  | reduce $excluded[] as $f ({counts: $counts, extra: []};
      ($f | tojson) as $k
      | if (.counts[$k] // 0) > 0 then .counts[$k] -= 1
        else .extra += [$f] end) | .extra;

def hypatia_with_exclusions($gate; $pre; $scope; $root; $ref; $verified):
  hypatia($gate; $ref; $verified) as $row
  | if $pre == null or $row.status != "ran" then $row
    else hypatia($pre; $ref; $verified) as $full
      | if $full.status != "ran" then
          $row + {status: "error", reason: "pre-scope SARIF inventory is unavailable or malformed"}
        else $row | .findings += extra_excluded($full; $row; $scope; $root) end
    end;

def state:
  if .status == "not_applicable" then "grey"
  elif .status != "ran" then "orange"
  else ([.findings_graded[].severity | rank] | max // 0) as $m
    | if $m >= 5 then "purple" elif $m == 4 then "red" elif $m == 3 then "yellow"
      elif $m >= 1 then "blue" else "green" end end;

# Precedence: a known critical beats missing evidence, which beats anything milder.
def overall:
  if length == 0 then "orange"
  elif all(. == "grey") then "grey"
  else (["purple", "red", "orange", "yellow", "blue", "green"] as $order
        | . as $states | $order | map(select(. as $c | $states | index($c))) | first) end;

# Hypatia.Kin.Arbiter @ adb2f41, highest priority first. Unknown IDs sort
# after known members by name, not by artifact download or JSON key order.
def arbiter_priority:
  {echidnabot: 1, rhodibot: 2, panicbot: 3, sustainabot: 4, glambot: 5,
   seambot: 6, finishingbot: 7, cipherbot: 8, gsbot: 9, accessibilitybot: 10,
   "the-hotchocolabot": 11}[.] // 99;

# One occurrence per reporter may corroborate the same path/line/class in
# another reporter. Duplicates within a reporter remain distinct (ordinal),
# and unknown identity never merges. The worst severity survives the merge;
# neither deduplication nor advisory evidence affects the gating row's state.
def unique_graded($rows):
  [ $rows[] as $r | $r.findings_graded | to_entries[]
    | .key as $i | .value + {reporter: $r.id, gating: $r.gating, row_index: $i} ]
  | group_by([(.fingerprint // ("unmatched:" + .reporter + ":" + (.row_index | tostring))), .reporter])
  | map(sort_by(-(.severity | rank)) | to_entries | map(.value + {ordinal: .key})) | add // []
  | group_by([(.fingerprint // ("unmatched:" + .reporter + ":" + (.row_index | tostring))), .ordinal])
  | map(. as $group | (max_by(.severity | rank)) as $worst
    | {fingerprint: $worst.fingerprint, file: $worst.file, line: $worst.line,
       class: $worst.class, severity: $worst.severity,
       corroborated_by: ([$group[].reporter] | unique),
       sources: [$group[] | {reporter, id, severity, gating}]} );

def build:
  . as $in
  | ($in.scope // {mode: "whole-repo"}) as $scope
  | ($in.sources | map(select(.kind == "hypatia")) | first // {present: false}) as $h
  | ($in.sources | map(select(.kind == "hypatia-sarif")) | first // {present: false}) as $hs
  | ($in.sources | map(select(.kind == "hypatia-unscoped-sarif")) | first) as $hu
  | ($in.sources | map(select(.kind == "panic")) | first // {present: false}) as $p
  | ($in.sources | map(select(.kind == "pons")) | first // {present: false}) as $q
  | [ hypatia_with_exclusions($hs; $hu; $scope; ($in.root // ""); $in.identity.refs.hypatia; ($in.hypatia_baseline_verified != false)), panic($p), pons($q) ] as $builtin
  | [ $in.sources[] | select(.kind == "report-back") | reportback(.) ] as $backs
  | ($in.enrolment.reporters // {}) as $enrol
  | [ $enrol | to_entries[] | .key as $id | .value as $e
      | select(($backs | map(.id) | index($id)) == null)
      | if $e.enrolled == true
        then reporter($id; ($e.title // $id); "not_run"; "enrolled, but no report-back was received"; ""; [])
        else reporter($id; ($e.title // $id); "not_applicable"; ($e.reason // "not enrolled for this repository"); ""; []) end ] as $missing
  | ($builtin + (($backs + $missing) | sort_by([(.id | arbiter_priority), (.id | ascii_downcase)]))
     | map(.findings |= map(normalize_finding($in.root // "") | . + {fingerprint: fingerprint}))
     | map(. + {findings_graded:   [.findings[] | select(bucket($scope; .) == "graded")],
                findings_standing: [.findings[] | select(bucket($scope; .) == "standing")],
                findings_excluded: [.findings[] | select(bucket($scope; .) == "excluded")]})
     | map(. + {counts:          (.findings_graded   | counts_of(.)),
                counts_standing: (.findings_standing | counts_of(.)),
                counts_excluded: (.findings_excluded | counts_of(.))})
     # ── Gating vs advisory ────────────────────────────────────────────────
     # A row is GATING when failing it can block a merge. Only such a row may
     # set the lane's overall state; anything else is advertised but never
     # grades the change.
     #
     # Why this is not cosmetic: panic-attack's own step in the reusable says it
     # "does not gate", yet its findings were driving the lane purple on every
     # revision. A verdict a green gate contradicts teaches readers to ignore
     # the badge, and then to ignore the gate.
     #
     # The default is `true` ONLY for the Hypatia row: it is the one producer
     # whose findings pass through .hypatia-baseline.json and the blocking
     # gate. An enrolment manifest may override either way -- `gating` is read
     # as a boolean when present, never as a truthy string.
     | map(. as $r | . + {gating: (if (($enrol[$r.id].gating | type) == "boolean")
                                   then $enrol[$r.id].gating else ($r.id == "hypatia") end)})
     | map(. + {state: state})) as $reporters
  | ([$reporters[] | select(.gating)]) as $gating_rows
  | ([$reporters[] | select(.gating | not)]) as $advisory_rows
  | (unique_graded($reporters)) as $unique
  | ([$reporters[].findings_graded[]]) as $reported
  | (try ($h.valid and ($h.doc | type == "array" and all(.[];
       type == "object" and (.severity | IN("critical", "high", "medium", "warn", "low", "info", "informational"))))) catch false) as $raw_valid
  | (if $raw_valid then
       [$h.doc[] | select(.rule_module | IN("code_scanning_alerts", "dependabot_alerts", "secret_scanning_alerts"))]
     else [] end) as $alerts
  | (if $raw_valid then
       [$h.doc[] | select(.advisory == true and (.severity | IN("low", "info", "informational")))]
     else [] end) as $json_advisories
  | { schema: 3, lane: ($in.identity.lane // "hypatia"), profile: $in.profile,
      sha: ($in.identity.sha // ""), run: ($in.identity.run // "local"), url: ($in.identity.url // ""),
      pr: ($in.identity.pr // "local"), repo: ($in.identity.repo // ""), dirty: ($in.identity.dirty // false),
      generated: ($in.identity.generated // ""), refs: ($in.identity.refs // {}),
      scope: { mode: ($scope.mode // "whole-repo"),
               changed: (($scope.changed // []) | length),
               excluded_prefixes: ($scope.excluded_prefixes // []) },
      reporters: $reporters,
      # The lane state is the worst GATING row. When a lane has no gating row
      # at all, the state falls back to every row, because "no row can block"
      # must not read as "green".
      state: (if ($gating_rows | length) == 0
              then ($reporters | map(.state) | overall)
              else ($gating_rows | map(.state) | overall) end),
      advisory: { rows: ($advisory_rows | length),
                  state: (if ($advisory_rows | length) == 0 then "none"
                          else ($advisory_rows | map(.state) | overall) end),
                  critical: ([$advisory_rows[].findings_graded[] | select(.severity == "critical")] | length),
                  high: ([$advisory_rows[].findings_graded[] | select(.severity == "high")] | length) },
      # These totals cover all rows in grid scope (gating AND advisory); they
      # are not a gate. Row counts remain as reported, before deduplication.
      counts: counts_of($unique),
      reported_counts: counts_of($reported),
      unique_total: ($unique | length), reported_total: ($reported | length),
      uncorrelatable_total: ([$unique[] | select(.fingerprint == null)] | length),
      unique_findings: $unique,
      hypatia_json_advisories: {available: $raw_valid, total: ($json_advisories | length), findings: $json_advisories},
      hypatia_alerts: {available: $raw_valid, total: ($alerts | length),
        by_module: ($alerts | group_by(.rule_module) | map({key: .[0].rule_module, value: length}) | from_entries),
        # Raw JSON inventory; some alert-derived results may also be in SARIF.
        counts: ([$alerts[] | {severity: (.severity | norm_sev)}] | counts_of(.))} };

# One row's movement since the previous revision of the same PR. `report` is
# the whole report (profile, pr, sha); `.` is the row.
# These cases are different facts; a missing historical comparison must not
# look like a flat trend or an absent finding.
def comparison_gap(prev; report):
  if prev == null then "— no comparable baseline (no prior PR grid or unreadable snapshot)"
  elif prev.schema != 3 then "— no comparable baseline (schema changed)"
  elif prev.pr != report.pr then "— no comparable baseline (different PR)"
  elif prev.sha == report.sha then "— same commit (no revision comparison)"
  elif (prev.scope.mode // "unknown") != (report.scope.mode // "unknown") then "— no comparable baseline (scope changed)"
  elif prev.profile != report.profile then "— no comparable baseline (scanner or policy profile changed)"
  else null end;

def delta(prev; report):
  . as $r
  | (comparison_gap(prev; report)) as $gap
  | if $gap != null then $gap else
    (prev.reporters | map(select(.id == $r.id)) | first) as $b
    | if $b == null then "— no comparable baseline (reporter absent previously)"
      elif $b.status != $r.status then "— evidence changed"
      elif $r.status == "not_applicable" then "↔ unchanged"
      elif $r.status != "ran" then "— indeterminate"
      else (($b.counts.critical + $b.counts.high) as $a | ($r.counts.critical + $r.counts.high) as $c
        | if $c < $a then "↑ improved (\($a - $c) fewer blocking)"
          elif $c > $a then "↓ regressed (\($c - $a) more blocking)"
          elif $r.counts.medium < $b.counts.medium then "↑ fewer medium"
          elif $r.counts.medium > $b.counts.medium then "↓ more medium"
          elif $r.counts.minor < $b.counts.minor then "↑ fewer minor"
          elif $r.counts.minor > $b.counts.minor then "↓ more minor"
          else "↔ unchanged" end) end end;

def state_label: {purple: "🟣 critical", red: "🔴 high", orange: "🟠 indeterminate", yellow: "🟡 medium",
            blue: "🔵 minor", green: "🟢 clean", grey: "⚪ not applicable"}[.];
def colour: {purple: "blueviolet", red: "red", orange: "orange", yellow: "yellow",
             blue: "blue", green: "brightgreen", grey: "lightgrey"}[.];
def word: {purple: "critical", red: "high", orange: "indeterminate", yellow: "medium",
           blue: "minor", green: "clean", grey: "not_applicable"}[.];
def esc: tostring | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;") | gsub("\\|"; "&#124;")
         | gsub("`"; "&#96;") | gsub("\r?\n"; " ");
def badge_url(lbl; st): "https://img.shields.io/badge/\(lbl | @uri)-\(st | word | @uri)-\(st | colour)";

# The pinned CLI emits the normalized `type`, not the source rule's WF code.
# Give known advisory rules their human label without rewriting the raw JSON.
def advisory_rule_label:
  if .rule_module == "workflow_audit" then
    ({sha_pinned_toolchain_without_input: "WF026", known_broken_reusable_revision: "WF027",
      reusable_call_to_moved_repository: "WF028"}[.type] // .type // "?")
  else (.rule // .type // "?") end;

def render(prev):
  . as $r
  | ($r.lane | if . == "hypatia" then "Hypatia grid" else . end) as $lbl
  | "<!-- verdict-grid:\($r.lane) regenerated on every run -->\n"
  + "![\($lbl) \($r.state)](\(badge_url($lbl; $r.state)))\n\n"
  + "\($r.state | state_label) · commit `\($r.sha[0:12] | esc)` · "
  + (if $r.url != "" then "[run \($r.run | esc)](\($r.url))" else "local run" end)
  + (if $r.dirty then " · working tree modified" else "" end)
  # The scope is stated where the verdict is stated, not only in the footer.
  # A reader must not have to reach the last line to learn that "green" meant
  # "green for this change".
  + (if ($r.scope.mode // "whole-repo") == "delta"
       then " · scope: this change (\($r.scope.changed) file(s))"
       else " · scope: whole repository" end)
  # An exclusion the reader cannot see is indistinguishable from a clean scan.
  + (if (($r.scope.excluded_prefixes // []) | length) > 0
       then " · excludes \((($r.scope.excluded_prefixes) | map("`" + . + "`") | join(", ")))"
       else "" end) + "\n\n"
  # A row's gate status is stated in the table, not inferred from the prose:
  # "purple" from a reporter that cannot block a merge and "purple" from one
  # that can are different facts, and used to look identical.
  + (if (($r.advisory.rows // 0) > 0)
       then "Advisory: \($r.advisory.rows) row(s), worst \($r.advisory.state | state_label) (\($r.advisory.critical) critical, \($r.advisory.high) high in grid scope) — reported, never grading the change.\n"
       else "" end)
  + "\nUnique graded findings across gating and advisory rows: \($r.unique_total) (\($r.reported_total) reporter observations; \($r.uncorrelatable_total) without sufficient identity to corroborate). Row counts remain per reporter; unique totals do not change gating.\n"
  + (if $r.hypatia_alerts.available then
       "Raw Hypatia alert-derived observations: \($r.hypatia_alerts.total) (code-scanning, Dependabot and secret-scanning; some may also be in SARIF; not an extra total).\n"
     else "Raw Hypatia alert-derived inventory unavailable.\n" end)
  + (if ($r.hypatia_json_advisories.total // 0) > 0 then
       "JSON-only below-threshold advisories: \($r.hypatia_json_advisories.total) (not graded or uploaded).\n\n"
       + ([ $r.hypatia_json_advisories.findings[0:20][]
            | "- `\(advisory_rule_label | esc)` at `\(.file // "" | esc)\(if (.line // 0) > 0 then ":\(.line)" else "" end)` — \(.reason // "" | esc | .[0:280])\n" ] | add // "")
       + (if $r.hypatia_json_advisories.total > 20 then "- Additional advisories are in the raw JSON artifact.\n" else "" end)
     else "" end)
  + "\n| Reporter | Gate | Status | Critical | High | Medium | Minor | Since previous revision |\n|---|---|---|---:|---:|---:|---:|---|\n"
  + ([ $r.reporters[]
       | "| \(.title | esc) | \(if .gating then "gating" else "advisory" end) | \(.state | state_label) | \(.counts.critical) | \(.counts.high) | \(.counts.medium) | \(.counts.minor) | \(delta(prev; $r)) |\n" ] | add // "")
  + ([ $r.reporters[]
       | select(.status != "ran" or (.findings | length) > 0)
       | "\n<details>\n<summary>\(.title | esc): "
         + (if .status == "ran" then "\(.findings | length) finding(s)" else "\(.status | esc) — \(.reason | esc)" end)
         + "</summary>\n\n"
         + (if .status != "ran" then "- **\(.state | state_label)**: \(.reason | esc)\n" else "" end)
         + ([ .findings_graded | sort_by(.severity | rank) | reverse | .[0:20][]
              | "- **\(.severity | esc)** `\(.id | esc)` — \(if .file != "" then "`\(.file | esc)\(if .line > 0 then ":\(.line)" else "" end)` — " else "" end)\(.message | esc | .[0:280])\n" ] | add // "")
         + (if (.findings_graded | length) > 20 then "- \((.findings_graded | length) - 20) more graded finding(s); see the structured report in the artifact.\n" else "" end)
         # Standing and excluded findings are NAMED AND COUNTED, never dropped.
         # The whole design accepts that a quieter grid can become a blind one;
         # this line is the mitigation, and it is why the numbers are here even
         # when they are large and unflattering.
         + (if (.findings_standing | length) > 0
            then "- \(.findings_standing | length) further finding(s) in files this change does not touch: reported, not graded (\(.counts_standing.critical) critical, \(.counts_standing.high) high).\n"
            else "" end)
         + (if (.findings_excluded | length) > 0
            then "- \(.findings_excluded | length) finding(s) under a declared out-of-scope prefix: reported, never graded.\n"
            else "" end)
         + "\n</details>\n" ] | add // "")
  + "\nScope: static findings reported by each row's tool at the named commit."
  + (if ($r.scope.mode // "whole-repo") == "delta"
       then " The table grades only findings in files this change touches, so the colour answers \"does this change introduce anything?\", not \"what does the whole repository still carry?\". Standing findings are counted in each accordion and in report.json; the baseline filter remains the place where acknowledged debt is recorded."
       else " The table grades every finding in the repository, so the colour will not move on a change that touches nothing a scanner flags." end)
  + " The lane state is the worst GATING row; advisory rows are listed and counted but never set it. Purple, red, yellow and blue grade the worst GRADED finding present; orange is evidence missing, malformed or a scanner that did not run; grey is an explicit scope exclusion with its reason. No row is a security certification. report.json, badge.json and the raw findings are in the verdict-grid artifact on the linked run.\n"
  # `scope` is embedded so the NEXT revision can tell whether the two counts
  # answer the same question. A baseline written before scoping existed has no
  # scope key and is therefore incomparable -- deliberately, because comparing
  # a whole-repository count with a delta count would report a large fake
  # improvement on the first revision after the upgrade.
  + "\n<!-- verdict-grid-baseline:\({schema: $r.schema, profile: $r.profile, pr: $r.pr, sha: $r.sha,
        scope: {mode: $r.scope.mode},
        reporters: [$r.reporters[] | {id, status, gating, counts}]} | tojson | @base64) -->\n";

def badge: {schemaVersion: 1, label: (.lane | if . == "hypatia" then "Hypatia grid" else . end),
            message: (.state | word | gsub("_"; " ")), color: (.state | colour)};

# Entry point: $mode selects build (input: the assembled sources object),
# render (input: report.json; $previous: the prior baseline or null) or badge.
if $mode == "build" then build
elif $mode == "render" then render($previous)
elif $mode == "badge" then badge
else error("unknown mode \($mode)") end
