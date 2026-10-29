#!/usr/bin/env bash
# =============================================================================
# divergence-track.sh — deterministic fork-divergence integrity
# =============================================================================
# A fork's divergences (features it ADDS, REMOVES, or PATCHES vs upstream) are
# its identity. A sync that silently drops them ships a release branch that
# BUILDS but is MISSING A FEATURE — e.g. a cherry-pick whose agentic conflict
# resolution loses an additive path (a helm chart, licensing code, a workflow),
# or a commit the cherry-picker skipped as "already applied". The build gate
# cannot catch this: added paths are not compiled.
#
# This is the real bug behind the 2026-07-09 signoz sync: it dropped both
# `deploy/charts/signoz-community/` and `pkg/licensing/communitylicensing/`
# (restored manually in a8c0b5e3 / still-pending). `additive_paths` was DECLARED
# in the fork definition but nothing enforced it.
#
# Three deterministic passes over the git TREES (no LLM, no prose source of
# truth):
#
#   capture <workdir> <upstream-ref> <fork-ref> <out.json> [additive-file] [deletions-file]
#       Build a baseline with three fields:
#         declared  — fork-def `additive_paths` (AUTHORITATIVE intent; enters the
#                     baseline unconditionally, even if the release already lost
#                     them, so a drifted release is caught not propagated).
#         added     — auto-derived minimal fork-added roots (git tree-diff:
#                     fork has, upstream lacks). The supplement that surfaces
#                     UNDECLARED divergences a dev forgot to declare.
#         deletions — fork-def `deletions` (permanent removals). Run BEFORE sync.
#
#   reapply <workdir> <fork-ref> <baseline.json>
#       Self-heal AFTER cherry-pick: restore any declared/added root the sync
#       dropped, from the fork's release ref. Safe — these paths don't exist
#       upstream. Declared roots absent from the release too are flagged
#       unrecoverable (need a manual restore from the last-good sync branch).
#
#   verify  <workdir> <baseline.json>
#       Gate BEFORE merge/release:
#         declared  — must EXIST in the result (strict: declared ⟹ present).
#         added     — must match the fork release (git diff fork -- root empty).
#         deletions — must be ABSENT.
#       Exit 0 = intact (GREEN); 1 = divergence lost (stderr feedback, blocks
#       auto-merge & release). Last stdout line = JSON report.
#
# Why tree diffs, not commit topology: a cherry-pick-sync that squash-merges its
# PRs produces a release branch whose commit graph no longer shares recent
# upstream ancestors, so `git merge-base` drifts and `merge-base..release`
# becomes polluted with upstream commits. `git diff <upstream-tree>..<fork-tree>`
# compares TREES and is immune to this.
#
# Why declared is existence-checked but added is diff-checked: a declared path
# MUST be present (intent). An auto-detected path merely must survive verbatim
# (it's whatever the release happens to carry). If the release itself already
# lost a declared path, a diff-against-release check would false-GREEN; only a
# strict existence check catches a drifted release.
#
# MODIFIED/patched paths are NOT covered here — they use content signatures
# (Gate 4), which a human chooses for rigor.
set -euo pipefail

cmd="${1:?usage: divergence-track.sh CAPTURE|REAPPLY|VERIFY ...}"; shift
die(){ echo "[divergence-track] ERROR: $*" >&2; exit 2; }
log(){ echo "[divergence-track] $*"; }

# minimal fork-added roots from added files + the upstream directory set.
# A dir D is an "added root" iff D is absent from upstream AND D's parent IS in
# upstream (or D is a single added file whose dir exists). A 101-file chart dir
# collapses to one root.
case "$cmd" in

# ─────────────────────────────────────────────────────────────────────────────
  capture)
    workdir="${1:?workdir required}"; upstream="${2:?upstream-ref required}"
    fork="${3:?fork-ref required}"; out="${4:?out.json required}"
    additive_file="${5:-/dev/null}"   # declared additive_paths (AUTHORITATIVE)
    dels_file="${6:-/dev/null}"
    cd "$workdir"
    git rev-parse --verify -q "$upstream" >/dev/null 2>&1 || die "upstream ref not found: $upstream"
    git rev-parse --verify -q "$fork"     >/dev/null 2>&1 || die "fork ref not found: $fork"

    # ── declared additive paths (authoritative intent) ──
    mapfile -t DECLARED < <(sed 's#[[:space:]]*/$##' "$additive_file" 2>/dev/null | grep -vE '^[[:space:]]*(#|$)' || true)

    # ── auto added roots (supplement — undeclared divergences) ──
    mapfile -t ADDED_FILES < <(git diff --no-renames --name-status --diff-filter=A "$upstream" "$fork" | cut -f2)
    nfc=${#ADDED_FILES[@]}
    tmp_updirs=$(mktemp); git ls-tree -r -d --name-only "$upstream" | sort -u > "$tmp_updirs"
    in_upstream(){ grep -qxF "$1" "$tmp_updirs"; }
    declare -A rootset=()
    if [ "$nfc" -gt 0 ]; then
      for f in "${ADDED_FILES[@]}"; do
        d=$(dirname "$f"); root=""
        while true; do
          if in_upstream "$d"; then break; fi
          root="$d"
          [ "$d" = "." ] && break
          nd=$(dirname "$d"); [ "$nd" = "$d" ] && break; d="$nd"
        done
        [ -z "$root" ] && root="$f"
        [ "$root" = "." ] && continue   # repo root is never a meaningful added root
        rootset["$root"]=1
      done
    fi
    rm -f "$tmp_updirs"
    # auto-only = roots not already implied by a declared path
    declare -A declared_a=(); for p in "${DECLARED[@]}"; do declared_a["$p"]=1; done
    AUTO_ONLY=()
    for r in "${!rootset[@]}"; do
      covered=0
      for p in "${DECLARED[@]}"; do
        # r is covered if a declared path is r or an ancestor of r
        [ "$r" = "$p" ] && { covered=1; break; }
        case "$r" in "$p"/*) covered=1; break;; esac
      done
      [ "$covered" -eq 0 ] && AUTO_ONLY+=("$r")
    done
    mapfile -t AUTO_ONLY < <(printf '%s\n' "${AUTO_ONLY[@]}" | sort)

    # ── declared deletions ──
    mapfile -t DELS < <(sed 's#[[:space:]]*/$##' "$dels_file" 2>/dev/null | grep -vE '^[[:space:]]*(#|$)' || true)

    t1=$(mktemp); t2=$(mktemp); t3=$(mktemp)
    printf '%s\n' "${DECLARED[@]}" | jq -R 'select(length>0)' | jq -s '.' > "$t1"
    printf '%s\n' "${AUTO_ONLY[@]}" | jq -R 'select(length>0)' | jq -s '.' > "$t2"
    printf '%s\n' "${DELS[@]}"      | jq -R 'select(length>0)' | jq -s '.' > "$t3"
    jq -n \
      --arg fork "$fork" --arg upstream "$upstream" --arg date "$(date -u +%FT%TZ)" \
      --argjson nfc "$nfc" \
      --slurpfile declared "$t1" --slurpfile auto "$t2" --slurpfile dels "$t3" \
      '{fork:$fork, upstream:$upstream, captured_at:$date,
        declared:($declared[0]), added:($auto[0]), deletions:($dels[0]),
        summary:{declared:($declared[0]|length), added_auto:($auto[0]|length),
                 added_files:$nfc, deletions:($dels[0]|length)}}' > "$out"
    rm -f "$t1" "$t2" "$t3"
    log "captured baseline: declared=$(jq '.declared|length' "$out") auto=$(jq '.added|length' "$out") (files=$nfc) deletions=$(jq '.deletions|length' "$out") → $out"
    ;;

# ─────────────────────────────────────────────────────────────────────────────
  reapply)
    workdir="${1:?workdir required}"; fork="${2:?fork-ref required}"
    baseline="${3:?baseline.json required}"
    cd "$workdir"
    git rev-parse --verify -q "$fork" >/dev/null 2>&1 || die "fork ref not found: $fork"
    [ -f "$baseline" ] || die "baseline not found: $baseline"

    # Roots to restore = declared (missing) ∪ auto (drifted from fork).
    mapfile -t DECLARED < <(jq -r '.declared[]' "$baseline")
    mapfile -t AUTO     < <(jq -r '.added[]'    "$baseline")
    MISSING=(); UNRECOVERABLE=()
    for root in "${DECLARED[@]}"; do
      [ -e "$root" ] && continue                       # strict: declared must exist
      if git cat-file -e "${fork}:${root}" 2>/dev/null || git ls-tree "$fork" -- "$root" 2>/dev/null | grep -q .; then
        MISSING+=("$root")
      else
        UNRECOVERABLE+=("$root")   # fork release itself lost it → needs last-good
      fi
    done
    for root in "${AUTO[@]}"; do
      git diff --quiet "$fork" -- "$root" 2>/dev/null || MISSING+=("$root")
    done

    if [ "${#MISSING[@]}" -eq 0 ] && [ "${#UNRECOVERABLE[@]}" -eq 0 ]; then
      log "reapply: all divergences intact — nothing to restore"
      echo '{"restored":[],"unrecoverable":[],"status":"ok"}'; exit 0
    fi
    if [ "${#MISSING[@]}" -gt 0 ]; then
      log "reapply: ${#MISSING[@]} divergence(s) dropped — restoring from $fork:"
      for m in "${MISSING[@]}"; do echo "  + $m"; done
      git checkout "$fork" -- "${MISSING[@]}" 2>/dev/null || {
        for m in "${MISSING[@]}"; do git checkout "$fork" -- "$m" 2>/dev/null || log "WARN: could not restore $m"; done
      }
    fi
    [ "${#UNRECOVERABLE[@]}" -gt 0 ] && {
      log "reapply: ${#UNRECOVERABLE[@]} declared path(s) absent from the fork release too — CANNOT self-heal:"
      for u in "${UNRECOVERABLE[@]}"; do echo "  ! $u (restore manually from the last-good sync branch)"; done
    }
    restored=$(printf '%s\n' "${MISSING[@]}"        | jq -R 'select(length>0)' | jq -s '.')
    unrecov=$( printf '%s\n' "${UNRECOVERABLE[@]}"  | jq -R 'select(length>0)' | jq -s '.')
    jq -n --argjson r "$restored" --argjson u "$unrecov" \
      '{restored:$r, unrecoverable:$u, status:(if ($u|length)>0 then "partial" else "restored" end)}'
    ;;

# ─────────────────────────────────────────────────────────────────────────────
  verify)
    workdir="${1:?workdir required}"; baseline="${2:?baseline.json required}"
    cd "$workdir"
    [ -f "$baseline" ] || die "baseline not found: $baseline"

    mapfile -t DECLARED < <(jq -r '.declared[]'  "$baseline")
    mapfile -t AUTO     < <(jq -r '.added[]'     "$baseline")
    mapfile -t DELS     < <(jq -r '.deletions[]' "$baseline")
    fork_ref=$(jq -r '.fork' "$baseline")

    missing=(); drifted=(); back=()
    for root in "${DECLARED[@]}"; do [ -e "$root" ] || missing+=("$root"); done
    for root in "${AUTO[@]}";     do git diff --quiet "$fork_ref" -- "$root" 2>/dev/null || drifted+=("$root"); done
    for d in "${DELS[@]}"; do
      if [ -n "$(git ls-files -- "$d" 2>/dev/null)" ] || [ -e "$d" ]; then back+=("$d"); fi
    done

    if [ "${#missing[@]}" -eq 0 ] && [ "${#drifted[@]}" -eq 0 ] && [ "${#back[@]}" -eq 0 ]; then
      log "verify GREEN: ${#DECLARED[@]} declared present, ${#AUTO[@]} auto intact, ${#DELS[@]} deletion(s) absent"
      jq -n --argjson d "${#DECLARED[@]}" --argjson a "${#AUTO[@]}" \
        '{status:"green", declared_present:$d, auto_intact:$a, deletions_absent:true}'
      exit 0
    fi
    {
      echo "verify RED — divergence lost after sync:"
      [ "${#missing[@]}" -gt 0 ] && { echo "  MISSING declared additive paths (${#missing[@]}) — fork features that MUST be present:"; printf '    - %s\n' "${missing[@]}"; }
      [ "${#drifted[@]}" -gt 0 ] && { echo "  DRIFTED auto divergences (${#drifted[@]}):"; printf '    - %s\n' "${drifted[@]}"; }
      [ "${#back[@]}"    -gt 0 ] && { echo "  deletions that came back (${#back[@]}):"; printf '    - %s\n' "${back[@]}"; }
      echo "  The release branch must NOT merge without these fork features."
    } >&2
    miss=$(printf '%s\n' "${missing[@]}" | jq -R 'select(length>0)' | jq -s '.')
    drift=$(printf '%s\n' "${drifted[@]}" | jq -R 'select(length>0)' | jq -s '.')
    backj=$(printf '%s\n' "${back[@]}"    | jq -R 'select(length>0)' | jq -s '.')
    jq -n --argjson m "$miss" --argjson d "$drift" --argjson b "$backj" \
      '{status:"red", missing:$m, drifted:$d, came_back:$b}'
    exit 1
    ;;

  *) die "unknown command: $cmd (expected capture|reapply|verify)" ;;
esac
