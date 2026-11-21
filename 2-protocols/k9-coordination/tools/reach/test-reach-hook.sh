#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# test-reach-hook.sh: local tests for .machine_readable/svc/k9/reach/reach-hook.sh.
# Runs the hook against the compiled fixture contracts in ../validate/fixtures/reach/
# with a fixed clock and a throwaway git checkout. Needs bash, git, jq, openssl and flock.
# Exit 0 when every case behaves as expected, 1 otherwise.
set -u
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../../.." && pwd)
hook="$repo/.machine_readable/svc/k9/reach/reach-hook.sh"
full="$repo/2-protocols/k9-coordination/tools/validate/fixtures/reach/reach-full.json"
mini="$repo/2-protocols/k9-coordination/tools/validate/fixtures/reach/reach-minimal.json"
for t in git jq openssl flock; do command -v "$t" >/dev/null || { echo "needs $t"; exit 2; }; done
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
at() { date -u -d "$1" +%s; }
MON=$(at 2026-11-23T10:00:00Z)   # Monday, inside the window
SAT21=$(at 2026-11-21T10:00:00Z) # inside the minimal contract (no window)
pass=0; fail=0

# A checkout whose origin is the granted repo, on claude/x, one commit under docs/.
co="$work/rsr-template-repo"
git init -q -b main "$co"
git -C "$co" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m root
git -C "$co" remote add origin https://github.com/hyperpolymath/rsr-template-repo.git
git -C "$co" checkout -q -b claude/x
mkdir -p "$co/docs"; echo a >"$co/docs/a.adoc"
git -C "$co" add . && git -C "$co" -c user.name=t -c user.email=t@example.invalid commit -q -m docs
# The stand-in for the remote at push time: main at the root commit, no claude/x yet.
git clone -q --bare "$co" "$work/remote.git"; git -C "$work/remote.git" branch -q -D claude/x
# A second checkout on feature/y, and a third with 42 files under docs/.
cp -r "$co" "$work/feat"; git -C "$work/feat" checkout -q -b feature/y
cp -r "$co" "$work/big"
for i in $(seq 1 41); do echo "$i" >"$work/big/docs/f$i.adoc"; done
git -C "$work/big" add . && git -C "$work/big" -c user.name=t -c user.email=t@example.invalid commit -q -m big
# A checkout with a file outside the allowed paths.
cp -r "$co" "$work/src"; mkdir -p "$work/src/src"; echo x >"$work/src/src/x.rs"
git -C "$work/src" add . && git -C "$work/src" -c user.name=t -c user.email=t@example.invalid commit -q -m src

# run NAME EXPECT(pass|deny) NOW CONTRACT SID JSON [ENV=VALUE...]
# WHY=TEXT makes a deny case also check that the reason contains TEXT, and
# WHYNOT=TEXT that it does not. A hook
# that exits nonzero fails the case, whatever it printed.
# State persists per SID inside one test file run, so cases can build on each other.
run() {
  local name=$1 want=$2 now=$3 contract=$4 sid=$5 json=$6; shift 6
  local sha; sha=$(sha256sum <"$contract" | cut -d' ' -f1)
  local out rc; out=$(env -i PATH="$PATH" HOME="$work" K9_REACH_STATE_KEY="${KEY-test-state-key}" K9_REACH_ROLE="${ROLE:-deed-migrator}" \
    K9_REACH_JSON_SHA="${SHA:-$sha}" K9_REACH_FILE="$contract" K9_REACH_STATE="$work/state" K9_REACH_LS_REMOTE="${LSR:-$work/remote.git}" \
    K9_REACH_NOW="$now" "$@" bash "$hook" <<<"${json//SID/$sid}"); rc=$?
  local got=pass; [[ "$out" == *'"permissionDecision":"deny"'* ]] && got=deny
  [ "$rc" -eq 0 ] || got="exit $rc"
  [ "$got" = deny ] && [ -n "${WHY:-}" ] && [[ "$out" != *"$WHY"* ]] && got="deny for another reason"
  [ "$got" = deny ] && [ -n "${WHYNOT:-}" ] && [[ "$out" == *"$WHYNOT"* ]] && got="deny with uncut text"
  if [ "$got" = "$want" ]; then pass=$((pass + 1)); echo "ok   $name"
  else fail=$((fail + 1)); echo "FAIL $name: wanted $want, got $got: ${out:-no output}"; fi
}
j() { jq -cn --arg t "$1" --arg c "$2" --argjson i "$3" '{session_id:"SID",cwd:$c,tool_name:$t,tool_input:$i}'; }
attach() { j mcp__claude-code-remote__add_repo /tmp "{\"owner\":\"${1%%/*}\",\"repo\":\"${1#*/}\",\"access\":\"${2:-push}\"}"; }
bash_in() { j Bash "$1" "$(jq -cn --arg c "$2" '{command:$c}')"; }
edit() { j Edit /tmp "$(jq -cn --arg f "$1" '{file_path:$f}')"; }
READ=$(j Read /tmp '{"file_path":"/etc/hostname"}')
MSG=$(j mcp__claude-code-remote__send_message /tmp '{"message":"hi"}')
SPAWN=$(j mcp__claude-code-remote__create_session /tmp '{}')

echo "# grants and the never list"
run "attach a granted repo in the window" pass "$MON" "$full" a1 "$(attach hyperpolymath/rsr-template-repo)"
run "attach a repo not in the role" deny "$MON" "$full" a2 "$(attach evil/x read)"
run "read attach of the read-only grant" pass "$MON" "$full" a3 "$(attach metadatastician/standards read)"
run "push attach of the read-only grant" deny "$MON" "$full" a4 "$(attach metadatastician/standards push)"
run "push claude/x with docs/ only" pass "$MON" "$full" p1 "$(bash_in "$co" 'git push -u origin claude/x')"
run "push through git -C" pass "$MON" "$full" p2 "$(bash_in /tmp "git -C $co push origin claude/x")"
run "force push" deny "$MON" "$full" p3 "$(bash_in "$co" 'git push --force origin claude/x')"
run "force push, short flag" deny "$MON" "$full" p4 "$(bash_in "$co" 'git push -f origin claude/x')"
run "branch delete by :refspec" deny "$MON" "$full" p5 "$(bash_in "$co" 'git push origin :claude/x')"
run "push from feature/y" deny "$MON" "$full" p6 "$(bash_in "$work/feat" 'git push origin feature/y')"
run "push of 42 files, max 40" deny "$MON" "$full" p7 "$(bash_in "$work/big" 'git push origin claude/x')"
run "push with a file under src/" deny "$MON" "$full" p8 "$(bash_in "$work/src" 'git push origin claude/x')"
run "draft PR" pass "$MON" "$full" r1 "$(bash_in "$co" 'gh pr create --draft --title t --body b')"
run "PR without --draft" deny "$MON" "$full" r2 "$(bash_in "$co" 'gh pr create --title t --body b')"
run "merge" deny "$MON" "$full" r3 "$(bash_in "$co" 'gh pr merge 1')"
run "close PR (in never)" deny "$MON" "$full" r4 "$(bash_in "$co" 'gh pr close 1')"
run "comment" pass "$MON" "$full" r5 "$(bash_in "$co" 'gh pr comment 1 --body hi')"
run "edit under docs/" pass "$MON" "$full" e1 "$(edit "$co/docs/a.adoc")"
run "edit in a new docs/ folder" pass "$MON" "$full" e2 "$(edit "$co/docs/new/b.adoc")"
run "edit in a new src/ folder" deny "$MON" "$full" e3 "$(edit "$co/src/new/x.rs")"
run "scratch file outside any checkout" pass "$MON" "$full" e4 "$(edit "$work/scratch/n.txt")"
run "spawn at depth 0" deny "$MON" "$full" s1 "$SPAWN"

echo "# gh api and direct HTTP"
G=hyperpolymath/rsr-template-repo
run "gh api read" pass "$MON" "$full" g1 "$(bash_in /tmp "gh api repos/$G/pulls/1")"
run "gh api read with -X GET and -f" pass "$MON" "$full" g2 "$(bash_in /tmp "gh api -X GET repos/$G/pulls -f state=open")"
run "gh api merge" deny "$MON" "$full" g3 "$(bash_in /tmp "gh api -X PUT repos/$G/pulls/1/merge")"
run "gh api draft PR" pass "$MON" "$full" g4 "$(bash_in /tmp "gh api repos/$G/pulls -f title=t -f head=claude/x -f base=main -F draft=true")"
run "gh api PR without draft=true" deny "$MON" "$full" g5 "$(bash_in /tmp "gh api repos/$G/pulls -f title=t -f head=claude/x -f base=main")"
run "gh api comment" pass "$MON" "$full" g6 "$(bash_in /tmp "gh api repos/$G/issues/1/comments -f body=hi")"
run "gh api comment on an ungranted repo" deny "$MON" "$full" g7 "$(bash_in /tmp "gh api repos/evil/x/issues/1/comments -f body=hi")"
run "gh api delete a branch ref" deny "$MON" "$full" g8 "$(bash_in /tmp "gh api -X DELETE repos/$G/git/refs/heads/claude/x")"
run "gh api write with no repos path" deny "$MON" "$full" g9 "$(bash_in /tmp "gh api graphql -f query=x")"
run "gh api --method=PATCH settings" deny "$MON" "$full" g10 "$(bash_in /tmp "gh api --method=PATCH repos/$G -f visibility=public")"
run "curl to api.github.com" deny "$MON" "$full" g11 "$(bash_in /tmp "curl -X PUT https://api.github.com/repos/$G/pulls/1/merge")"
run "wget in a pipe to api.github.com" deny "$MON" "$full" g12 "$(bash_in /tmp "true | wget -qO- https://api.github.com/repos/$G")"
run "ordinary bash (build)" pass "$MON" "$full" g13 "$(bash_in "$co" 'ls -la && echo done')"

echo "# every simple command, the selected repo, and the pushed refs"
git -C "$work/src" branch claude/clean HEAD~1
ln -s ../src "$co/docs/link"
run "push then merge in one call" deny "$MON" "$full" m1 "$(bash_in "$co" 'git push origin claude/x; gh pr merge 1')"
run "comment then curl in one call" deny "$MON" "$full" m2 "$(bash_in "$co" 'gh pr comment 1 --body hi && curl https://api.github.com/x')"
run "build then push in one call" pass "$MON" "$full" m3 "$(bash_in "$co" 'ls && git push origin claude/x')"
WHY="evil/x not in role" run "gh pr comment --repo evil/x" deny "$MON" "$full" m4 "$(bash_in "$co" 'gh pr comment 1 --repo evil/x --body hi')"
run "gh pr comment -R on the granted repo" pass "$MON" "$full" m5 "$(bash_in "$co" "gh pr comment 1 -R $G --body hi")"
run "GH_REPO with a gh action" deny "$MON" "$full" m6 "$(bash_in "$co" 'GH_REPO=evil/x gh pr comment 1 --body hi')"
WHY="branch main does not match" run "push HEAD:main" deny "$MON" "$full" m7 "$(bash_in "$co" 'git push origin HEAD:main')"
run "push claude/x:main" deny "$MON" "$full" m8 "$(bash_in "$co" 'git push origin claude/x:main')"
run "push the local main" deny "$MON" "$full" m9 "$(bash_in "$co" 'git push origin main')"
run "push to an ungranted URL" deny "$MON" "$full" m10 "$(bash_in "$co" 'git push https://github.com/evil/x claude/x')"
run "push to a look-alike host" deny "$MON" "$full" m11 "$(bash_in "$co" 'git push https://evil.example/github.com/hyperpolymath/rsr-template-repo claude/x')"
run "git -c before push" deny "$MON" "$full" m12 "$(bash_in "$co" 'git -c remote.origin.pushurl=https://github.com/evil/x push origin claude/x')"
run "push inside bash -c" deny "$MON" "$full" m13 "$(bash_in "$co" "bash -c \"git push origin HEAD:main\"")"
run "push with no arguments" pass "$MON" "$full" m14 "$(bash_in "$co" 'git push')"
run "push a docs-only branch from another checkout state" pass "$MON" "$full" m15 "$(bash_in "$work/src" 'git push origin claude/clean')"
WHY="src/x.rs is outside" run "push HEAD (with src/) to claude/clean" deny "$MON" "$full" m16 "$(bash_in "$work/src" 'git push origin HEAD:claude/clean')"
run "push a tag" deny "$MON" "$full" m17 "$(bash_in "$co" 'git push origin refs/tags/v1')"
WHY="src/x.rs is outside" run "edit docs/../src/x.rs" deny "$MON" "$full" m18 "$(edit "$co/docs/../src/x.rs")"
run "edit through a symlink into src/" deny "$MON" "$full" m19 "$(edit "$co/docs/link/x.rs")"
run "push with a redirect" pass "$MON" "$full" m20 "$(bash_in "$co" 'git push origin claude/x 2>&1')"

echo "# second review pass"
# A file under src/ added in one commit and deleted in the next.
cp -r "$co" "$work/gone"; rm -f "$work/gone/docs/link"; mkdir -p "$work/gone/src"; echo x >"$work/gone/src/x.rs"
git -C "$work/gone" add -A && git -C "$work/gone" -c user.name=t -c user.email=t@example.invalid commit -q -m add
git -C "$work/gone" rm -q src/x.rs && git -C "$work/gone" -c user.name=t -c user.email=t@example.invalid commit -q -m del
# A second push URL on origin, and a URL rewrite.
cp -r "$co" "$work/two"
git -C "$work/two" config --add remote.origin.pushurl https://github.com/hyperpolymath/rsr-template-repo.git
git -C "$work/two" config --add remote.origin.pushurl https://github.com/evil/x.git
cp -r "$co" "$work/iof"; git -C "$work/iof" config url.https://github.com/evil/.insteadOf https://github.com/hyperpolymath/
# A long file name under src/, for the clipped deny reason.
long=$(printf 'a%.0s' $(seq 1 150))
cp -r "$co" "$work/long"; rm -f "$work/long/docs/link"; mkdir -p "$work/long/src"; echo x >"$work/long/src/$long.rs"
git -C "$work/long" add -A && git -C "$work/long" -c user.name=t -c user.email=t@example.invalid commit -q -m long
run "export GH_REPO, then a gh action" deny "$MON" "$full" n1 "$(bash_in "$co" 'export GH_REPO=evil/x; gh pr comment 1 --body hi')"
WHY="more than one GitHub action" run "push then a quoted 'merge'" deny "$MON" "$full" n2 "$(bash_in "$co" "git push origin claude/x; gh pr 'merge' 1")"
run "quoted \$'merge' alone" deny "$MON" "$full" n3 "$(bash_in "$co" "gh pr \$'merge' 1")"
run "backslash m\\erge" deny "$MON" "$full" n4 "$(bash_in "$co" 'gh pr m\erge 1')"
run "quoted 'push' to HEAD:main" deny "$MON" "$full" n5 "$(bash_in "$co" "git 'push' origin HEAD:main")"
WHY="more than one repo" run "origin with a second, ungranted push URL" deny "$MON" "$full" n6 "$(bash_in "$work/two" 'git push origin claude/x')"
WHY="insteadOf" run "push to a URL under url.insteadOf" deny "$MON" "$full" n7 "$(bash_in "$work/iof" 'git push https://github.com/hyperpolymath/rsr-template-repo claude/x')"
WHY="src/x.rs is outside" run "src/ file added then deleted" deny "$MON" "$full" n8 "$(bash_in "$work/gone" 'git push origin claude/x')"
WHYNOT="$long" run "long path cut in the deny reason" deny "$MON" "$full" n9 "$(bash_in "$work/long" 'git push origin claude/x')"
run "ANSI-C escape \$'mer\\x67e' after a push" deny "$MON" "$full" n11 "$(bash_in "$co" "git push origin claude/x; gh pr \$'mer\\x67e' 1")"
# A remote whose main moved on (a commit under src/) while its claude/x stayed at the root.
git clone -q --bare "$work/src" "$work/behind.git"; git -C "$work/behind.git" branch -q -f main claude/x
git -C "$work/behind.git" branch -q -f claude/x "$(git -C "$co" rev-list --max-parents=0 HEAD)"
WHY="src/x.rs is outside" LSR="$work/behind.git" run "destination behind the remote HEAD" deny "$MON" "$full" n12 "$(bash_in "$work/src" 'git push origin HEAD:claude/x')"
# A remote claude/x at a commit this checkout has never fetched.
git clone -q --bare "$co" "$work/ahead.git"; git -C "$work/ahead.git" -c user.name=t -c user.email=t@example.invalid \
  commit-tree -p claude/x -m other "$(git -C "$work/ahead.git" rev-parse 'claude/x^{tree}')" >"$work/ahead.sha"
git -C "$work/ahead.git" branch -q -f claude/x "$(cat "$work/ahead.sha")"
WHY="fetch first" LSR="$work/ahead.git" run "remote tip not fetched" deny "$MON" "$full" n13 "$(bash_in "$co" 'git push origin claude/x')"
WHY="cannot read" LSR="$work/nowhere.git" run "remote cannot be read" deny "$MON" "$full" n14 "$(bash_in "$co" 'git push origin claude/x')"
qv="$repo/2-protocols/k9-coordination/tools/validate/fixtures/reach/reach-quoted-version.json"
ROLE=constructor run "role named constructor keeps its grant" pass "$SAT21" "$qv" n10 "$(attach hyperpolymath/k9-ecosystem read)" K9_CEIL_PROFILE=moderate

echo "# temporal window and validity"
run "attach on a Saturday" deny "$(at 2026-11-28T10:00:00Z)" "$full" w1 "$(attach hyperpolymath/rsr-template-repo)"
run "read on a Saturday (scope actions)" pass "$(at 2026-11-28T10:00:00Z)" "$full" w2 "$READ"
run "read on a Saturday, admin scope all" deny "$(at 2026-11-28T10:00:00Z)" "$full" w3 "$READ" K9_WINDOW_SCOPE_MIN=all
run "hub message on a Saturday, scope all" pass "$(at 2026-11-28T10:00:00Z)" "$full" w4 "$MSG" K9_WINDOW_SCOPE_MIN=all
run "attach at 06:59 UTC" deny "$(at 2026-11-23T06:59:00Z)" "$full" w5 "$(attach hyperpolymath/rsr-template-repo)"
run "attach at 21:00 UTC" deny "$(at 2026-11-23T21:00:00Z)" "$full" w6 "$(attach hyperpolymath/rsr-template-repo)"
run "attach on a blackout day" deny "$(at 2026-12-01T10:00:00Z)" "$full" w7 "$(attach hyperpolymath/rsr-template-repo)"
run "read before valid_from" deny "$(at 2026-11-20T10:00:00Z)" "$full" w8 "$READ"
run "read after expires" deny "$(at 2026-12-22T10:00:00Z)" "$full" w9 "$READ"
run "hub message after expires" pass "$(at 2026-12-22T10:00:00Z)" "$full" w10 "$MSG"

echo "# time to live, breadth, rate"
T0=$(at 2026-11-24T08:00:00Z)
run "first call starts the clock" pass "$T0" "$full" t1 "$READ"
for m in 50 100 150 200; do run "keep-alive read at $m min" pass "$((T0 + m * 60))" "$full" t1 "$READ"; done
run "attach at 3 h 59" pass "$((T0 + 239 * 60))" "$full" t1 "$(attach hyperpolymath/rsr-template-repo)"
run "attach at 4 h 00 (wall 240)" deny "$((T0 + 240 * 60))" "$full" t1 "$(attach hyperpolymath/rsr-template-repo)"
run "hub message after TTL" pass "$((T0 + 300 * 60))" "$full" t1 "$MSG"
run "first call (idle test)" pass "$T0" "$full" t2 "$READ"
run "call after 61 min idle" deny "$((T0 + 61 * 60))" "$full" t2 "$READ"
run "first call (admin wall 30)" pass "$T0" "$full" t1c "$READ" K9_CEIL_WALL_MIN=30
run "call at 31 min, admin wall 30 below role 240" deny "$((T0 + 31 * 60))" "$full" t1c "$READ" K9_CEIL_WALL_MIN=30
for k in 1 2 3; do run "attach $k of 3" pass "$T0" "$full" t3 "$(attach hyperpolymath/rsr-template-repo)"; done
run "attach 4 of 3" deny "$T0" "$full" t3 "$(attach hyperpolymath/rsr-template-repo)"
for k in 1 2 3 4 5 6; do run "push $k in the hour" pass "$((T0 + k * 60))" "$full" t4 "$(bash_in "$co" 'git push origin claude/x')"; done
run "push 7 in the hour (rate 6)" deny "$((T0 + 7 * 60))" "$full" t4 "$(bash_in "$co" 'git push origin claude/x')"
run "attach repo 1 under admin ceiling of 1 repo" pass "$T0" "$full" t5 "$(attach hyperpolymath/rsr-template-repo)" K9_CEIL_REPOS=1
run "attach repo 2 under admin ceiling of 1 repo" deny "$T0" "$full" t5 "$(attach metadatastician/standards read)" K9_CEIL_REPOS=1
mkdir -p "$work/state"; jq -cn --argjson t "$T0" '{first:$t,last:$t,calls:800,attaches:0,pushes:0,prs:0,spawns:0,push_times:[],repos:[]}' >"$work/state/t6.json"
openssl dgst -sha256 -hmac test-state-key -r "$work/state/t6.json" | awk '{print $1}' >"$work/state/t6.json.sig"
WHY="800 tool calls used up" run "call 801 (max 800)" deny "$T0" "$full" t6 "$READ"

echo "# switches"
run "breach mode reported in the reason" deny "$MON" "$full" x1 "$(attach evil/x read)"
grep -q '"mode":"deny_and_report"' "$work/state/breach.jsonl" && { pass=$((pass + 1)); echo "ok   breach line written"; } || { fail=$((fail + 1)); echo "FAIL breach line written"; }
run "profile tight" pass "$MON" "$full" x2 "$(attach hyperpolymath/rsr-template-repo)" K9_CEIL_PROFILE=tight
run "unknown profile" deny "$MON" "$full" x3 "$READ" K9_CEIL_PROFILE=wild
ROLE=auditor run "role with no TTL and no ceiling (fail closed)" deny "$SAT21" "$mini" x4 "$(attach hyperpolymath/k9-ecosystem read)"
ROLE=auditor run "role with no TTL, profile moderate" pass "$SAT21" "$mini" x5 "$(attach hyperpolymath/k9-ecosystem read)" K9_CEIL_PROFILE=moderate

echo "# contract and input"
ROLE=nobody run "unknown role" deny "$MON" "$full" c1 "$READ"
SHA=0000 run "tampered contract (hash mismatch)" deny "$MON" "$full" c2 "$READ"
run "malformed input" deny "$MON" "$full" c3 "not json"

# state integrity (HMAC over the session state file)
KEY= run "state key missing" deny "$MON" "$full" k1 "$READ"
run "first call signs the state" pass "$MON" "$full" k2 "$READ"
run "second call after a signed write" pass "$MON" "$full" k2 "$READ"
jq -c ".calls=0" "$work/state/k2.json" >"$work/state/k2.t" && mv "$work/state/k2.t" "$work/state/k2.json"
run "edited state file" deny "$MON" "$full" k2 "$READ"
run "hub message with an edited state file" pass "$MON" "$full" k2 "$MSG"

echo "local hook tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
