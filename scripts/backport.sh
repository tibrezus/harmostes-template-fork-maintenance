#!/usr/bin/env bash
# =============================================================================
# backport.sh — agent-driven upstream backports
# =============================================================================
# Cherry-picks critical upstream fixes (security, data integrity) onto the
# release branch ahead of the next upstream patch release, with RZ/bp:
# provenance, through the same gate chain as a sync; the pi agent covers the
# conflict case (same escalation contract as sync-fork.sh).
#
# Every backport lands through the SAME gate chain as a sync:
#   cherry-pick (-x) → subject rewritten to "RZ/bp: <original>" →
#   marker scan → validate-fork.sh → verify-patches.sh → PR → auto-merge
#
# No release is cut here: a backport only advances the release branch; the
# next sync's auto-release (or a manual v*-rezus.N tag) builds the image.
#
# Usage: backport.sh <fork-name> <upstream-sha> [<upstream-sha> ...]
# Exit codes:
#   0 — backported (PR merged if auto.merge)
#   2 — cherry-pick conflict (partial work pushed; agent runbook applies)
#   3 — push failure
# =============================================================================
set -euo pipefail

FORK_NAME="${1:?Usage: backport.sh <fork-name> <upstream-sha> [...]}"
shift
[ "$#" -ge 1 ] || { echo "ERROR: at least one upstream SHA required" >&2; exit 1; }

MAINT_DIR="${MAINT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT_DIR="$MAINT_DIR/scripts"
SYNC_DATE="$(date -u +%Y-%m-%d)"
WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# shellcheck source=scripts/git-host.sh
# shellcheck source=scripts/git-host.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/git-host.sh"
DEF="$MAINT_DIR/forks/${FORK_NAME}.yaml"
[ -f "$DEF" ] || { echo "ERROR: no fork definition for $FORK_NAME" >&2; exit 1; }

read_yaml() { yq e "$1" "$DEF"; }
UPSTREAM_URL=$(read_yaml '.upstream.url')
FORK_URL=$(read_yaml '.fork.url')
# Release row: mapping-table defs carry theirs→ours rows; the release row is
# the one with tags: derive. Legacy defs keep flat fields.
if read_yaml '.mappings' >/dev/null 2>&1 && [ "$(read_yaml '.mappings | length')" != "0" ]; then
  UPSTREAM_BRANCH=$(read_yaml '[.mappings[] | select(.tags == "derive")][0].theirs')
  FORK_DEFAULT_BRANCH=$(read_yaml '[.mappings[] | select(.tags == "derive")][0].ours')
else
  UPSTREAM_BRANCH=$(read_yaml '.upstream.branch')
  FORK_DEFAULT_BRANCH=$(read_yaml '.fork.default_branch')
fi
BP_BRANCH="rezus/bp-${SYNC_DATE}"

echo "=== Backport: ${FORK_NAME} — $# upstream commit(s) → ${FORK_DEFAULT_BRANCH} ==="
echo "  upstream: ${UPSTREAM_URL} (${UPSTREAM_BRANCH})"
echo "  fork:     ${FORK_URL} (${FORK_DEFAULT_BRANCH})"

# ── 1. Clone + fetch upstream ────────────────────────────────────────────────────
echo ""
echo "=== Cloning fork (shallow) ==="
git clone --depth 100 "$FORK_URL" "$WORKDIR/repo"
cd "$WORKDIR/repo"
host_setup

git remote add upstream "$UPSTREAM_URL"
git fetch --depth 100 upstream "$UPSTREAM_BRANCH" --tags

# ── 2. Verify every SHA is on the upstream release branch ───────────────────
for SHA in "$@"; do
  if ! git merge-base --is-ancestor "$SHA" "upstream/${UPSTREAM_BRANCH}" 2>/dev/null; then
    echo "ERROR: ${SHA} is not on upstream/${UPSTREAM_BRANCH} — refusing to backport foreign commits" >&2
    exit 1
  fi
done

git checkout --quiet -b "$BP_BRANCH" "origin/$FORK_DEFAULT_BRANCH"

# ── 3. Cherry-pick with the RZ/bp: convention ───────────────────────────────
# -x records "(cherry picked from commit <sha>)" — the standard backport
# provenance line; the subject gets the RZ/bp: prefix.
PICKED=()
for SHA in "$@"; do
  SUBJECT=$(git log -1 --format='%s' "$SHA")
  echo "  cherry-picking ${SHA:0:12} — ${SUBJECT}"
  if ! git cherry-pick -x "$SHA" >/dev/null 2>&1; then
    echo ""
    echo "=== Cherry-pick conflict on ${SHA:0:12} — escalating ==="
    git diff --name-only --diff-filter=U 2>/dev/null || true
    mkdir -p "$MAINT_DIR/manifests" 2>/dev/null || true
    NEEDS_FIX="$MAINT_DIR/manifests/${FORK_NAME}-needs-fix.json"
    cat > "$NEEDS_FIX" <<EOF
{
  "kind": "backport-conflict",
  "fork": "${FORK_NAME}",
  "branch": "${BP_BRANCH}",
  "sha": "${SHA}",
  "subject": $(git log -1 --format='%s' "$SHA" | jq -Rs .),
  "files": $(git diff --name-only --diff-filter=U 2>/dev/null | jq -Rs .),
  "protocol": "Resolve the 3-way regions like a sync conflict (skill: fork-maintenance / conflict-resolution), reword the subject to RZ/bp:, then re-run the gates and push ${BP_BRANCH}."
}
EOF
    git push --quiet origin "$BP_BRANCH" --force-with-lease 2>/dev/null || true
    echo "  partial work pushed to ${BP_BRANCH}; manifest: ${NEEDS_FIX}"
    exit 2
  fi
  # Rewrite subject with the convention prefix; keep body + provenance line.
  git log -1 --format='%B' | sed "1s/^/RZ\/bp: /" | git commit --amend --quiet -F -
  PICKED+=("${SHA:0:12}")
done

echo ""
echo "=== Backported: ${PICKED[*]} ==="

# ── 4. Gates (the non-negotiables) ───────────────────────────────────────────
MARKERS=$(git grep -l -E '^(<<<<<<<|>>>>>>>|=======) ' -- . 2>/dev/null || true)
if [ -n "$MARKERS" ]; then
  echo "ERROR: conflict markers remain:" >&2; echo "$MARKERS" >&2; exit 2
fi

if [ -f "$MAINT_DIR/checks/validate-fork.sh" ]; then
  echo "=== Validating fork ==="
  VALIDATION_MD=$(bash "$MAINT_DIR/checks/validate-fork.sh" "$FORK_NAME" "$PWD") || {
    echo "ERROR: validation failed — see above" >&2; exit 2
  }
else
  VALIDATION_MD="(no validator)"
fi

if [ -f "$MAINT_DIR/scripts/verify-patches.sh" ]; then
  echo "=== Verifying patches ==="
  bash "$MAINT_DIR/scripts/verify-patches.sh" "$DEF" "$PWD" || {
    echo "ERROR: patch signatures lost" >&2; exit 2
  }
fi

# ── 5. Push + PR + (opt-in) merge ───────────────────────────────────────────
echo ""
echo "=== Pushing ${BP_BRANCH} ==="
git push --quiet origin "$BP_BRANCH" 2>&1 || { echo "ERROR: push failed" >&2; exit 3; }

echo "=== Opening PR ==="
host_label_create "auto-merge" 0E8A16 2>/dev/null || true
PR_BODY="Backport of ${#PICKED[@]} upstream commit(s) onto \`${FORK_DEFAULT_BRANCH}\` (RZ/bp: convention).

$(printf '%s\n' "${PICKED[@]}" | sed 's/^/- `/;s/$/`/')

${VALIDATION_MD}

Cherry-picks carry \`(cherry picked from commit …)\` provenance lines. No release tag is cut: the next sync's auto-release builds the image."
PR_URL=$(host_pr_create "$FORK_DEFAULT_BRANCH" "$BP_BRANCH" \
  "RZ/bp: ${#PICKED[@]} upstream commit(s) (${SYNC_DATE})" "$PR_BODY" "auto-merge")
echo "  PR: ${PR_URL:-<none>}"

AUTO_MERGE=$(read_yaml '.auto.merge // false')
if [ "$AUTO_MERGE" = "true" ]; then
  echo "=== Auto-merging PR (gates green, auto.merge enabled) ==="
  MERGE_SHA=$(host_pr_merge "$BP_BRANCH" 2>&1) || echo "WARNING: merge failed: $MERGE_SHA" >&2
fi

echo ""
echo "=== Backport complete ==="
echo "  commits: ${#PICKED[@]}"
echo "  PR: ${PR_URL:-<none>}"
exit 0
