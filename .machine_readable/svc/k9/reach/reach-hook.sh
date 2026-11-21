#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# reach-hook.sh: Claude Code PreToolUse hook that fences a worker session to its
# K9 reach contract (COORDINATION-K9-SPEC "Reach", grammar v1.3.0).
#
# Input: the PreToolUse JSON on stdin. Output: nothing (normal permission flow) or a
# deny decision. It never returns allow, so it can only narrow what a session may do.
#
# Contract: reach.json, compiled from the reach section of this repository's
# coordination.k9 by `bun validate.js --compile-reach`. Fetched from
# raw.githubusercontent.com at the commit K9_REACH_PIN_SHA and accepted only if its
# sha256 is K9_REACH_JSON_SHA. Both pins, and every setting below, sit inline in the
# org's server-managed settings, which only an org Owner or Primary Owner can change.
# K9_REACH_ROLE names the role; it is set on the role's cloud environment.
#
# Enforces: validity dates, temporal window, breadth and depth, time to live (wall
# clock, idle and iterations), push rate, spawn depth and breadth, the never list,
# draft-only PRs. A worker may always message the hub.
#
# Admin ceilings cap every role value (effective value = the smaller):
#   K9_CEIL_WALL_MIN, K9_CEIL_TOOL_CALLS, K9_CEIL_REPOS, K9_CEIL_SPAWN_DEPTH.
#   K9_CEIL_PROFILE=tight|moderate|loose presets all four; an explicit K9_CEIL_* wins.
# Admin floors (switches only tighten; a role can be firmer, never looser):
#   K9_BREACH_MIN=deny|deny_and_report|deny_and_interrupt floors the role's on_breach.
#   K9_WINDOW_SCOPE_MIN=actions|all floors the role's window.scope.
# Fail closed (spec rule 19): an action with no effective wall-clock or tool-call
# limit is refused.
#
# Counters live in a state file in the worker's container, so they are
# tamper-evident, not tamper-proof; the hub keeps its own clock and counts.
# Test only: K9_REACH_FILE (local contract) and K9_REACH_NOW (fixed clock).
set -u
breach=deny_and_report
deny() { local r="$1"
  if [ "$breach" != deny ] && [ -n "${state_dir:-}" ]; then
    jq -cn --arg s "${sid:-?}" --arg t "${tool:-?}" --arg r "$1" --arg m "$breach" --arg w "$(date -u +%FT%TZ)" \
      '{at:$w,session:$s,tool:$t,reason:$r,mode:$m}' >>"$state_dir/breach.jsonl" 2>/dev/null
    r="$1. on_breach=$breach: report this to the hub now with send_message"
    [ "$breach" = deny_and_interrupt ] && r="$r; the hub will stop this session"
  fi
  jq -cn --arg r "K9 reach: $r" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
         [ -n "${log:-}" ] && printf '%s deny %s %s\n' "$(date -u +%FT%TZ)" "${tool:-?}" "$1" >>"$log"; exit 0; }
rank() { case "$1" in deny|actions) echo 0;; deny_and_report|all) echo 1;; deny_and_interrupt) echo 2;; *) echo -1;; esac; }
firmer() { [ "$(rank "${2:-}")" -gt "$(rank "$1")" ] && echo "$2" || echo "$1"; }
min() { local a=${1:-} b=${2:-}; [ -z "$a" ] && { echo "$b"; return; }; [ -z "$b" ] && { echo "$a"; return; }; [ "$a" -le "$b" ] && echo "$a" || echo "$b"; }
in=$(cat) || deny "no hook input"
jq -e . >/dev/null 2>&1 <<<"$in" || deny "bad hook input"
tool=$(jq -r '.tool_name // empty' <<<"$in"); sid=$(jq -r '.session_id // "unknown"' <<<"$in")
cwd=$(jq -r '.cwd // "."' <<<"$in")
[[ "$sid" =~ ^[A-Za-z0-9_-]+$ ]] || deny "bad session id"
# A worker may always report to the hub: after the contract expires, after its
# TTL runs out, and even when the state check below fails.
case "$tool" in mcp__claude-code-remote__send_message|SendMessage) exit 0;; esac
role=${K9_REACH_ROLE:-}; [ -n "$role" ] || deny "no K9_REACH_ROLE on this environment"
want_sha=${K9_REACH_JSON_SHA:-}; [ -n "$want_sha" ] || deny "no pinned contract hash"
state_dir=${K9_REACH_STATE:-$HOME/.k9-reach}; mkdir -p "$state_dir" || deny "no state dir"
log="$state_dir/$sid.log"
cache="$state_dir/reach-$want_sha.json"
# One temp file per call, so calls that run at the same time do not share it.
ctmp="$cache.$$.tmp"
if [ -n "${K9_REACH_FILE:-}" ]; then cp "$K9_REACH_FILE" "$ctmp" || deny "cannot read contract"
elif [ ! -s "$cache" ]; then
  [[ "${K9_REACH_PIN_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || deny "bad pin"
  curl -fsS --max-time 20 -o "$ctmp" "https://raw.githubusercontent.com/metadatastician/standards/$K9_REACH_PIN_SHA/.machine_readable/svc/k9/reach/reach.json" || deny "cannot fetch contract"
else cp "$cache" "$ctmp"; fi
[ "$(sha256sum <"$ctmp" | cut -d' ' -f1)" = "$want_sha" ] || { rm -f "$ctmp"; deny "contract hash mismatch"; }
mv "$ctmp" "$cache"
R=$(jq -c --arg r "$role" '.roles[$r] // empty' "$cache"); [ -n "$R" ] || deny "role $role not in contract"
q() { jq -r "$1 // empty" <<<"$R"; }
# Ceiling profile presets (admin). Explicit K9_CEIL_* values override the preset.
case "${K9_CEIL_PROFILE:-}" in
  tight)    p=(240 800 3 0);;
  moderate) p=(480 1500 5 0);;
  loose)    p=(1440 5000 10 1);;
  "")       p=("" "" "" "");;
  *)        deny "unknown K9_CEIL_PROFILE";;
esac
K9_CEIL_WALL_MIN=${K9_CEIL_WALL_MIN:-${p[0]}}; K9_CEIL_TOOL_CALLS=${K9_CEIL_TOOL_CALLS:-${p[1]}}
K9_CEIL_REPOS=${K9_CEIL_REPOS:-${p[2]}}; K9_CEIL_SPAWN_DEPTH=${K9_CEIL_SPAWN_DEPTH:-${p[3]}}
# Switches: role choice, raised to the admin floor. Unknown values fail closed to the firmest.
rb=$(q .on_breach); rb=${rb:-deny_and_report}; [ "$(rank "$rb")" -ge 0 ] || rb=deny_and_interrupt
breach=$(firmer "$rb" "${K9_BREACH_MIN:-}")
ws=$(q .window.scope); ws=${ws:-actions}; [ "$(rank "$ws")" -ge 0 ] || ws=all
wscope=$(firmer "$ws" "${K9_WINDOW_SCOPE_MIN:-}")
now=${K9_REACH_NOW:-$(date -u +%s)}; [ -n "${K9_REACH_FILE:-}" ] || now=$(date -u +%s)
today=$(date -u -d "@$now" +%F); dow=$(date -u -d "@$now" +%a | tr A-Z a-z); hour=$((10#$(date -u -d "@$now" +%H)))
# Validity dates.
vf=$(jq -r .valid_from "$cache"); ex=$(jq -r .expires "$cache")
[[ "$today" < "$vf" ]] && deny "contract not valid until $vf"
[[ "$today" > "$ex" ]] && deny "contract expired $ex"
# Session state with an HMAC integrity check. The key only shows that the
# hook wrote the file. A worker that can read the key could still forge it.
st="$state_dir/$sid.json"; st_sig="$st.sig"
# One call at a time per session: hold the lock from the read of the state
# to the write of its signature, so two calls cannot both use the last unit.
command -v flock >/dev/null || deny "flock is needed for the session state lock"
exec 9>"$st.lock" || deny "cannot open the session state lock"
flock -w 10 9 || deny "session state is busy"
[ -n "${K9_REACH_STATE_KEY:-}" ] || deny "state integrity key missing (K9_REACH_STATE_KEY)"
state_key=$K9_REACH_STATE_KEY; unset K9_REACH_STATE_KEY
sign_state() { openssl dgst -sha256 -hmac "$state_key" -r "$st" 2>/dev/null | awk '{print $1}'; }
if [ ! -s "$st" ]; then
  jq -cn --argjson t "$now" '{first:$t,last:$t,calls:0,attaches:0,pushes:0,prs:0,spawns:0,push_times:[],repos:[]}' >"$st" || deny "failed to initialize session state"
  sign_state >"$st_sig" || deny "failed to sign session state"
fi
[ -s "$st_sig" ] || deny "session state signature missing"
calc_sig=$(sign_state)
read -r file_sig <"$st_sig"
[ -n "$calc_sig" ] && [ "$calc_sig" = "$file_sig" ] || deny "session state integrity check failed"
S=$(cat "$st"); s() { jq -r "$1" <<<"$S"; }
# Temporal window. scope=actions: only actions; scope=all: every tool except reporting.
window_check() {
  if [ -n "$(q .window.days)" ]; then jq -e --arg d "$dow" '.window.days|index($d)' >/dev/null <<<"$R" || deny "outside window: nothing on $dow"; fi
  h0=$(q '.window.hours_utc[0]'); h1=$(q '.window.hours_utc[1]')
  [ -n "$h0" ] && { [ "$hour" -ge "$h0" ] && [ "$hour" -lt "$h1" ]; } || [ -z "$h0" ] || deny "outside window: hours ${h0}-${h1} UTC"
  jq -e --arg t "$today" '[.window.blackout[]? | select($t >= .[0] and $t <= .[1])] | length == 0' >/dev/null <<<"$R" || deny "blackout window covers $today"
}
[ "$wscope" = all ] && window_check
# TTL: wall clock, idle, iterations. Whichever runs out first ends the session's reach.
wall=$(min "$(q .ttl.wall_minutes)" "${K9_CEIL_WALL_MIN:-}"); idle=$(q .ttl.idle_minutes)
calls_max=$(min "$(q .ttl.max_tool_calls)" "${K9_CEIL_TOOL_CALLS:-}")
[ -n "$wall" ] && [ $(( (now - $(s .first)) / 60 )) -ge "$wall" ] && deny "TTL: wall clock $wall min used up"
[ -n "$idle" ] && [ $(( (now - $(s .last)) / 60 )) -ge "$idle" ] && deny "TTL: idle over $idle min; ask the hub to renew"
[ -n "$calls_max" ] && [ "$(s .calls)" -ge "$calls_max" ] && deny "TTL: $calls_max tool calls used up"
# Classify the call into an action (empty = read or local work).
action=""; target=""; files=""; dsts=""
# OWNER/REPO from a github.com remote URL; fails for any other host.
repo_of_url() { local u=$1
  [[ "$u" =~ ^(https://([^@/]+@)?github\.com/|git@github\.com:|ssh://git@github\.com/)(.+)$ ]] || return 1
  u=${BASH_REMATCH[3]%/}; echo "${u%.git}"; }
# The remote gh uses in a checkout: the one marked gh-resolved=base, else
# upstream, github, origin, in that order (as gh itself picks).
gh_remote() { local r n
  r=$(git -C "$1" config --get-regexp '^remote\..*\.gh-resolved$' 2>/dev/null | sed -nE 's/^remote\.(.*)\.gh-resolved base$/\1/p' | head -1)
  [ -n "$r" ] || for n in upstream github origin; do git -C "$1" remote get-url "$n" >/dev/null 2>&1 && { r=$n; break; }; done
  echo "${r:-origin}"; }
# Split a command line into simple commands. Quotes are not parsed, so a
# separator inside a quoted string also splits. That can only add pieces, and
# a piece that looks like a second action is refused, so it fails closed.
segments() { sed -E 's/(\|\||&&|[;|&()`{}]|\$\()/\n/g' <<<"$1"; }
# Classify one simple command: sets s_action, s_need and s_api.
classify_seg() { local x=$1 ep
  if [[ "$x" =~ (^|[[:space:]\"\'/])git([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+push([[:space:]]|$) ]]; then
    s_action=push_branch; s_need=write
  elif [[ "$x" =~ gh[[:space:]]+pr[[:space:]]+create ]]; then s_action=open_draft_pr; s_need=write
    [[ "$x" =~ --draft ]] || deny "PRs must be opened as drafts"
  elif [[ "$x" =~ gh[[:space:]]+pr[[:space:]]+(comment|review) ]]; then s_action=comment; s_need=read
  elif [[ "$x" =~ gh[[:space:]]+pr[[:space:]]+close ]]; then s_action=close_pr; s_need=write
  elif [[ "$x" =~ gh[[:space:]]+pr[[:space:]]+merge ]]; then s_action=merge; s_need=write
  elif [[ "$x" =~ (^|[[:space:]\"\'/])gh[[:space:]]+api([[:space:]]|$) ]]; then
    # gh api: reads pass. A write (a write method, or fields without -X GET)
    # must map to a reach action on a repos/OWNER/REPO path, or it is denied.
    if [[ "$x" =~ (-X|--method)[[:space:]=]*[\"\']?(POST|PUT|PATCH|DELETE|post|put|patch|delete) ]] ||
       { [[ "$x" =~ [[:space:]](-f|-F|--field|--raw-field|--input)([[:space:]=]) ]] &&
         ! [[ "$x" =~ (-X|--method)[[:space:]=]*[\"\']?(GET|get) ]]; }; then
      [[ "$x" =~ repos/([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)/([^[:space:]\'\"?]*) ]] ||
        deny "gh api write without a repos/OWNER/REPO path"
      s_api=${BASH_REMATCH[1]}; ep=${BASH_REMATCH[2]%/}
      case "$ep" in
        pulls/*/merge) s_action=merge; s_need=write ;;
        pulls) s_action=open_draft_pr; s_need=write
          [[ "$x" =~ -[Ff][[:space:]]+[\"\']?draft=true ]] || deny "PRs must be opened as drafts (draft=true)" ;;
        issues/*/comments|pulls/*/comments|pulls/*/comments/*/replies|pulls/*/reviews)
          s_action=comment; s_need=read ;;
        *) deny "gh api write to $ep is not a reach action" ;;
      esac
    fi
  elif [[ "$x" =~ (^|[[:space:]\"\'/])(curl|wget|http|xh)([[:space:]]|$) ]]; then
    deny "direct HTTP calls are not allowed; use git or gh"
  fi
  if [[ -n "$s_action" && "$x" =~ (^|[[:space:]])GH_REPO= ]]; then deny "GH_REPO is not allowed with a GitHub action; use --repo"; fi
}
# Resolve a git push: the repo it writes to, each destination branch, and the
# files it carries. Any form the hook cannot resolve is refused.
parse_push() { local x=${1//[\"\']/} tw n i=0 wd=$cwd remote="" rname="" url t r src dst src_c base up refs=()
  read -ra tw <<<"$x"; n=${#tw[@]}
  while [ $i -lt $n ] && [ "${tw[$i]}" != git ] && [[ "${tw[$i]}" != */git ]]; do i=$((i + 1)); done
  i=$((i + 1))
  while [ $i -lt $n ] && [ "${tw[$i]}" != push ]; do
    case "${tw[$i]}" in
      -C) i=$((i + 1)); t=${tw[$i]:-}; [[ "$t" == /* ]] && wd=$t || wd="$wd/$t" ;;
      *) deny "git option ${tw[$i]} before push is not allowed under reach" ;;
    esac; i=$((i + 1))
  done
  [ $i -lt $n ] || deny "cannot read the git push command"
  for ((i = i + 1; i < n; i++)); do t=${tw[$i]}
    [[ "$t" =~ ^[0-9]*[\<\>] ]] && break   # a redirect ends the arguments
    case "$t" in
      +*|:*|-f|--force|--force-*|-d|--delete|--prune|--mirror) deny "force push or branch delete is never granted" ;;
      -u|--set-upstream|-q|--quiet|-v|--verbose|--progress|--no-verify|--atomic|--porcelain|-n|--dry-run) ;;
      -o|--push-option) i=$((i + 1)) ;;
      --push-option=*) ;;
      -*) deny "git push option $t is not allowed under reach" ;;
      *) if [ -z "$remote" ]; then remote=$t; else refs+=("$t"); fi ;;
    esac
  done
  top=$(git -C "$wd" rev-parse --show-toplevel 2>/dev/null) || deny "push_branch outside a git checkout"
  br=$(git -C "$top" symbolic-ref -q --short HEAD)
  if [ -z "$remote" ]; then
    [ -n "$br" ] || deny "a push from a detached HEAD must name the remote and the branch"
    remote=$(git -C "$top" config "branch.$br.pushRemote" || git -C "$top" config remote.pushDefault ||
             git -C "$top" config "branch.$br.remote" || echo origin)
  fi
  if [[ "$remote" == *[:/]* ]]; then url=$remote
  else rname=$remote; url=$(git -C "$top" remote get-url --push "$remote" 2>/dev/null) || deny "unknown remote $remote"; fi
  target=$(repo_of_url "$url") || deny "push to a remote that is not on github.com"
  [ -z "$rname" ] || [ -z "$(git -C "$top" config --get-all "remote.$rname.push")" ] ||
    deny "remote.$rname.push is set; it can redirect a push, so it is not allowed under reach"
  if [ ${#refs[@]} -eq 0 ]; then
    [ "$(git -C "$top" config push.default || echo simple)" != matching ] || deny "push.default=matching is not allowed under reach"
    [ -n "$br" ] || deny "a push from a detached HEAD must name the branch"
    up=$(git -C "$top" rev-parse --abbrev-ref --symbolic-full-name '@{push}' 2>/dev/null)
    if [ -n "$up" ] && [ -n "$rname" ]; then refs=("$br:${up#"$rname"/}"); else refs=("$br:$br"); fi
  fi
  for r in "${refs[@]}"; do
    src=${r%%:*}; dst=${r#*:}
    if [[ "$r" != *:* ]]; then
      if [ "$src" = HEAD ]; then [ -n "$br" ] || deny "a push from a detached HEAD must name the branch"; dst=$br
      else git -C "$top" show-ref --verify -q "refs/heads/$src" || deny "push $src: name a local branch"; fi
    fi
    dst=${dst#refs/heads/}
    [[ -n "$dst" && "$dst" != refs/* ]] || deny "push to $dst is not a branch"
    src_c=$(git -C "$top" rev-parse --verify -q "$src^{commit}") || deny "cannot resolve $src"
    base=$(git -C "$top" merge-base "$src_c" "${rname:-origin}/HEAD" 2>/dev/null ||
           git -C "$top" rev-list --max-parents=0 "$src_c" | tail -1)
    files+="$(git -C "$top" diff --name-only "$base" "$src_c")"$'\n'
    dsts+="$dst"$'\n'
  done
}
case "$tool" in
  mcp__claude-code-remote__add_repo)
    action=attach; target="$(jq -r '.tool_input.owner + "/" + .tool_input.repo' <<<"$in")"
    [ "$(jq -r '.tool_input.access // "read"' <<<"$in")" = push ] && need=write || need=read ;;
  mcp__claude-code-remote__create_session) action=spawn ;;
  Edit|Write|NotebookEdit|MultiEdit)
    f=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$in")
    [ -n "$f" ] || deny "edit without a file path"
    [[ "$f" == /* ]] || f="$cwd/$f"
    # Resolve .. and symlinks in the parts that exist, so docs/../src counts as src.
    f=$(realpath -m -- "$f") || deny "cannot resolve $f"
    d=$(dirname "$f")
    while [ ! -d "$d" ] && [ "$d" != / ]; do d=$(dirname "$d"); done  # new folders
    if top=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null); then
      [[ "$f" == "$top"/* ]] || deny "edit target $f is outside its checkout"
      action=edit; need=write; files="${f#"$top"/}"
      target=$(repo_of_url "$(git -C "$top" remote get-url origin 2>/dev/null)")
    fi ;;
  Bash)
    c=$(jq -r '.tool_input.command // empty' <<<"$in"); api_target=; seg_c=
    # Check every simple command. At most one may be a GitHub action.
    while IFS= read -r seg; do
      s_action=; s_need=; s_api=
      classify_seg "$seg"
      if [ -n "$s_action" ]; then
        [ -z "$action" ] || deny "more than one GitHub action in one Bash call ($action, $s_action); run them one at a time"
        action=$s_action; need=$s_need; api_target=$s_api; seg_c=$seg
      fi
    done < <(segments "$c")
    if [ -n "$api_target" ]; then
      target=$api_target
    elif [ "$action" = push_branch ]; then
      parse_push "$seg_c"
    elif [ -n "$action" ]; then
      # gh pr: --repo/-R names the repo; otherwise gh's own pick in the cwd checkout.
      if [[ "$seg_c" =~ (^|[[:space:]])(--repo|-R)([[:space:]]+|=)[\"\']?([^[:space:]\"\']+) ]]; then
        t=${BASH_REMATCH[4]}
        target=$(repo_of_url "$t" || repo_of_url "https://$t" || echo "$t")
      else
        top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || deny "$action outside a git checkout"
        target=$(repo_of_url "$(git -C "$top" remote get-url "$(gh_remote "$top")" 2>/dev/null)")
      fi
    fi ;;
esac
if [ -n "$action" ]; then
  # Rule 19: fail closed when neither the role nor the admin sets a TTL.
  [ -n "$wall" ] || deny "no wall-clock TTL from the role or the admin ceilings (fail closed)"
  [ -n "$calls_max" ] || deny "no tool-call TTL from the role or the admin ceilings (fail closed)"
  [ "$wscope" = actions ] && window_check
  jq -e --arg a "$action" '(.never // []) | index($a) | not' >/dev/null <<<"$R" || deny "$action is never granted"
  if [ "$action" = spawn ]; then
    depth=$(min "$(q .extent.spawn_depth)" "${K9_CEIL_SPAWN_DEPTH:-}"); depth=${depth:-0}
    [ "${K9_REACH_DEPTH:-1}" -le "$depth" ] || deny "spawn depth: this role may not start sessions at depth ${K9_REACH_DEPTH:-1}"
    [ "$(s .spawns)" -lt "$(q .extent.spawn_breadth || echo 0)" ] || deny "spawn breadth used up"
  else
    [[ "$target" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || deny "cannot tell which repo ($target)"
    G=$(jq -c --arg r "$target" '.grants[] | select(.repo==$r)' <<<"$R")
    [ -n "$G" ] || deny "$target not in role $role"
    g() { jq -r "$1 // empty" <<<"$G"; }
    [ "$action" = edit ] || jq -e --arg a "$action" '.actions|index($a)' >/dev/null <<<"$G" || deny "$action not granted on $target"
    [ "${need:-read}" = read ] || [ "$(g .access)" = write ] || deny "write not granted on $target"
    # Breadth: distinct repos and orgs touched this session.
    if ! jq -e --arg r "$target" '.repos|index($r)' >/dev/null <<<"$S"; then
      mr=$(min "$(q .extent.max_repos)" "${K9_CEIL_REPOS:-}")
      [ -n "$mr" ] && [ "$(s '.repos|length')" -ge "$mr" ] && deny "breadth: max $mr repos per session"
      mo=$(q .extent.max_orgs); org=${target%%/*}
      [ -n "$mo" ] && [ "$(jq -r --arg o "$org" '[.repos[]|split("/")[0]]+[$o]|unique|length' <<<"$S")" -gt "$mo" ] && deny "breadth: max $mo orgs per session"
    fi
    # Depth: paths inside the repo, and files per push.
    if [ -n "$files" ] && [ -n "$(g '.paths[0]')" ]; then
      while IFS= read -r p; do [ -z "$p" ] && continue; ok=0
        while IFS= read -r glob; do [[ "$p" == $glob ]] && { ok=1; break; }; done < <(g '.paths[]')
        [ $ok = 1 ] || deny "depth: $p is outside the allowed paths on $target"
      done <<<"$files"
    fi
    if [ "$action" = push_branch ]; then
      bp=$(g .branch)
      if [ -n "$bp" ]; then
        while IFS= read -r d; do [ -z "$d" ] || [[ "$d" == $bp ]] || deny "branch $d does not match $bp"; done <<<"$dsts"
      fi
      files=$(grep . <<<"$files" | sort -u)
      mf=$(g .max_files_per_push); n=$(grep -c . <<<"$files")
      [ -n "$mf" ] && [ "$n" -gt "$mf" ] && deny "depth: $n files in push, max $mf"
      mp=$(q .ttl.max_pushes); [ -n "$mp" ] && [ "$(s .pushes)" -ge "$mp" ] && deny "TTL: $mp pushes used up"
      rh=$(q .rate.pushes_per_hour); [ -n "$rh" ] && [ "$(jq --argjson n "$now" '[.push_times[]|select(. > $n-3600)]|length' <<<"$S")" -ge "$rh" ] && deny "rate: $rh pushes per hour"
    fi
    if [ "$action" = attach ]; then ma=$(q .ttl.max_attaches); [ -n "$ma" ] && [ "$(s .attaches)" -ge "$ma" ] && deny "TTL: $ma attaches used up"; fi
    if [ "$action" = open_draft_pr ]; then mx=$(q .ttl.max_prs); [ -n "$mx" ] && [ "$(s .prs)" -ge "$mx" ] && deny "TTL: $mx PRs used up"; fi
  fi
fi
# Count the call (conservative: counted even if a later check refuses it).
jq -c --argjson n "$now" --arg a "$action" --arg t "${target:-}" '
  .calls+=1 | .last=$n
  | if $a=="attach" then .attaches+=1 else . end
  | if $a=="push_branch" then .pushes+=1 | .push_times+=[$n] else . end
  | if $a=="open_draft_pr" then .prs+=1 else . end
  | if $a=="spawn" then .spawns+=1 else . end
  | if $t!="" and $a!="spawn" and (.repos|index($t)|not) then .repos+=[$t] else . end' <<<"$S" >"$st.$$.tmp" &&
  mv "$st.$$.tmp" "$st" || deny "failed to write session state"
new_sig=$(sign_state) && [ -n "$new_sig" ] && printf '%s\n' "$new_sig" >"$st_sig.$$.tmp" &&
  mv "$st_sig.$$.tmp" "$st_sig" || deny "failed to sign session state"
[ -n "$action" ] && printf '%s ok %s %s %s\n' "$(date -u +%FT%TZ)" "$tool" "$action" "${target:-}" >>"$log"
exit 0
