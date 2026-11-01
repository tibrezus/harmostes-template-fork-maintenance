#!/usr/bin/env bash
# =============================================================================
# sync-fork.sh — Universal fork sync script (MERGE model, phase-addressable)
# =============================================================================
# Merges the upstream release branch INTO the fork's release branch (off a sync
# branch → PR), runs post-merge hooks, verifies patches + divergence integrity,
# validates, and opens a host-routed PR. Merge model: the fork's
# release branch carries our customizations as immutable commits; each sync
# appends an upstream merge, so custom SHAs never change (append-only, bisectable,
# no replay/accumulation). Conflicts are localized 3-way regions — the ideal
# substrate for the LLM conflict-resolver (resolve-conflict.sh). Parameterized by
# a fork definition YAML.
#
# PHASE MODE (graph-native fork-maintenance workflows): each phase is one harmostes
# graph node (plugin fork-sync <fork> <phase>). Phases share the clone via
# HARMOSTES_WORKDIR/fork-<name> and pass state through .git/harmostes-state.env.
# Phased mode merges the LOCAL MIRROR BRANCH (fork.mirror_branch, kept current by
# the upstream-mirror action + push webhook) — it never fetches the upstream host.
# Result semantics (PluginResult JSON on the last stdout line):
#   merge     exit 0 {changed:false}            upstream unchanged (no-op run)
#             exit 0 {changed:true}             merged cleanly
#             exit 2                            conflict (resolver delegated, async)
#   hook      exit 0/1                          post-merge codegen
#   gates     exit 0 {changed:true}             divergence + patches intact
#             exit 1                            lost feature → needs-fix PR pushed
#   validate  exit 0/1                          the fork's declared validation suite
#   pr        exit 0 {changed:true|false}       false = PR left for review (no auto-merge)
#   tag       exit 0 {changed:true|false}       machine-cut v<upstream>-rezus.<N+1>
#
# ALL MODE (default — legacy single-shot for forks not yet graph-native):
# exit codes: 0 = up to date or PR opened (auto-merged if auto.merge);
#             2 = merge conflict (needs resolution PR created); 3 = push failure.
#
# Usage: sync-fork.sh <fork-name> [merge|hook|gates|validate|pr|tag|all]
# Requires: git, gh (GitHub CLI), yq, bash
# Environment: GITHUB_TOKEN (PAT with repo + workflow scope on the forks)
# =============================================================================

set -euo pipefail

FORK_NAME="${1:?Usage: sync-fork.sh <fork-name> [merge|hook|gates|validate|pr|tag|all]}"
PHASE="${2:-all}"
case "$PHASE" in
  merge|hook|gates|validate|pr|tag) PHASED=1 ;;
  all) PHASED=0 ;;
  *) echo "ERROR: unknown phase '$PHASE'" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# MAINT_DIR is the parent of scripts/ — either platform/harmostes/fork-maintenance/ in the
# repo, or /workspace/ in the worker (ConfigMap mount).
MAINT_DIR="$(dirname "$SCRIPT_DIR")"
# HARMOSTES_FORK_DEF: def-file override. The group dispatcher (below) synthesizes
# defs for org members that have no file of their own (group defaults + discovery)
# and hands them to the per-member child process through this env var — the
# fork-maintenance-defs mount is a read-only ConfigMap, so synthesized defs can
# never be written where real defs live. Real defs always win over synthesis.
DEF_FILE="${HARMOSTES_FORK_DEF:-$MAINT_DIR/forks/${FORK_NAME}.yaml}"

if [ ! -f "$DEF_FILE" ]; then
  echo "ERROR: fork definition not found: $DEF_FILE" >&2
  exit 1
fi

echo "=== [$PHASE] fork: $FORK_NAME ==="

# Parse YAML definition into shell variables
read_yaml() { yq -r "$1" "$DEF_FILE"; }

# Mode dispatch: merge (default, whole-repo forks) vs mapping (the forgejo
# self-sync — sync.yml's mapping-table walk in the plugin). Mapping machinery
# dispatches at the END of this script; merge-mode code below is unreachable
# for mapping defs. (subtree mode retired: no def ever shipped with it —
# vendored-tree forks are served by merge mode; history holds the old file.)
MODE="$(read_yaml '.mode // "merge"' 2>/dev/null || echo merge)"
case "$MODE" in
  merge|mapping) ;;
  subtree) echo "ERROR: mode 'subtree' retired from the payload — use merge mode" >&2; exit 1 ;;
  *) echo "ERROR: unknown mode '$MODE' for fork '$FORK_NAME'" >&2; exit 1 ;;
esac

# Mapping-table defs are SELF-HOSTED (sync.yml in the fork repo walks the
# rows) unless they opt into the plugin transport (mode: mapping — #97).
if [ "$(read_yaml '.mappings | length' 2>/dev/null || echo 0)" != "0" ] && [ "$MODE" != "mapping" ]; then
  echo "fork ${FORK_NAME} is self-hosted (mapping table; transport declared per row)"
  echo "sync runs in the fork repo: .github/workflows/sync.yml — nothing to do here"
  exit 0
fi

# Per-member child invocation. Test seam: HARMOSTES_SYNC_CHILD overrides the
# command (the group-defs suite stubs members to assert discovery, exclusion,
# composition, and outcome aggregation without cloning anything).
run_group_member() {
  local member="$1" phase="$2" def_file="$3"
  if [ -n "${HARMOSTES_SYNC_CHILD:-}" ]; then
    # test seam: the %MEMBER% stub runs with the SAME env contract as the
    # real child (HARMOSTES_FORK_DEF carries the resolved def).
    HARMOSTES_FORK_DEF="$def_file" eval "${HARMOSTES_SYNC_CHILD//%MEMBER%/$member}"
  else
    HARMOSTES_FORK_DEF="$def_file" bash "$SCRIPT_DIR/sync-fork.sh" "$member" "$phase"
  fi
}

# Member-def resolution: own def file > synthesis (defaults + discovery).
# Echoes the def file path; writes synthesized defs to a temp file the child
# reads via HARMOSTES_FORK_DEF. Echoes "SKIP:<reason>" when undef'd+unmapped.
resolve_member_def() {
  local member="$1" org="$2"
  local own="$MAINT_DIR/forks/${member}.yaml"
  if [ -f "$own" ]; then
    echo "$own"
    return 0
  fi
  # Discover the upstream: explicit upstream_map entry first (detached forks
  # have a null parent — the API cannot answer), then the host's fork parent.
  local u_url u_branch
  u_url=$(read_yaml ".group.upstream_map.\"${member}\".url // .group.upstream_map.${member}.url // \"\"" 2>/dev/null || echo "")
  u_branch=$(read_yaml ".group.upstream_map.\"${member}\".branch // .group.upstream_map.${member}.branch // \"\"" 2>/dev/null || echo "")
  if [ -z "$u_url" ]; then
    local parent
    parent=$(host_repo_parent "$org/$member") || parent=""   # "<url> <default-branch>" or empty
    if [ -n "$parent" ]; then
      u_url=$(printf '%s' "$parent" | awk '{print $1}')
      u_branch=$(printf '%s' "$parent" | awk '{print $2}')
    fi
  fi
  if [ -z "$u_url" ] || [ -z "$u_branch" ]; then
    echo "SKIP:no upstream — no member def, no upstream_map entry, host parent detached/absent"
    return 1
  fi
  # Compose the def in ONE python pass (the worker image ships pyyaml):
  # discovery facts + upstream + group defaults, with the fork block merged
  # (defaults' fork.url/default_branch never shadow the synthesized ones —
  # a duplicate YAML key would silently drop them to the last writer).
  # NOTE: resolve_member_def runs under command substitution — the synthesis
  # must write the FILE, never stdout (stdout IS the return channel: the
  # def path, or SKIP:<reason>).
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/fork-def-${member}.XXXXXX.yaml")
  SYNTH_OUT="$tmp" FORK_NAME="$FORK_NAME" MEMBER="$member" GROUP_FORK_BASE="$(group_fork_base)" ORG="$org" \
    UPSTREAM_URL="$u_url" UPSTREAM_BRANCH="$u_branch" DEF_FILE="$DEF_FILE" \
    python3 <<'PYEOF' || return 1
import os, sys, yaml
with open(os.environ["DEF_FILE"]) as f:
    d = yaml.safe_load(f) or {}
defaults = d.get("defaults") or {}
fork_defaults = defaults.pop("fork", {}) or {}
fork_defaults["url"] = f"{os.environ['GROUP_FORK_BASE']}/{os.environ['ORG']}/{os.environ['MEMBER']}"
fork_defaults["default_branch"] = f"rezus/{os.environ['UPSTREAM_BRANCH']}"
out = {
    "name": os.environ["MEMBER"],
    "upstream": {"url": os.environ["UPSTREAM_URL"], "branch": os.environ["UPSTREAM_BRANCH"]},
    "fork": fork_defaults,
}
for key in ("versioning", "auto", "validation"):
    if key in defaults:
        out[key] = defaults[key]
with open(os.environ["SYNTH_OUT"], "w") as f:
    f.write(
        f"# SYNTHESIZED by the group dispatcher (group '{os.environ['FORK_NAME']}') — do not edit;\n"
        f"# add forks/{os.environ['MEMBER']}.yaml to take over this member with a real def.\n"
    )
    f.write(yaml.safe_dump(out, default_flow_style=False, sort_keys=True))
PYEOF
  echo "$tmp"
}

# The base URL for member fork repos (scheme + host), derived from
# group.fork_base (explicit) or the platform default.
group_fork_base() {
  local b
  b=$(read_yaml '.group.fork_base // ""' 2>/dev/null || echo "")
  case "${b:-x}" in
    x) case "$(read_yaml '.group.platform // "github"')" in forgejo) echo "https://git.rezus.cloud" ;; *) echo "https://github.com" ;; esac ;;
    *) echo "$b" ;;
  esac
}

run_group() {
  local phase="${1:-all}"
  local org platform
  org=$(read_yaml '.group.org' 2>/dev/null || true)
  platform=$(read_yaml '.group.platform // "github"')
  if [ -z "$org" ]; then
    echo "ERROR: group def '$FORK_NAME' requires group.org" >&2
    exit 1
  fi
  # Forgejo enumeration needs the REST base (host_setup sets it per-fork; the
  # group dispatcher sets it from the group block).
  if [ "$platform" = "forgejo" ]; then
    FORGEJO_API=$(read_yaml '.group.api_url // .fork.api_url // ""')
    [ -n "$FORGEJO_API" ] || { echo "ERROR: forgejo group def requires group.api_url" >&2; exit 1; }
    export FORGEJO_API
  fi

  local discovered include exclude
  mapfile -t discovered < <(host_list_org_forks "$org" | sort -u)
  include=$(read_yaml '.group.include // []' 2>/dev/null | sed 's/[][]//g' | tr -d '"' | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' || true)
  exclude=$(read_yaml '.group.exclude // []' 2>/dev/null | sed 's/[][]//g' | tr -d '"' | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' || true)

  echo "=== [group] $FORK_NAME (org=$org, platform=$platform, phase=$phase) ==="
  if [ "${#discovered[@]}" -eq 0 ]; then
    echo "ERROR: no fork repos discovered in org '$org' — check the token/platform" >&2
    exit 1
  fi
  echo "discovered (${#discovered[@]}): ${discovered[*]}"

  local -a maintain=() excluded=() missing=()
  local m
  if [ -n "$include" ]; then
    [ -n "$exclude" ] && { echo "ERROR: group.include and group.exclude are mutually exclusive" >&2; exit 1; }
    for m in $include; do
      if printf '%s\n' "${discovered[@]}" | grep -qxF "$m"; then maintain+=("$m"); else missing+=("$m"); fi
    done
    [ "${#missing[@]}" -gt 0 ] && echo "WARNING: include entries not discovered: ${missing[*]}" >&2
    echo "included (def): $(printf '%s ' $include)"
  else
    for m in "${discovered[@]}"; do
      if printf '%s\n' $exclude | grep -qxF "$m"; then excluded+=("$m"); else maintain+=("$m"); fi
    done
    [ "${#excluded[@]}" -gt 0 ] && echo "excluded (def): ${excluded[*]}"
  fi
  if [ "${#maintain[@]}" -eq 0 ]; then
    echo "ERROR: no members to maintain after filtering" >&2
    exit 1
  fi
  echo "maintaining (${#maintain[@]}): ${maintain[*]}"

  local -a members_json=()
  local worst=0 changed_any=false n_ok=0 n_conflict=0 n_pushfail=0 n_failed=0 n_skipped=0
  for m in "${maintain[@]}"; do
    local def_file outcome="failed" detail=""
    def_file=$(resolve_member_def "$m" "$org") || {
      detail="${def_file#SKIP:}"   # resolve_member_def echoes the skip reason
      echo "── member $m: SKIPPED ($detail)"
      members_json+=("{\"name\":\"$m\",\"outcome\":\"skipped\",\"detail\":\"$detail\"}")
      n_skipped=$((n_skipped+1))
      continue
    }
    local out rc=0
    # `|| rc=$?` — a failing child must NOT trip set -e (a plain assignment
    # from a failing command substitution exits the whole run): per-member
    # isolation IS the contract — capture the rc, keep going.
    out=$(run_group_member "$m" "$phase" "$def_file" 2>&1) || rc=$?
    printf '%s\n' "$out" | sed 's/^/    /'
    case "$rc" in
      0)
        if grep -q "Already up to date" <<<"$out"; then
          outcome="no-op"; n_ok=$((n_ok+1))
        else
          outcome="changed"; changed_any=true; n_ok=$((n_ok+1))
        fi
        ;;
      2) outcome="conflict";   n_conflict=$((n_conflict+1)); [ "$worst" -lt 2 ] && worst=2 ;;
      3) outcome="push-failed"; n_pushfail=$((n_pushfail+1)); [ "$worst" -lt 3 ] && worst=3 ;;
      *) outcome="failed";     n_failed=$((n_failed+1)) ;;
    esac
    echo "── member $m: ${outcome^^}"
    members_json+=("{\"name\":\"$m\",\"outcome\":\"$outcome\"}")
  done

  # ALL members that RAN hard-failed → the group is red (1); skips don't
  # rescue a dead group (a skipped member is loud config debt, not health).
  # Otherwise the worst member outcome surfaces (2 conflict → the resolver
  # handles it async; 3 push failure) while the rest still landed.
  local exit_rc=0
  if [ "$n_failed" -gt 0 ] && [ $((n_ok + n_conflict + n_pushfail)) -eq 0 ]; then
    exit_rc=1
  else
    exit_rc=$worst
  fi

  echo ""
  echo "=== GROUP SUMMARY: $FORK_NAME — changed=$changed_any members=${#maintain[@]} ok=$n_ok conflict=$n_conflict push-fail=$n_pushfail failed=$n_failed skipped=$n_skipped ==="
  local msg
  msg="group $FORK_NAME: ${#maintain[@]} members — changed=$changed_any ok=$n_ok conflict=$n_conflict push-failed=$n_pushfail failed=$n_failed skipped=$n_skipped"
  printf '{"changed":%s,"artifact":"fork-sync-%s","event":{"phase":"%s"},"message":"%s","members":[%s]}\n' \
    "$changed_any" "$FORK_NAME" "$phase" "$(printf '%s' "$msg" | sed 's/"/\\"/g')" "$(IFS=,; echo "${members_json[*]}")"
  exit "$exit_rc"
}

# ── GROUP MODE (kind: group — maintain an org/group of forks) ────────────────
# A group def declares DISCOVERY + DEFAULTS, not a single fork:
#
#   name: rezusforks
#   kind: group
#   group:
#     platform: github            # github | forgejo — where the org lives
#     org: rezusforks             # the org whose FORK repos are maintained
#     exclude: [external-dns]     # repo names (bare); XOR include
#     include: [dapr, signoz]     # optional allowlist; entries not discovered warn
#     upstream_map:               # optional: member → upstream (needed when the
#       cilium:                   # fork is DETACHED — GitHub nulls .parent)
#         url: https://github.com/cilium/cilium
#         branch: main
#   defaults:                     # inherited ONLY by members without their own
#     fork:                       # def file (forks/<member>.yaml always wins)
#       platform: github
#       token_env: GITHUB_TOKEN
#     versioning: {tag_pattern: "v*-rezus.*"}
#     auto: {merge: false, release: false}
#
# Per member the engine runs the FULL single-fork flow as a child process
# (sync-fork.sh <member>), isolated: one member's conflict/failure never
# blocks the others. Member defs compose: own def file > upstream_map/parent
# discovery + defaults. An undef'd member with no discoverable upstream is
# SKIPPED loudly, never guessed. Exit code = worst member outcome (0 all
# fine/no-op, 2 any conflict, 3 any push failure, 1 ALL members failed);
# the final stdout line is one aggregate PluginResult with a members array.
KIND="$(read_yaml '.kind // "project"' 2>/dev/null || echo project)"
case "$KIND" in
  project|group) ;;
  *) echo "ERROR: unknown def kind '$KIND' for '$FORK_NAME' (project | group)" >&2; exit 1 ;;
esac

if [ "$KIND" = "group" ]; then
  # shellcheck source=scripts/git-host.sh
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/git-host.sh"
  run_group "$PHASE"
  exit $?   # run_group always exits; explicit for readability
fi

# — everything below runs for kind: project (single-fork defs) —

UPSTREAM_URL=$(read_yaml '.upstream.url')
UPSTREAM_BRANCH=$(read_yaml '.upstream.branch')
FORK_URL=$(read_yaml '.fork.url')
FORK_DEFAULT_BRANCH=$(read_yaml '.fork.default_branch')
FORK_MIRROR_BRANCH=$(read_yaml '.fork.mirror_branch' 2>/dev/null || echo "")

# The conflict-escalation contract lives in scripts/conflict-event.sh (#637):
# emit_conflict_event (structured needs-fix payload → manifest + direct HTTP
# POST to the resolver's /events endpoint, with retries — routed there because
# Dapr pub/sub is fire-and-forget: events published while the resolver was
# restarting were silently lost, AND the daprd sidecar in the sync Job never
# terminated so the Job hung and re-emission (every 30m) never happened).
# Row context (theirs/ours/conflict branch) rides the payload so the resolver
# is def-shape-agnostic. See skill/references/conflict-resolution.md
# "Agentic integration shape".
# shellcheck source=scripts/conflict-event.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/conflict-event.sh"

# ── Phase-mode plumbing ──────────────────────────────────────────────────────
# The clone lives under HARMOSTES_WORKDIR (the graph executor shares one workdir
# across the run's nodes) and state passes through .git/harmostes-state.env
# (inside .git so it never pollutes the working tree).
STATE_FILE=""
state_save() {
  { for v in FORK_NAME UPSTREAM_URL UPSTREAM_BRANCH FORK_URL FORK_DEFAULT_BRANCH \
             FORK_MIRROR_BRANCH SYNC_DATE SYNC_BRANCH MERGE_BASE UPSTREAM_HEAD \
             NEW_COMMITS BASELINE PATCH_STATUS PATCH_RESULTS HOOK_RAN; do
      printf '%s=%q\n' "$v" "${!v:-}"
    done
    printf 'VALIDATION_FAILED=%q\n' "${VALIDATION_FAILED:-false}"
    printf 'DIVERGENCE_FAILED=%q\n' "${DIVERGENCE_FAILED:-false}"
    printf 'VALIDATION_RESULTS=%q\n' "${VALIDATION_RESULTS:-(validation not run)}"
  } > "$STATE_FILE"
}
state_load() {
  # STATE_FILE is per-process state: recompute it for phased runs (the merge
  # phase that created it ran in a different process/node).
  if [ "$PHASED" = "1" ] && [ -z "${STATE_FILE:-}" ]; then
    STATE_FILE="${HARMOSTES_WORKDIR:-/tmp}"
    STATE_FILE="${STATE_FILE%/}/fork-${FORK_NAME}/.git/harmostes-state.env"
  fi
  [ -n "${STATE_FILE:-}" ] && [ -f "$STATE_FILE" ] || { echo "ERROR: no sync state — run the merge phase first" >&2; exit 1; }
  # shellcheck disable=SC1090
  source "$STATE_FILE"
}

# push_sync_branch pushes the disposable sync branch: force-with-lease when a
# remote-tracking ref is known (protects foreign updates), plain --force when the
# shallow clone lacks the tracking ref (same-day re-runs legitimately recreate
# the branch; it is derived state owned by this script).
push_sync_branch() {
  if git rev-parse -q --verify "origin/$SYNC_BRANCH" >/dev/null 2>&1; then
    git push --force-with-lease --quiet origin "$SYNC_BRANCH"
  else
    git push --force --quiet origin "$SYNC_BRANCH"
  fi
}

# result_json prints the PluginResult contract line (LAST stdout line wins).
result_json() {
  local changed="$1" artifact="$2" phase="$3" msg="$4"
  printf '{"changed":%s,"artifact":"%s","event":{"phase":"%s"},"message":"%s"}\n' \
    "$changed" "$artifact" "$phase" "$msg"
}

# ── Phase: merge (clone → merge-base check → merge → divergences) ────────────
phase_merge() {
  if [ "$PHASED" = "1" ]; then
    WORKDIR_ROOT="${HARMOSTES_WORKDIR:-/tmp}"
    WORKDIR="${WORKDIR_ROOT%/}/fork-${FORK_NAME}"
    rm -rf "$WORKDIR"          # stale clone from a prior failed run on this pod
    mkdir -p "$WORKDIR_ROOT"
    STATE_FILE="$WORKDIR/.git-state.env"  # placeholder; real .git exists after clone
  else
    WORKDIR=$(mktemp -d)
  fi

  echo ""
  echo "=== Cloning fork (shallow) ==="
  git clone --depth 100 "$FORK_URL" "$WORKDIR"
  cd "$WORKDIR"
  STATE_FILE="$WORKDIR/.git/harmostes-state.env"

  # shellcheck source=scripts/git-host.sh
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/git-host.sh"
  host_setup

  # Phased mode merges the LOCAL MIRROR BRANCH (same host as the fork, kept
  # current by the upstream-mirror action + push webhook) — no upstream-host
  # fetch. The alias remote keeps every downstream `upstream/<branch>` ref
  # working. Legacy (all) mode fetches the upstream host directly.
  if [ "$PHASED" = "1" ]; then
    git remote add upstream "$FORK_URL"
    git fetch --depth 100 upstream "$UPSTREAM_BRANCH" --tags
  else
    git remote add upstream "$UPSTREAM_URL"
    git fetch --depth 100 upstream "$UPSTREAM_BRANCH" --tags
  fi

  CURRENT_BRANCH=$(git branch --show-current)
  # ── Release-branch bootstrap ────────────────────────────────────────────
  # A def whose fork.default_branch does not exist on the fork yet (fresh
  # org member — forks start bare, only upstream's snapshot on their own
  # default). Seed the release branch from the fork's CURRENT default (the
  # clone's HEAD): for a bare fork that HEAD IS upstream's snapshot, so the
  # release line starts byte-identical to upstream — the release-branch
  # invariant holds trivially, and the first real sync arrives as an
  # ordinary upstream catch-up PR. Pushed immediately so later phases see
  # the PR base. Push failure = exit 3 (the push-failure contract).
  if ! git ls-remote --heads origin "$FORK_DEFAULT_BRANCH" 2>/dev/null | grep -q .; then
    echo "=== BOOTSTRAP: release branch $FORK_DEFAULT_BRANCH absent on the fork — seeding from current default ($CURRENT_BRANCH) ==="
    git checkout -b "$FORK_DEFAULT_BRANCH"
    git push origin "$FORK_DEFAULT_BRANCH" \
      || { echo "ERROR: bootstrap push of $FORK_DEFAULT_BRANCH failed" >&2; exit 3; }
    echo "  seeded + pushed: $FORK_DEFAULT_BRANCH"
  fi
  if [ "$CURRENT_BRANCH" != "$FORK_DEFAULT_BRANCH" ]; then
    git checkout "$FORK_DEFAULT_BRANCH" 2>/dev/null || git checkout -b "$FORK_DEFAULT_BRANCH" "origin/$FORK_DEFAULT_BRANCH"
  fi

  # Shallow-history soundness (#566): the clone and the upstream fetch are
  # --depth 100, and a shallow graph can lack the common ancestor — a
  # merge-base that fails (or silently mis-resolves) here turns the
  # up-to-date decision into a coin flip. The false "up to date" is the
  # worst outcome: the sync silently no-ops forever, defeating the
  # dead-man's switch it feeds. So:
  #   1. the up-to-date test is `merge-base --is-ancestor` (exit-status
  #      semantics — upstream head fully contained in the fork), never a
  #      string compare that an empty MERGE_BASE can corrupt;
  #   2. a missing common ancestor triggers an unshallow retry before the
  #      merge — a real 300+-commit range cannot merge from 100-deep
  #      history at all;
  #   3. if the ancestor is STILL unresolvable, we proceed to the merge,
  #      which fails LOUDLY (unrelated histories) instead of skipping.
  MERGE_BASE=$(git merge-base "HEAD" "upstream/$UPSTREAM_BRANCH" 2>/dev/null || echo "")
  if [ -z "$MERGE_BASE" ]; then
    echo "=== shallow history has no common ancestor — unshallowing upstream ==="
    git fetch --unshallow upstream "$UPSTREAM_BRANCH" 2>/dev/null \
      || git fetch --deepen=2000 upstream "$UPSTREAM_BRANCH" 2>/dev/null \
      || true
    MERGE_BASE=$(git merge-base "HEAD" "upstream/$UPSTREAM_BRANCH" 2>/dev/null || echo "")
  fi
  UPSTREAM_HEAD=$(git rev-parse "upstream/$UPSTREAM_BRANCH")

  # ── Release-line coverage (#627 exact identity mapping) ────────────────
  # upstream.release_refs (def-declared, e.g. dapr's release-1.18): release
  # lines upstream cuts OFF the synced branch — their tags are never
  # reachable from it, so without merging them here the release identity
  # anchors at the last line ever merged (observed: v1.18.0-forever while
  # upstream shipped 1.18.1..1.18.4). A pending ref BLOCKS the up-to-date
  # skip: a converged master still owes the release line a merge.
  RELEASE_REFS=$(read_yaml '.upstream.release_refs // []' 2>/dev/null | sed 's/[][]//g' | tr -d '"' | tr ',' ' ')
  REFS_PENDING=""
  MASTER_UPTODATE=0
  for rel_ref in $RELEASE_REFS; do
    [ -z "$rel_ref" ] && continue
    if git fetch --quiet upstream "+refs/heads/$rel_ref:refs/remotes/upstream/$rel_ref" 2>/dev/null; then
      if ! git merge-base --is-ancestor "upstream/$rel_ref" "HEAD" 2>/dev/null; then
        REFS_PENDING="$REFS_PENDING $rel_ref"
      fi
    else
      echo "WARNING: release ref $rel_ref not found on the upstream host — identity may anchor stale" >&2
    fi
  done

  if git merge-base --is-ancestor "upstream/$UPSTREAM_BRANCH" "HEAD" 2>/dev/null; then
    MASTER_UPTODATE=1
  fi

  if [ "$MASTER_UPTODATE" = 1 ] && [ -z "${REFS_PENDING// /}" ]; then
    echo ""
    echo "=== Already up to date — mirror has no new commits, release lines contained ==="
    if [ "$PHASED" = "1" ]; then
      result_json false "fork-sync-$FORK_NAME" merge "up to date — nothing to merge"
      exit 0
    fi
    # all-mode (#627): a fully converged fork may still owe its RELEASE CUT —
    # the identity can have moved since the last cut (upstream tagged a
    # release whose line the fork already carries). Fall through to the tag
    # phase; its own derivation + ordinal + already-tagged guards decide.
    AUTO_RELEASE=$(read_yaml '.auto.release // false')
    if [ "$AUTO_RELEASE" = "true" ]; then
      phase_tag
    fi
    exit 0
  fi
  if [ "$MASTER_UPTODATE" = 1 ]; then
    echo "=== master already contained — syncing the pending release line(s):$REFS_PENDING ==="
  fi

  NEW_COMMITS=$(git rev-list --count "${MERGE_BASE}..upstream/${UPSTREAM_BRANCH}" 2>/dev/null || echo "?")
  echo ""
  echo "=== Upstream has $NEW_COMMITS new commits — syncing ==="

  # ── Capture divergence baseline (deterministic, BEFORE sync) ────────────
  DT="$SCRIPT_DIR/divergence-track.sh"
  { read_yaml '.additive_paths[]' 2>/dev/null || true; } > "/tmp/${FORK_NAME}-additive.txt"
  { read_yaml '.deletions[]'       2>/dev/null || true; } > "/tmp/${FORK_NAME}-deletions.txt"
  BASELINE="/tmp/${FORK_NAME}-divergence-baseline.json"
  echo ""
  echo "=== Capturing divergence baseline (declared additive + auto + deletions) ==="
  bash "$DT" capture "$WORKDIR" "upstream/$UPSTREAM_BRANCH" "$FORK_DEFAULT_BRANCH" "$BASELINE" \
       "/tmp/${FORK_NAME}-additive.txt" "/tmp/${FORK_NAME}-deletions.txt"

  SYNC_DATE=$(date +%Y-%m-%d)
  SYNC_BRANCH="rezus/sync-${SYNC_DATE}"

  # Branch the sync work off the RELEASE branch (not upstream) so the merge
  # result is release + upstream-delta — a clean superset that PRs back.
  git checkout -b "$SYNC_BRANCH" "$FORK_DEFAULT_BRANCH"

  # The merge sources: the synced branch (unless already contained) + every
  # pending release line (#627). Each merges --no-ff; a conflict anywhere
  # routes to the resolver path below (one PR per sync, as before).
  MERGE_SRCS=""
  [ "$MASTER_UPTODATE" = 0 ] && MERGE_SRCS="$MERGE_SRCS upstream/${UPSTREAM_BRANCH}"
  for rel_ref in $REFS_PENDING; do
    MERGE_SRCS="$MERGE_SRCS upstream/$rel_ref"
  done
  [ -z "${MERGE_SRCS// /}" ] && { echo "ERROR: nothing queued to merge" >&2; exit 1; }

  for merge_src in $MERGE_SRCS; do
  # --no-ff guarantees an explicit, auditable merge commit (revertible via -m 1).
  # Shallow-graph guard (#566 class): a release ref fetched at --depth shares
  # no visible ancestor with the fork clone — on "unrelated histories" pull
  # the ref's full history and retry once; a REAL unrelated history still
  # fails loudly on the retry.
  if ! git merge --no-ff --no-edit \
       -m "RZ/sync: merge $merge_src into ${FORK_DEFAULT_BRANCH} (${SYNC_DATE})" \
       "$merge_src"; then
    if git merge-base "$merge_src" HEAD >/dev/null 2>&1; then
      true   # real conflict — resolver path below
    else
      echo "=== no common ancestor with $merge_src — unshallowing and retrying ==="
      git merge --abort 2>/dev/null || true
      git fetch --unshallow upstream 2>/dev/null \
        || git fetch --deepen=5000 upstream 2>/dev/null || true
      if git merge --no-ff --no-edit \
           -m "RZ/sync: merge $merge_src into ${FORK_DEFAULT_BRANCH} (${SYNC_DATE})" \
           "$merge_src"; then
        continue   # merged on the retry — next source
      fi
    fi
    # The merge stopped on conflicts (localized 3-way regions). Conclude it WITH
    # markers on the sync branch, open a needs-conflict-resolution PR for the LLM
    # resolver, and emit fork.conflict.needs-resolution. The resolver re-creates
    # this exact merge, resolves each region from the patch's wiki intent, then
    # re-runs the gates as proof before merging.
    CONFLICT_FILES=$(git diff --name-only --diff-filter=U 2>/dev/null | grep -v '^$' || true)
    echo ""
    echo "=== Merge conflict — opening a resolution PR for the LLM resolver ==="
    echo "Conflicting files:"; echo "$CONFLICT_FILES" | sed 's/^/  - /'
    git add -A 2>/dev/null || true
    git commit --no-edit --quiet 2>/dev/null || true   # conclude the merge WITH markers
    push_sync_branch 2>&1 || { echo "ERROR: cannot push conflict branch" >&2; exit 3; }
    host_label_create "needs-conflict-resolution" 0E8A16 2>/dev/null || true
    PR_URL=$(host_pr_create "$FORK_DEFAULT_BRANCH" "$SYNC_BRANCH" \
      "sync: $FORK_NAME — needs conflict resolution ($SYNC_DATE)" \
      "Upstream merge produced conflicts (merge model — localized 3-way regions). The LLM conflict-resolver will resolve on this branch using each patch's declared intent; the monitor merges once every gate passes." \
      "needs-conflict-resolution" 2>/dev/null || echo "")
    echo "  resolution PR: ${PR_URL:-<none>}"
    emit_conflict_event "$CONFLICT_FILES"
    exit 2
  fi
  done # merge sources

  # ── Permanent divergences (deletions from fork definition) ──────────────
  DELETIONS=$(read_yaml '.deletions[]' 2>/dev/null || true)
  if [ -n "$DELETIONS" ]; then
    echo ""
    echo "=== Applying permanent divergences ==="
    for del_path in $DELETIONS; do
      clean_path="${del_path%/}"
      if [ -e "$clean_path" ]; then
        echo "  rm -rf $clean_path"
        git rm -rf --quiet "$clean_path" 2>/dev/null || true
      fi
    done
    git add -A 2>/dev/null || true
    if [ -f .git/MERGE_HEAD ]; then
      git commit --no-edit --quiet 2>/dev/null || true
    fi
  fi

  # ── Re-apply divergences the merge dropped (self-heal) ──────────────────
  echo ""
  echo "=== Re-applying dropped divergences (self-heal) ==="
  bash "$DT" reapply "$WORKDIR" "$FORK_DEFAULT_BRANCH" "$BASELINE" || true

  # ── Final marker guard (defensive assertion) ────────────────────────────
  CONFLICT_FILES=$(git grep -l -E '^(<<<<<<<|>>>>>>>|=======) ' -- . 2>/dev/null || true)
  if [ -n "$CONFLICT_FILES" ]; then
    echo "ERROR: unexpected conflict markers after a clean merge — aborting sync" >&2
    echo "$CONFLICT_FILES" | sed 's/^/  - /' >&2
    exit 3
  fi

  echo ""
  echo "=== Merge completed cleanly ==="
  if [ "$PHASED" = "1" ]; then
    state_save
    result_json true "fork-sync-$FORK_NAME" merge "merged ${NEW_COMMITS} upstream commit(s)"
  fi
}

# ── Phase: hook (per-fork codegen: SDK regen, chart vendor, …) ───────────────
phase_hook() {
  cd_repo
  # Def-level post_merge_hook wins (lets channels SHARE a hook — e.g.
  # forgejo-next reuses forgejo.sh); convention fallback keeps old defs working.
  HOOK_DEF=$(read_yaml '.post_merge_hook' 2>/dev/null || echo "")
  HOOK_FILE="$MAINT_DIR/${HOOK_DEF:-post-merge-hooks/${FORK_NAME}.sh}"
  HOOK_RAN=false
  if [ -f "$HOOK_FILE" ]; then
    echo ""
    echo "=== Running post-merge hook: ${FORK_NAME}.sh ==="
    FORK_DIR="$PWD" MAINT_DIR="$MAINT_DIR" bash "$HOOK_FILE" || {
      echo "WARNING: post-merge hook failed — continuing but review needed"
    }
    HOOK_RAN=true
  fi
  if [ "$PHASED" = "1" ]; then
    state_save
    result_json true "fork-sync-$FORK_NAME" hook "post-merge hook complete"
  fi
}

# ── Phase: gates (divergence integrity + patch signatures + manifest) ────────
phase_gates() {
  cd_repo
  DIVERGENCE_FAILED=false
  echo ""
  echo "=== Verifying divergence integrity ==="
  if DIVERGENCE_REPORT=$(bash "$SCRIPT_DIR/divergence-track.sh" verify "$PWD" "$BASELINE" 2>&1); then
    echo "  divergence: ✅ intact"
  else
    echo "$DIVERGENCE_REPORT" >&2
    echo "  divergence: ❌ LOST — a fork feature is missing"
    DIVERGENCE_FAILED=true
  fi

  echo ""
  echo "=== Verifying patches ==="
  PATCH_STATUS="all-intact"
  PATCH_RESULTS=""
  PATCH_COUNT=$(read_yaml '.patches | length')
  for i in $(seq 0 $((PATCH_COUNT - 1))); do
    PATCH_FILE=$(read_yaml ".patches[$i].file")
    PATCH_SIG=$(read_yaml ".patches[$i].signature")
    PATCH_DESC=$(read_yaml ".patches[$i].description")
    if [ ! -f "$PATCH_FILE" ]; then
      STATUS="MISSING"
      PATCH_STATUS="needs-review"
    else
      OCCURRENCES=$(grep -cF "$PATCH_SIG" "$PATCH_FILE" 2>/dev/null || true)
      if [ "$OCCURRENCES" -gt 0 ]; then
        STATUS="OK (${OCCURRENCES}x)"
      else
        STATUS="LOST"
        PATCH_STATUS="needs-review"
      fi
    fi
    echo "  ${STATUS} ${PATCH_FILE} — ${PATCH_DESC}"
    PATCH_RESULTS="${PATCH_RESULTS}  ${STATUS} ${PATCH_FILE}\n"
  done
  echo ""
  echo "Patch status: $PATCH_STATUS"

  # Audit manifest.
  MANIFEST_FILE="$MAINT_DIR/manifests/${FORK_NAME}-rezus.yaml"
  mkdir -p "$MAINT_DIR/manifests"
  if [ -f "$MAINT_DIR/scripts/generate-manifest.sh" ]; then
    echo ""
    echo "=== Generating divergence manifest ==="
    bash "$MAINT_DIR/scripts/generate-manifest.sh" "$FORK_DEFAULT_BRANCH" "upstream/$UPSTREAM_BRANCH" > "$MANIFEST_FILE" 2>/dev/null || true
    echo "  manifest written: $MANIFEST_FILE"
  fi

  if [ "$PHASED" = "1" ]; then
    if $DIVERGENCE_FAILED || [ "$PATCH_STATUS" != "all-intact" ]; then
      # Honest red node + a review surface: push the sync branch and open a
      # needs-fix PR so a human can fix on the merged branch (no auto-merge).
      echo ""
      echo "=== Gates RED — pushing sync branch + needs-fix PR ==="
      push_sync_branch 2>&1 || { echo "ERROR: failed to push sync branch" >&2; exit 3; }
      host_label_create "needs-fix" D93F0B 2>/dev/null || true
      host_pr_create "$FORK_DEFAULT_BRANCH" "$SYNC_BRANCH" \
        "sync: $FORK_NAME — gates RED ($SYNC_DATE)" \
        "Divergence or patch verification failed after the upstream merge. See the run envelopes; fix on this branch, then re-run." \
        "needs-fix" 2>/dev/null || echo "  (PR creation failed)"
      state_save
      echo "ERROR: gates red — a fork feature or patch signature did not survive the merge" >&2
      exit 1
    fi
    state_save
    result_json true "fork-sync-$FORK_NAME" gates "divergence + patches intact"
  fi
}

# ── Phase: validate (the fork's declared validation suite) ───────────────────
phase_validate() {
  cd_repo
  VALIDATION_FILE="/tmp/fork-validation-${FORK_NAME}.md"
  rm -f "$VALIDATION_FILE"
  VALIDATION_RESULTS="(validation not run)"
  VALIDATION_FAILED=false
  if [ -f "$MAINT_DIR/checks/validate-fork.sh" ]; then
    echo ""
    echo "=== Running validation ==="
    VALIDATION_OUTPUT=$(bash "$MAINT_DIR/checks/validate-fork.sh" "$FORK_NAME" "$PWD" 2>&1) && VALIDATION_RC=0 || VALIDATION_RC=$?
    echo "$VALIDATION_OUTPUT"
    echo "$VALIDATION_OUTPUT" > "$VALIDATION_FILE"
    VALIDATION_RESULTS="$VALIDATION_OUTPUT"
    if [ "$VALIDATION_RC" -eq 0 ]; then
      echo "  validation: ✅"
    else
      echo "  validation: ❌ (see above)"
      VALIDATION_FAILED=true
    fi
  else
    echo "=== No validator available — skipping ==="
  fi
  if [ "$PHASED" = "1" ]; then
    state_save
    if $VALIDATION_FAILED; then
      echo "ERROR: validation failed — see output above" >&2
      exit 1
    fi
    result_json true "fork-sync-$FORK_NAME" validate "validation green"
  fi
}

# ── Phase: pr (push + PR + opt-in auto-merge) ────────────────────────────────
phase_pr() {
  cd_repo
  AUTO_MERGE=$(read_yaml '.auto.merge // false')

  echo ""
  echo "=== Pushing sync branch ==="
  push_sync_branch 2>&1 || {
    echo "ERROR: failed to push sync branch" >&2
    exit 3
  }

  UPSTREAM_TAG=$(git describe --tags --abbrev=0 "upstream/$UPSTREAM_BRANCH" 2>/dev/null || echo "HEAD")
  UPSTREAM_COMMITS_RANGE="${MERGE_BASE:0:8}..${UPSTREAM_HEAD:0:8}"

  PR_TITLE="RZ/sync: merge upstream ${UPSTREAM_BRANCH} (${SYNC_DATE})"
  PR_LABEL="auto-merge"
  if [ "$PATCH_STATUS" = "needs-review" ]; then
    PR_LABEL="needs-conflict-resolution"
  elif $VALIDATION_FAILED || $DIVERGENCE_FAILED; then
    PR_LABEL="needs-fix"
  fi

  PR_BODY=$(compose_pr_body)

  echo ""
  echo "=== Opening PR ==="
  for label in "$PR_LABEL" "needs-conflict-resolution"; do
    host_label_create "$label" 0E8A16
  done
  PR_URL=$(host_pr_create "$FORK_DEFAULT_BRANCH" "$SYNC_BRANCH" "$PR_TITLE" "$PR_BODY" "$PR_LABEL") || {
    echo "WARNING: failed to open PR: $PR_URL" >&2
  }
  echo "  PR: ${PR_URL:-<none>} (label: $PR_LABEL)"

  if [ "$PR_LABEL" = "auto-merge" ] && [ "$AUTO_MERGE" = "true" ]; then
    echo ""
    echo "=== Auto-merging PR (all gates green, auto.merge enabled) ==="
    MERGE_SHA=$(host_pr_merge "$SYNC_BRANCH" 2>&1) || {
      echo "WARNING: auto-merge failed: $MERGE_SHA" >&2
    }
    [ "$PHASED" = "1" ] && printf 'MERGE_SHA=%q\n' "${MERGE_SHA:-}" >> "$STATE_FILE"
    if [ "$PHASED" = "1" ]; then
      result_json true "fork-sync-$FORK_NAME" pr "PR merged (${MERGE_SHA:0:12})"
    fi
  elif [ "$PHASED" = "1" ]; then
    result_json false "fork-sync-$FORK_NAME" pr "PR left for review (label=$PR_LABEL; auto.merge=$AUTO_MERGE)"
  fi
}

# ── Phase: tag (machine-cut release trigger) ─────────────────────────────────
phase_tag() {
  cd_repo
  AUTO_RELEASE=$(read_yaml '.auto.release // false')
  MERGE_SHA="${MERGE_SHA:-}"
  RELEASE_TAG=""

  # MERGE_SHA is informational: a converged fork (up-to-date all-mode, #627)
  # reaches this phase with no fresh merge and still owes its release cut —
  # the tag targets the fork default branch HEAD either way.
  if [ "$AUTO_RELEASE" != "true" ]; then
    echo ""
    echo "=== No release (auto.release=$AUTO_RELEASE, merged=${MERGE_SHA:+yes}${MERGE_SHA:-no}) ==="
    if [ "$PHASED" = "1" ]; then
      result_json false "fork-sync-$FORK_NAME" tag "no release"
    fi
    return 0
  fi

  # Re-sync the release branch so we can tag the merged commit.
  git fetch --quiet origin "$FORK_DEFAULT_BRANCH"
  git checkout --quiet "$FORK_DEFAULT_BRANCH" 2>/dev/null || true
  git reset --hard --quiet "origin/$FORK_DEFAULT_BRANCH"

  # Source the #627 identity-mapping helper — the single derivation for ALL
  # fork-maintenance modes (sync mints here; mapping-mode reuses the same
  # functions in its own walk).
  # shellcheck source=scripts/derive-release-version.sh
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/derive-release-version.sh"

  # ── Upstream identity, mapped exactly (#627 contract) ─────────────────────
  # Tags mirror upstream major.minor.patch exactly; -rezus.NN counts addon
  # builds on top and RESETS at every upstream change. Identity = the highest
  # upstream release tag whose CONTENT is in the tree, cross-checked against
  # the upstream HOST (a shallow clone's tag window never decides — the
  # #601/#603 lesson class). Pattern: versioning.upstream_pattern (def-
  # declared, e.g. "b[0-9]*" for a revision-tag upstream) or "auto" (pure
  # vX.Y.Z). upstream.release_refs (def-declared, e.g. dapr's release-1.18):
  # release lines upstream cuts OFF the synced branch — merged here so their
  # content and tags become claimable; without this the identity would stick
  # at the last release ever merged into the branch (v1.18.0-forever).
  RELEASE_REFS=$(read_yaml '.upstream.release_refs // []' 2>/dev/null | sed 's/[][]//g' | tr -d '"' | tr ',' ' ')
  for rel_ref in $RELEASE_REFS; do
    [ -z "$rel_ref" ] && continue
    # Merge-phase coverage: the refs were already merged into the tree (the
    # #627 phase_merge loop). This pass only VERIFIES — a ref that is still
    # missing means the merge phase didn't run it (all-mode up-to-date exit
    # before the release-refs loop landed) — surface, never mint.
    if ! git fetch --quiet "$UPSTREAM_URL" "+refs/heads/$rel_ref:refs/remotes/upstream-rel-$rel_ref" 2>/dev/null; then
      echo "WARNING: release ref $rel_ref not found on the upstream host" >&2
      continue
    fi
    if ! git merge-base --is-ancestor "refs/remotes/upstream-rel-$rel_ref" HEAD 2>/dev/null; then
      echo "WARNING: release ref $rel_ref is NOT contained in HEAD — identity cannot map exactly; run a sync to merge the line first" >&2
      REL_REF_UNMERGED=1
    fi
  done
  if [ "${REL_REF_UNMERGED:-0}" = 1 ]; then
    if [ "$PHASED" = "1" ]; then
      result_json false "fork-sync-$FORK_NAME" tag "release line not merged — sync first"
    fi
    return 0
  fi

  UPSTREAM_PATTERN=$(read_yaml '.versioning.upstream_pattern // "auto"' 2>/dev/null || echo auto)
  if ! derive_upstream_identity "HEAD" "$UPSTREAM_URL" "$UPSTREAM_PATTERN"; then
    echo "WARNING: could not determine upstream release identity — skipping auto-release (#627: never mint blind)" >&2
    if [ "$PHASED" = "1" ]; then
      result_json false "fork-sync-$FORK_NAME" tag "no upstream release derivable"
    fi
    return 0
  fi
  PREV_ANCHOR=$(previous_anchor "$FORK_URL")
  if [ "$IDENTITY_STATE" = "behind" ]; then
    echo "WARNING: upstream $REMOTE_LATEST is newer than anything reachable from $FORK_DEFAULT_BRANCH — its content is NOT in this tree (#627 exact mapping); declare upstream.release_refs or a mapping row for its line. NOT minting a stale-identity tag." >&2
    if [ "$PHASED" = "1" ]; then
      result_json false "fork-sync-$FORK_NAME" tag "identity behind ($REMOTE_LATEST not in tree)"
    fi
    return 0
  fi
  if [ -n "$PREV_ANCHOR" ] && [ "$PREV_ANCHOR" != "$IDENTITY" ]; then
    echo "=== Upstream change $PREV_ANCHOR → $IDENTITY: -rezus ordinal resets to 1 ==="
  fi
  # Ordinal: highest existing <IDENTITY>-rezus.* on the fork remote + 1 —
  # the reset at upstream changes falls out of the scoping (a new identity
  # has no rezus tags yet → 0+1 = 1).
  NEXT_N=$(next_rezus_ordinal "$IDENTITY" "$FORK_URL")
  # Ordinal tag-shape contract (#595) — enforced by the helpers: ordinals are
  # UNPADDED (a digit-only prerelease identifier ranks NUMERICALLY by semver,
  # monotonic at every boundary; zero-padded …-rezus.01 is INVALID semver and
  # invisible to semver ImagePolicies) and the image tag is the git tag
  # VERBATIM — no variant suffix at all (rezuscloud/signoz#67; a dash-fused
  # variant ranks lexically and "10-community" < "9-community" silently
  # stalled a policy at every 9→10 boundary — flux marker stuck at
  # v0.127.0-rezus.3-community since 2026-06-29).
  RELEASE_TAG="${IDENTITY}-rezus.${NEXT_N}"

  HEAD_TAG=$(git tag --points-at HEAD | grep -E -- "${IDENTITY}-rezus\." || true)
  if [ -n "$HEAD_TAG" ]; then
    echo "=== HEAD already tagged ($HEAD_TAG) — skipping auto-release ==="
    RELEASE_TAG=""
  else
    echo "=== Auto-releasing: tagging $FORK_DEFAULT_BRANCH as $RELEASE_TAG (identity $IDENTITY, $IDENTITY_STATE) ==="
    git tag "$RELEASE_TAG"
    if git push --quiet origin "$RELEASE_TAG" 2>&1; then
      echo "  tagged $RELEASE_TAG → fork release workflow will build + publish image"
    else
      echo "WARNING: failed to push tag $RELEASE_TAG"
      RELEASE_TAG=""
    fi
  fi
  if [ "$PHASED" = "1" ]; then
    [ -n "$RELEASE_TAG" ] && result_json true "$RELEASE_TAG" tag "release tag cut (identity $IDENTITY, $IDENTITY_STATE)" \
                         || result_json false "fork-sync-$FORK_NAME" tag "no release"
  fi
}

# cd into the phased clone (state must exist). Re-sources the host abstraction:
# each phase runs as its own process (its own graph node) and needs the
# host_* helpers + credentials.
cd_repo() {
  if [ "$PHASED" = "1" ]; then
    state_load                 # separate process per node — reload state
    WORKDIR="${HARMOSTES_WORKDIR:-/tmp}"; WORKDIR="${WORKDIR%/}/fork-${FORK_NAME}"
    cd "$WORKDIR"
  else
    cd "$WORKDIR"              # single process — state is in memory
  fi
  # shellcheck source=scripts/git-host.sh
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/git-host.sh"
  host_setup
}

# compose_pr_body builds the PR body from the current state variables.
compose_pr_body() {
  cat <<EOF
## Upstream sync: ${FORK_NAME}

**Upstream**: ${UPSTREAM_URL} (\`${UPSTREAM_BRANCH}\`)
**New commits**: ${NEW_COMMITS} since last sync
**Range**: ${MERGE_BASE:0:8}..${UPSTREAM_HEAD:0:8}

### Patch verification

$(echo -e "$PATCH_RESULTS")

**Status**: ${PATCH_STATUS}

$(if [ "$PATCH_STATUS" = "needs-review" ]; then echo "⚠️ Some patches need manual review — a signature was not found after the merge."; else echo "✅ All patches verified — this PR is auto-mergeable."; fi)

### Post-merge hook

$(if [ "${HOOK_RAN:-false}" = "true" ]; then echo "Ran \`post-merge-hooks/${FORK_NAME}.sh\`"; else echo "(no post-merge hook)"; fi)

---

${VALIDATION_RESULTS}

---

### Divergence integrity

$(if $DIVERGENCE_FAILED; then echo "❌ A fork feature was LOST in this sync (see job logs). PR is labelled \`needs-fix\` — it will not auto-merge."; else echo "✅ All declared additive paths + auto divergences intact (Gate 4b)."; fi)

---

_Automated by platform/harmostes/fork-maintenance (k8s-config GitOps)._
EOF
}

# ── Dispatch ─────────────────────────────────────────────────────────────────
if [ "$MODE" = "mapping" ]; then
  # Mapping-table transport (the forgejo self-sync, sync.yml's walk in the
  # plugin). See docs/forgejo-cutover.md for the equivalence contract.
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/mapping-mode.sh"
  mapping_dispatch
  exit 0
fi

case "$PHASE" in
  merge)    phase_merge ;;
  hook)     phase_hook ;;
  gates)    phase_gates ;;
  validate) phase_validate ;;
  pr)       phase_pr ;;
  tag)      phase_tag ;;
  all)
    # Legacy single-shot flow for forks not yet graph-native. Exit codes:
    # 0 = up to date or PR opened (auto-merged if auto.merge); 2 = conflict;
    # 3 = push failure. Identical semantics to the pre-phase-mode single-shot flow.
    phase_merge          # exits 0 (up-to-date) or 2 (conflict) or 3 on its own
    phase_hook
    phase_validate
    phase_gates
    phase_pr
    AUTO_RELEASE=$(read_yaml '.auto.release // false')
    if [ "$PR_LABEL" = "auto-merge" ] && [ "$AUTO_MERGE" = "true" ]; then
      phase_tag
    fi
    echo ""
    echo "=== Sync complete ==="
    echo "  PR: ${PR_URL:-<none>}"
    echo "  Label: ${PR_LABEL}"
    echo "  Patch status: ${PATCH_STATUS}"
    echo "  Divergence: $(if $DIVERGENCE_FAILED; then echo '❌ LOST (needs-fix)'; else echo '✅ intact'; fi)"
    [ -n "${RELEASE_TAG:-}" ] && echo "  Released tag: $RELEASE_TAG (image build triggered)"
    ;;
esac

# Exit 0 explicitly: with set -e, a bare `[ -n "" ] && ...` as the final
# statement returns 1, which made every successful sync (auto.release: false
# → empty RELEASE_TAG) report "sync failed (exit 1)" despite a merged PR.
exit 0
