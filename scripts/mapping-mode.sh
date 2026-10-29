#!/usr/bin/env bash
# mapping-mode.sh — mode: mapping (the forgejo self-sync, in the plugin)
# =============================================================================
# Sourced by sync-fork.sh when the def carries `mode: mapping`. Reproduces
# sync.yml's mapping-table walk with plugin conventions; the equivalence
# checklist (docs/forgejo-cutover.md) is the contract this implements:
#
#   per row (theirs → ours):
#     1. ours ⊇ theirs already → no-op verdict (the common case)
#     2. merge --no-ff "RZ/sync: <theirs> → <ours> (DATE)"
#     3. validation delegate (repo-local, called with the merge-base):
#        green AND its regen output (SDK/tidy) commits on top as
#        "RZ/sync: post-merge regen for <theirs>"
#     4. direct push to ours on green — the green run IS the review
#     5. conflicts: force-push conflict/<theirs>-<date> + ONE PR labelled
#        needs-conflict-resolution (conflict-resolver machinery downstream)
#   A sync NEVER mints a version (tags: derive — deliberate cuts only).
#
# Phases: merge|all — the row walk is atomic (validate runs per-merge,
# repo-locally). gates/pr/tag are structural no-ops here: there is no PR
# to watch for clean merges, and releases are deliberate.
# =============================================================================

MAPPING_VALIDATE_CMD=$(read_yaml '.validation_command // ".github/fork/sync-validate.sh"')
# #627 identity-mapping helper — the same derivation sync mode uses.
# shellcheck source=scripts/derive-release-version.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/derive-release-version.sh"
# #627 release contract: tags mirror upstream major.minor.patch exactly,
# -rezus.NN counts addon builds on top and resets at every upstream change.
# auto_cut: true → the walk mints the tag right after a validated push
# (same semantics as sync mode's auto.release); "label-pr" → a cut-request
# PR with the correct next tag name; "none" → describe-only (anchor
# staleness is always reported, never silently aged).
RELEASE_AUTO_CUT=$(read_yaml '.release.auto_cut // "none"')
UPSTREAM_PATTERN=$(read_yaml '.versioning.upstream_pattern // "auto"')

# mapping_release_report <ours-ref> — describe the identity state for one
# row (always cheap; runs even on no-op rows so staleness is visible).
mapping_release_report() {
  local ours="$1"
  git fetch --quiet origin "+refs/tags/*:refs/tags/*" 2>/dev/null || true
  if ! derive_upstream_identity "origin/$ours" "$UPSTREAM_URL" "$UPSTREAM_PATTERN"; then
    echo "  identity: (none derivable — pattern '$UPSTREAM_PATTERN' matched no upstream release)"
    return 0
  fi
  local anchor
  anchor=$(previous_anchor "$FORK_URL")
  if [ "$IDENTITY_STATE" = "behind" ]; then
    echo "  identity: $anchor STALE — upstream $REMOTE_LATEST not in tree (release line unmapped; exact mapping blocked)"
  elif [ -n "$anchor" ] && [ "$anchor" != "$IDENTITY" ]; then
    echo "  identity: $IDENTITY (exact) — next cut re-bases: $anchor → $IDENTITY-rezus.1"
  else
    echo "  identity: $IDENTITY (exact, anchored)"
  fi
}

# mapping_maybe_cut <ours-ref> — mint or nudge per release.auto_cut after a
# validated push. Never mints a "behind" identity (exact mapping).
mapping_maybe_cut() {
  local ours="$1"
  [ "$RELEASE_AUTO_CUT" = "none" ] && { mapping_release_report "$ours"; return 0; }
  derive_upstream_identity "origin/$ours" "$UPSTREAM_URL" "$UPSTREAM_PATTERN" || return 0
  if [ "$IDENTITY_STATE" = "behind" ]; then
    echo "  NOT cutting: upstream $REMOTE_LATEST content is not in $ours (exact mapping) — map its release line first" >&2
    return 0
  fi
  local next_tag="${IDENTITY}-rezus.$(next_rezus_ordinal "$IDENTITY" "$FORK_URL")"
  if [ "$RELEASE_AUTO_CUT" = "true" ]; then
    local minted
    minted=$(mint_release_tag "origin/$ours" "$IDENTITY" "$FORK_URL") && {
      [ -n "$minted" ] && echo "  released: $minted (identity $IDENTITY — upstream-mirrored, ordinal reset on change)"
    } || echo "  WARNING: mint/push failed for $next_tag" >&2
  elif [ "$RELEASE_AUTO_CUT" = "label-pr" ]; then
    local pr_url
    pr_url=$(host_pr_create "$ours" "$ours" \
      "cut $next_tag (identity $IDENTITY re-based)" \
      "#627 contract: identity moved to $IDENTITY — deliberate cut request. Merge to release." \
      "cut-release") || echo "  (cut-request PR may already exist)"
    echo "  cut-request PR: ${pr_url:-<none>} (tag $next_tag)"
  fi
}

mapping_walk() {
  local rows theirs ours conflicted=0 changed=0 base sync_date row_n=0
  rows=$(read_yaml '.mappings[] | .theirs + " " + .ours')
  sync_date=$(date +%F)

  while read -r theirs ours; do
    [ -z "$theirs" ] && continue
    row_n=$((row_n + 1))
    echo ""
    echo "══ row: $theirs → $ours ══"

    git fetch -q upstream "$theirs" 2>/dev/null || { echo "ERROR: upstream has no $theirs" >&2; return 1; }
    git fetch -q origin "$ours"

    if git merge-base --is-ancestor "upstream/$theirs" "origin/$ours"; then
      echo "  ⊇ holds — no-op"
      mapping_release_report "$ours"
      continue
    fi

    base=$(git rev-parse "origin/$ours")
    git checkout -q -B sync-work "origin/$ours"

    if git merge --no-ff --no-edit \
         -m "RZ/sync: $theirs → $ours ($sync_date)" \
         "upstream/$theirs"; then
      echo "  merged clean — validating (repo-local delegate: $MAPPING_VALIDATE_CMD)"
      if bash "$MAPPING_VALIDATE_CMD" "$base"; then
        # Regen output (SDK/tidy) rides on top of the merge commit.
        if ! git diff --quiet || ! git diff --cached --quiet; then
          git add -A
          git commit -q -m "RZ/sync: post-merge regen for $theirs"
        fi
        git push origin "HEAD:$ours"
        changed=1
        echo "  pushed — invariant restored (dev-build fires)"
        mapping_maybe_cut "$ours"   # #627: mint/nudge per release.auto_cut
      else
        echo "ERROR: validation failed for $theirs → $ours; nothing pushed" >&2
        return 1
      fi
    else
      echo "  conflicts — concluding with markers for resolution"
      conflicted=1
      local row_conflict_files
      row_conflict_files=$(git diff --name-only --diff-filter=U 2>/dev/null | grep -v '^$' || true)
      git add -A 2>/dev/null || true
      git commit --no-edit --quiet 2>/dev/null || true
      local conflict_branch
      conflict_branch="$(conflict_branch_for "$theirs")"   # stable per row — one PR, force-updated
      git push --force-with-lease origin "HEAD:$conflict_branch"
      local pr_url
      pr_url=$(host_pr_create "$ours" "$conflict_branch" \
        "sync: $theirs → $ours needs conflict resolution" \
        "Upstream moved into files our delta touches. Resolve the 3-way regions on this branch (the rezus intent lives in our side of each marker); merging this PR restores \`ours ⊇ theirs\`. The conflict-resolver resolves this automatically." \
        needs-conflict-resolution) || echo "  (PR may already exist)"
      echo "  conflict PR: ${pr_url:-<none>} (label: needs-conflict-resolution)"
      emit_conflict_event "$row_conflict_files" "$theirs" "$ours" "$conflict_branch"
    fi
  done <<< "$rows"

  if [ "$conflicted" = "1" ]; then
    echo "::notice::one or more rows await conflict resolution (PRs above) — resolver escalated"
    [ "$PHASED" = "1" ] && result_json false "fork-sync-$FORK_NAME" merge "conflicts — resolver escalated"
    return 2   # same escalation code as legacy merge mode's conflict path (#637)
  fi
  if [ "$changed" = "1" ]; then
    [ "$PHASED" = "1" ] && result_json true "fork-sync-$FORK_NAME" merge "row(s) merged+validated+pushed"
  else
    [ "$PHASED" = "1" ] && result_json false "fork-sync-$FORK_NAME" merge "no-op — invariant holds"
  fi
  return 0
}

mapping_dispatch() {
  case "$PHASE" in
    merge|all)
      echo "=== [$PHASE] fork: $FORK_NAME (mode: mapping) ==="
      if [ "${DRY_RUN:-0}" = "1" ]; then
        echo "DRY RUN — fetch-only detect (nothing merged/pushed):"
        git ls-remote --heads "$UPSTREAM_URL" | head -5
        echo "  rows: $(read_yaml '.mappings[] | .theirs + " → " + .ours' | tr '\n' ';')"
        exit 0
      fi
      # Full-history clone: merge-base must not lie (sync.yml's fetch-depth 0).
      echo ""
      echo "=== Cloning target (FULL history) ==="
      WORKDIR=$(mktemp -d)
      git clone -q "$FORK_URL" "$WORKDIR"
      cd "$WORKDIR"
      # shellcheck source=scripts/git-host.sh
      # shellcheck disable=SC1091
      source "$SCRIPT_DIR/git-host.sh"
      host_setup
      git remote add upstream "$UPSTREAM_URL" 2>/dev/null || true
      local walk_rc=0
      mapping_walk || walk_rc=$?
      # Propagate the walk's verdict: 2 = conflict (resolver escalated), 1 =
      # validation failure — both must reach the plugin (set -e would have
      # killed the bare call; an explicit exit keeps that contract visible).
      [ "$walk_rc" -eq 0 ] || exit "$walk_rc"
      ;;
    gates|validate)
      echo "=== [$PHASE] mapping mode: validation is repo-local and runs inside the row walk — structural no-op"
      [ "$PHASED" = "1" ] && result_json false "fork-sync-$FORK_NAME" "$PHASE" "no-op (repo-local validation rides the merge phase)"
      ;;
    pr)
      echo "=== [$PHASE] mapping mode: clean merges push directly (green run IS the review); conflict PRs are opened during the walk — structural no-op"
      [ "$PHASED" = "1" ] && result_json false "fork-sync-$FORK_NAME" pr "no-op (direct push; conflict PRs ride the walk)"
      ;;
    tag)
      echo "=== [$PHASE] mapping mode: a sync NEVER mints a version — tags are deliberate cuts (tags: derive) ==="
      [ "$PHASED" = "1" ] && result_json false "fork-sync-$FORK_NAME" tag "no-op (deliberate tags only)"
      ;;
    *) echo "ERROR: unknown phase '$PHASE'" >&2; exit 1 ;;
  esac
}
