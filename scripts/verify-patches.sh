#!/usr/bin/env bash
# =============================================================================
# verify-patches.sh — Verify fork patches survived an upstream merge
# =============================================================================
# Reads a fork definition and greps each patch signature in the fork's files.
# Returns 0 if all patches intact, 1 if any are lost.
#
# Usage: verify-patches.sh <fork-definition.yaml> [fork-workdir]
# =============================================================================
set -euo pipefail

DEF_FILE="${1:?Usage: verify-patches.sh <fork-definition.yaml> [workdir]}"
WORKDIR="${2:-.}"

if [ ! -f "$DEF_FILE" ]; then
  echo "ERROR: definition not found: $DEF_FILE" >&2
  exit 1
fi

PATCH_COUNT=$(yq -r '.patches | length' "$DEF_FILE")
ALL_INTACT=true

echo "=== Patch verification ==="
for i in $(seq 0 $((PATCH_COUNT - 1))); do
  FILE=$(yq -r ".patches[$i].file" "$DEF_FILE")
  SIG=$(yq -r ".patches[$i].signature" "$DEF_FILE")
  DESC=$(yq -r ".patches[$i].description" "$DEF_FILE")

  FILEPATH="${WORKDIR}/${FILE}"
  if [ ! -f "$FILEPATH" ]; then
    echo "  ❌ MISSING ${FILE} — ${DESC}"
    ALL_INTACT=false
    continue
  fi

  COUNT=$(grep -cF "$SIG" "$FILEPATH" 2>/dev/null || echo 0)
  if [ "$COUNT" -gt 0 ]; then
    echo "  ✅ ${FILE} — '${SIG}' (${COUNT}x)"
  else
    echo "  ❌ LOST ${FILE} — '${SIG}' — ${DESC}"
    ALL_INTACT=false
  fi
done

if $ALL_INTACT; then
  echo ""
  echo "Result: ALL PATCHES INTACT ✅"
  exit 0
else
  echo ""
  echo "Result: SOME PATCHES NEED REVIEW ⚠️"
  exit 1
fi
