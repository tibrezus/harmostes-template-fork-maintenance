# derive-release-version.sh — the upstream-identity mapping contract (#627).
#
# CONTRACT (owner directive 2026-09-27): fork tags mirror upstream release
# tags exactly, suffixed -rezus.NN. NN counts addon builds on top of that
# upstream identity and RESETS to 1 at every upstream change. "Mapped
# exactly for major.minor.patch" means an identity may only be claimed when
# that upstream release's content is actually IN the tree — a release that
# exists only on an upstream release branch (dapr's release-1.18 model) is
# reported as "behind", never silently skipped and never minted blind.
#
# Exports (caller sources this file):
#   derive_upstream_identity <head-ref> <upstream-url> [pattern]
#     Sets IDENTITY, REMOTE_LATEST, IDENTITY_STATE ("exact"|"behind"); rc 1
#     when no upstream release could be derived at all.
#     pattern: "auto" (default — pure vX.Y.Z / X.Y.Z across all upstream
#     tags) or an ls-remote glob for non-semver identities ("b[0-9]*").
#   next_rezus_ordinal <identity> <fork-url>
#     Echoes NN+1 for the highest existing <identity>-rezus.* tag on the
#     fork remote (0+1 = 1 for a fresh identity — the reset is intrinsic:
#     a changed upstream version has no rezus tags yet).
#   previous_anchor <fork-url>
#     Echoes the upstream identity of the fork's newest -rezus.* tag.
#
# Derivation rules (the #627 lessons, both directions):
#   - REACHABLE first: `git tag --merged <head>` — identity must be content-
#     true. The caller must have fetched tags for head's history (full clone
#     or fetch --tags).
#   - REMOTE cross-check: ls-remote against the upstream HOST (shallow
#     clones hide tags — the #601/#603 lesson class). A pure-but-stale
#     describe/reachable answer is never trusted alone: if the remote has a
#     newer release for the pattern, that is surfaced as "behind", and the
#     caller refuses to mint (exact mapping) instead of anchoring wrong
#     (the observed v1.18.0-forever / v16.0.3-forever failure).
# ============================================================================
# shellcheck shell=bash
# IDENTITY/REMOTE_LATEST/IDENTITY_STATE are the sourced-output contract —
# callers read them after derive_upstream_identity returns:
# shellcheck disable=SC2034

derive_upstream_identity() {
  local head="$1" upstream_url="$2" pattern="${3:-auto}"
  IDENTITY=""; REMOTE_LATEST=""; IDENTITY_STATE=""

  local pure_re='^-?v?[0-9]+\.[0-9]+\.[0-9]+$'
  local is_custom=0
  [ -n "$pattern" ] && [ "$pattern" != "auto" ] && is_custom=1

  # The reachable set needs upstream tags LOCALLY. Sync/mapping clones fetch
  # branches only — fetch the tag set straight from the upstream URL here so
  # no caller can derive against an empty tag universe (#601/#603 class).
  git fetch --quiet "$upstream_url" "+refs/tags/*:refs/tags/*" 2>/dev/null || \
    echo "WARNING: could not fetch upstream tags from $upstream_url — reachable identity may under-report" >&2

  # ── Reachable set: releases whose content is in the tree ────────────────
  # -rezus.* tags are the mint's OUTPUT — never identity inputs (#664): a
  # custom pattern like "v16.0.*" is start-anchored only and matches the
  # fork's own output tags on the release line, feeding an output back in as
  # the identity (observed live: identity became v16.0.5-rezus.2 and the walk
  # minted the nested v16.0.5-rezus.2-rezus.1). Filtered in BOTH branches.
  local reachable=""
  if [ "$is_custom" = 1 ]; then
    reachable=$( { git tag --merged "$head" 2>/dev/null | grep -E "^${pattern}" || true; } | { grep -v -- '-rezus\.' || true; } | sed 's/\^{}$//' | sort -V | tail -1)
  else
    reachable=$( { git tag --merged "$head" 2>/dev/null | grep -E "$pure_re" || true; } | { grep -v -- '-rezus\.' || true; } | sed 's/\^{}$//' | sort -V | tail -1)
  fi

  # ── Remote set: the authoritative upstream release line ─────────────────
  # ls-remote always sees every tag (never a shallow-fetch blind spot).
  # ^{} suffixes (annotated-tag peel entries) are deduped — sort -V on both
  # spellings of the same version keeps the base name via sed.
  local remote_raw remote_latest=""
  if [ "$is_custom" = 1 ]; then
    remote_raw=$({ git ls-remote --tags "$upstream_url" "refs/tags/${pattern}" 2>/dev/null \
      | awk -F/ '{print $NF}' | grep -E "^${pattern}$" || true; })
  else
    remote_raw=$({ git ls-remote --tags "$upstream_url" "refs/tags/*" 2>/dev/null \
      | awk -F/ '{print $NF}' | grep -E "$pure_re" || true; })
  fi
  remote_latest=$(echo "$remote_raw" | sed 's/\^{}$//' | sort -Vu | tail -1)

  if [ -z "$reachable" ] && [ -z "$remote_latest" ]; then
    return 1
  fi

  # ── Exact-mapping arbitration ───────────────────────────────────────────
  local top=""
  top=$(printf '%s\n%s\n' "$reachable" "$remote_latest" | sed '/^$/d' | sort -V | tail -1)
  IDENTITY="$top"
  REMOTE_LATEST="$remote_latest"
  if [ -n "$remote_latest" ] && [ "$top" = "$remote_latest" ] && [ "$reachable" != "$remote_latest" ]; then
    IDENTITY_STATE="behind" # newer upstream release exists; its content is NOT in the tree
  else
    IDENTITY_STATE="exact" # tree content == remote's newest release for this pattern
  fi
  return 0
}

next_rezus_ordinal() {
  local identity="$1" fork_url="$2"
  # Scoped to THIS identity: a new upstream version has no rezus tags yet,
  # so the ordinal naturally resets to 1 (#627 contract). Unpadded ordinals
  # are semver-valid; ranked numerically by any consumer (#595).
  local last_n
  last_n=$(git ls-remote --tags "$fork_url" "refs/tags/${identity}-rezus.*" 2>/dev/null \
    | awk -F/ '{print $NF}' | sed -nE 's/^[^ ]*-rezus\.([0-9]+)(\^\{\})?$/\1/p' \
    | sort -n | tail -1)
  echo "$((10#${last_n:-0} + 1))"
}

previous_anchor() {
  local fork_url="$1"
  # The upstream identity of the fork's newest existing rezus tag — the
  # anchor a mint is measured against (reset detection / staleness report).
  git ls-remote --tags "$fork_url" "refs/tags/*-rezus.*" 2>/dev/null \
    | awk -F/ '{print $NF}' | sed 's/\^{}$//' \
    | sed -E 's/-rezus\.[0-9]+.*$//' | sort -V | tail -1
}

# mint_release_tag <fork-head-ref> <identity> <fork-url> — cut+push the tag.
# Echoes the tag name; rc 1 on push failure. Refuses a HEAD that already
# carries the identity's tag (idempotent re-runs).
mint_release_tag() {
  local head="$1" identity="$2" fork_url="$3"
  local existing
  existing=$(git tag --points-at "$head" 2>/dev/null | grep -E -- "-rezus\." | head -1)
  if [ -n "$existing" ]; then
    echo "=== HEAD already tagged ($existing) — skipping mint ===" >&2
    return 0
  fi
  local tag="${identity}-rezus.$(next_rezus_ordinal "$identity" "$fork_url")"
  git tag "$tag" "$head"
  if git push --quiet origin "refs/tags/$tag" 2>&1; then
    echo "$tag"
    return 0
  fi
  echo "WARNING: failed to push tag $tag" >&2
  return 1
}
