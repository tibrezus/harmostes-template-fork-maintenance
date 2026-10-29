#!/usr/bin/env bash
# =============================================================================
# gate-resolved.sh — the combined "is this sync branch resolved?" gate
# =============================================================================
# Used as harmostes's --gate: exit 0 = green (no markers + validates + signatures),
# non-zero = fail. On failure, stderr is fed back to the agent by harmostes as a
# same-session continuation (the agent fixes in context, harmostes re-runs this).
#
# Usage: gate-resolved.sh <fork-name> <workdir>
# =============================================================================
set -euo pipefail
FORK_NAME="${1:?Usage: gate-resolved.sh <fork-name> <workdir>}"
WD="${2:?}"
MAINT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEF="$MAINT_DIR/forks/${FORK_NAME}.yaml"
[ -f "$DEF" ] || { echo "FAIL: fork definition not found: $DEF"; exit 1; }
ry() { yq -r "$1" "$DEF"; }
cd "$WD"

# Gate 1 — no conflict markers (the real "conflicts resolved" signal).
MARKERS=$(git grep -l -E '^(<<<<<<<|>>>>>>>|=======) ' -- . 2>/dev/null || true)
if [ -n "$MARKERS" ]; then
  echo "FAIL gate 1 (conflict markers remain):"; echo "$MARKERS" | sed 's/^/  - /'
  exit 1
fi

# Gate 5 — validate-fork.sh (build / codegen / integration, per the fork def).
if [ -f "$MAINT_DIR/checks/validate-fork.sh" ]; then
  if ! bash "$MAINT_DIR/checks/validate-fork.sh" "$FORK_NAME" "$WD"; then
    echo "FAIL gate 5 (validate-fork.sh: build/codegen/integration)"
    exit 1
  fi
fi

# Gate 4 — patch signatures intact (each customization's signature must survive).
PC=$(ry '.patches | length' 2>/dev/null || echo 0)
for i in $(seq 0 $((PC - 1))); do
  PF=$(ry ".patches[$i].file"); PS=$(ry ".patches[$i].signature")
  if [ -f "$PF" ]; then
    OCC=$(grep -cF "$PS" "$PF" 2>/dev/null || true)
    [ "$OCC" -eq 0 ] && { echo "FAIL gate 4 (signature lost in $PF)"; exit 1; }
  fi
done

echo "GATES GREEN (no markers + validation + signatures)"
exit 0
