#!/usr/bin/env bash
# =============================================================================
# generate-manifest.sh — Fork divergence manifest generator
# =============================================================================
# Generates a YAML manifest of all differences between our fork's release
# branch and the upstream branch. Three sections: deletions, patches, additive.
#
# Usage: generate-manifest.sh <our-branch> <upstream-ref>
# Example: generate-manifest.sh rezus/forgejo upstream/forgejo
#
# Must be run from inside a git repository that has both refs available.
# =============================================================================
set -uo pipefail

BRANCH="${1:?Usage: generate-manifest.sh <our-branch> <upstream-ref>}"
UPSTREAM="${2:?Usage: generate-manifest.sh <our-branch> <upstream-ref>}"

echo "# Fork Divergence Manifest"
echo "# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "# Source: git diff ${BRANCH} ${UPSTREAM}"
echo "# REGENERATE: platform/harmostes/fork-maintenance/scripts/generate-manifest.sh"
echo ""

WORKDIR=$(mktemp -d)
trap "rm -rf $WORKDIR" EXIT

# =============================================================================
# Pass 1: Deletions (top-level dirs in upstream but not in ours)
# =============================================================================
echo "deletions:"
for dir in $(git ls-tree -d --name-only "$UPSTREAM" | sort); do
  if ! git ls-tree -d --name-only "$BRANCH" | grep -qx "$dir"; then
    echo "  - ${dir}/"
  fi
done

# =============================================================================
# Pass 2: Patches (files in both branches with different content)
# =============================================================================
echo ""
echo "patches:"

git diff --name-only "$BRANCH" "$UPSTREAM" -- \
  '*.go' '*.yaml' '*.yml' '*.xml' '*.ts' '*.tsx' '*.json' '*.jsx' '*.css' '*.toml' '*.mod' \
  ':(exclude)*.lock' ':(exclude)*.tgz' ':(exclude)go.sum' \
  > "$WORKDIR/files.txt" 2>/dev/null || true

while IFS= read -r file; do
  [ -z "$file" ] && continue
  # Must exist in BOTH branches
  git show "${BRANCH}:${file}" >/dev/null 2>&1 || continue
  git show "${UPSTREAM}:${file}" >/dev/null 2>&1 || continue
  # Must actually differ
  git diff --quiet "$BRANCH" "$UPSTREAM" -- "$file" && continue

  # Extract signature from diff
  diff <(git show "${UPSTREAM}:${file}") <(git show "${BRANCH}:${file}") > "$WORKDIR/diff.txt" 2>/dev/null
  signature=$(grep '^>' "$WORKDIR/diff.txt" | sed 's/^> //' | sed 's/^[[:space:]]*//' \
    | grep -vE '^$|^//|^#' | sed -n '1p')
  occurrences=$(git show "${BRANCH}:${file}" | grep -cF "$signature" 2>/dev/null || echo 0)

  echo "  - file: ${file}"
  echo "    signature: '${signature}'"
  echo "    occurrences: ${occurrences}"
done < "$WORKDIR/files.txt"

# =============================================================================
# Pass 3: Additive (files in ours not in upstream)
# =============================================================================
echo ""
echo "additive:"

comm -23 \
  <(git ls-tree -r --name-only "$BRANCH" | sort) \
  <(git ls-tree -r --name-only "$UPSTREAM" | sort) | \
  awk -F/ '{
    if ($1 == ".github" && $2 == "workflows") print "  - .github/workflows/"$3
    else if ($1 == "staging" && NF >= 3) print "  - staging/src/"$2"/"$3"/"
    else if ($1 == "cmd" && NF >= 2) print "  - cmd/"$2"/"
    else if ($1 == "charts" && NF >= 2) print "  - charts/"$2"/"
    else if ($1 == "pkg" && NF >= 3) print "  - pkg/"$2"/"$3"/"
    else print "  - "$0
  }' | sort -u
