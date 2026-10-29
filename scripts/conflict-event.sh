#!/usr/bin/env bash
# conflict-event.sh — the unified conflict-escalation contract (#637).
# =============================================================================
# One conflict contract for EVERY fork-maintenance mode: a conflict produces
#   1. a conflict branch carrying the merge WITH markers,
#   2. ONE labelled PR (needs-conflict-resolution) per row — stable branch,
#      force-updated, never date-stamped (no daily PR pileup),
#   3. a fork.conflict.needs-resolution event delivered to the resolver
#      (direct HTTP POST with retries — the wire mapping-mode was missing;
#      see sync-fork.sh's history for why this is not Dapr pub/sub).
#
# Functions-only (sourced by sync-fork.sh and resolve-conflict.sh; unit-tested
# by scripts/tests/conflict-contract.test.sh).
#
# Caller contract (dynamic scope — both callers define these):
#   read_yaml <yq-expr>   def parser (sync-fork.sh + resolve-conflict.sh both
#                         define one against their DEF_FILE)
#   FORK_NAME, UPSTREAM_URL, UPSTREAM_BRANCH, MAINT_DIR
#   MERGE_BASE, UPSTREAM_HEAD  (merge-phase state; may be empty in tests)
#
# No global set-flags here — sourced libs don't mutate the caller's shell
# (house pattern: derive-release-version.sh).
# =============================================================================

# conflict_branch_for <theirs> — the STABLE per-row conflict branch. No date:
# the daily walk force-pushes the SAME branch and updates the SAME PR, and the
# resolver pushes its resolution onto it and merges it. A date-suffixed branch
# (the old shape) opened a fresh PR every day — rezuscloud/forgejo#148/#149.
conflict_branch_for() {
  echo "conflict/$(echo "$1" | tr '/' '-')"
}

# emit_conflict_event <conflict-files-newline-separated> [theirs] [ours] [conflict-branch]
#
# Builds the structured needs-fix payload (patches at risk, verified against
# their declared signatures), writes it to manifests/<fork>-needs-fix.json
# (audit / manual-runs fallback), and POSTs it as a CloudEvent to the
# resolver's /events endpoint with retries. theirs/ours/conflict-branch are
# the ROW context — mapping mode passes them; legacy single-row mode omits
# them and the resolver falls back to the def's top-level upstream.branch /
# fork.default_branch (the degenerate one-row table).
emit_conflict_event() {
  local cfiles="${1:-}" theirs="${2:-}" ours="${3:-}" cbranch="${4:-}"
  local payload patches_json pcount i
  patches_json="[]"
  pcount=$(read_yaml '.patches | length' 2>/dev/null || true)
  for i in $(seq 0 $((pcount - 1))); do
    local pf ps pd st="LOST"
    pf=$(read_yaml ".patches[$i].file"); ps=$(read_yaml ".patches[$i].signature"); pd=$(read_yaml ".patches[$i].description")
    if [ -f "$pf" ]; then { [ "$(grep -cF "$ps" "$pf" 2>/dev/null || true)" -gt 0 ] && st="OK"; } || st="LOST"; else st="MISSING"; fi
    patches_json=$(echo "$patches_json" | jq --arg f "$pf" --arg s "$ps" --arg d "$pd" --arg st "$st" '. += [{file:$f,signature:$s,description:$d,status:$st}]')
  done
  payload=$(jq -n \
    --arg fork "$FORK_NAME" \
    --arg upstream_url "$UPSTREAM_URL" --arg upstream_branch "$UPSTREAM_BRANCH" \
    --arg upstream_range "${MERGE_BASE:-}${MERGE_BASE:+..}${UPSTREAM_HEAD:-}" \
    --argjson patches "$patches_json" \
    --arg conflict_files "$cfiles" \
    --arg theirs "$theirs" --arg ours "$ours" --arg cbranch "$cbranch" \
    '{fork:$fork, upstream_url:$upstream_url, upstream_branch:$upstream_branch,
      upstream_range:$upstream_range, patches_at_risk:$patches,
      conflict_files: ($conflict_files | split("\n") | map(select(length>0))),
      row: {theirs:$theirs, ours:$ours}, conflict_branch: $cbranch}')
  mkdir -p "$MAINT_DIR/manifests" 2>/dev/null || true
  echo "$payload" > "$MAINT_DIR/manifests/${FORK_NAME}-needs-fix.json"
  # Direct HTTP delivery to the resolver (replaces Dapr pub/sub — see header).
  RESOLVER_URL="${RESOLVER_URL:-http://fork-conflict-resolver.harmostes.svc.cluster.local/events}"
  ce=$(echo "$payload" | jq -c '{source:"fork-sync", type:"fork.conflict.needs-resolution", data:.}')
  local delivered=false attempt
  for attempt in 1 2 3 4 5; do
    if curl -sf -m 5 -X POST "$RESOLVER_URL" -H "Content-Type: application/json" -d "$ce" >/dev/null 2>&1; then
      echo "  delivered fork.conflict.needs-resolution → resolver"
      delivered=true; break
    fi
    echo "  resolver unreachable (attempt $attempt); retrying in ${attempt}s"
    sleep "$attempt"
  done
  $delivered || echo "  WARNING: resolver unreachable after retries — needs-fix payload at manifests/${FORK_NAME}-needs-fix.json"
}

# event_row_context <payload-json> — echo "<theirs>|<ours>|<conflict-branch>"
# from an event payload's row context. Empty fields (legacy single-row events)
# mean "fall back to the def's top-level upstream.branch / fork.default_branch
# and the rezus/sync-<date> branch". `|`-separated (never in a git ref) and
# parsed with IFS='|' — an IFS-whitespace separator (space/tab) makes `read`
# strip empty leading/trailing fields, shifting partial rows. Parsed with
# python3: guaranteed present in both run contexts (worker image ships
# harmostes.py; the resolver pod runs conflict-subscriber.py on it), unlike
# jq on the resolver image.
event_row_context() {
  python3 - "$1" <<'PYEOF'
import json, sys
try:
    d = json.loads(sys.argv[1] or "{}")
except json.JSONDecodeError:
    d = {}
row = d.get("row") or {}
print("|".join([row.get("theirs", ""), row.get("ours", ""), d.get("conflict_branch", "")]))
PYEOF
}
