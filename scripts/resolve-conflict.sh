#!/usr/bin/env bash
# =============================================================================
# resolve-conflict.sh — merge + harmostes-orchestrated agent + gate/deploy
# =============================================================================
# sync-fork.sh merges the upstream release branch into the fork's release branch
# (off a sync branch); on conflict it opens a needs-conflict-resolution PR +
# emits fork.conflict.needs-resolution. THIS script is the consumer: it REDOES
# the merge (Phase 1) and, where it conflicts, hands the work to harmostes
# (Phase 2) — a shared pi.dev RPC orchestrator (github.com/tibrezus/harmostes)
# that runs ONE warm agent session: the agent resolves the merge's localized
# 3-way regions + pushes, harmostes runs gate-resolved.sh (markers +
# validate-fork.sh + signatures), and on failure feeds the error back to the
# SAME session (the agent keeps context) up to N fixes. Only a green gate
# deploys. Then this script PR-merges the sync branch into the release + releases.
#
# This replaces the old `pi --print` + cold-reinvoke-on-failure loop: warm
# session continuation + full tool-call observability + a tool allowlist.
#
# Usage: resolve-conflict.sh <fork-name>
# Env:   ZAI_API_KEY|LLM_WIKI_ZAI_TOKEN, <host token>, RESOLVER_MODEL, SKILL_PATH,
#        MAINT_DIR, HARMOSTES (default 'harmostes'), FORK_MAINTENANCE_WIKI,
#        RESOLVER_FIX_RETRIES (default 3), RESOLVER_TIMEOUT (default 1800)
# =============================================================================
set -euo pipefail

FORK_NAME="${1:?Usage: resolve-conflict.sh <fork-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAINT_DIR="${MAINT_DIR:-$(dirname "$SCRIPT_DIR")}"
DEF_FILE="$MAINT_DIR/forks/${FORK_NAME}.yaml"
MODEL="${RESOLVER_MODEL:-zai/glm-5.2}"
SKILL_PATH="${SKILL_PATH:-$HOME/.agents/skills/fork-maintenance/SKILL.md}"
WIKI_REPO="${FORK_MAINTENANCE_WIKI:-https://github.com/rezuscloud/llm-wiki}"
HARMOSTES="${HARMOSTES:-harmostes}"

[ -f "$DEF_FILE" ] || { echo "ERROR: fork definition not found: $DEF_FILE" >&2; exit 1; }
if [ -z "${ZAI_API_KEY:-}" ] && [ -n "${LLM_WIKI_ZAI_TOKEN:-}" ]; then export ZAI_API_KEY="$LLM_WIKI_ZAI_TOKEN"; fi
[ -n "${ZAI_API_KEY:-}" ] || { echo "ERROR: ZAI_API_KEY not set" >&2; exit 1; }
command -v pi >/dev/null 2>&1 || { echo "ERROR: pi not on PATH" >&2; exit 1; }
# Resolve the harmostes binary into an ARRAY so a "python3 /path/harmostes.py"
# value word-splits correctly (a quoted scalar would be one command name →
# exit 127). Honors $HARMOSTES, else 'harmostes' on PATH, else the baked-in .py.
if [ -n "${HARMOSTES:-}" ]; then
    read -ra HARMOSTES_CMD <<<"$HARMOSTES"
elif command -v harmostes >/dev/null 2>&1; then
    HARMOSTES_CMD=(harmostes)
elif [ -x /usr/local/bin/harmostes.py ]; then
    HARMOSTES_CMD=(python3 /usr/local/bin/harmostes.py)
else
    echo "ERROR: harmostes not found" >&2; exit 1
fi

read_yaml() { yq -r "$1" "$DEF_FILE"; }
FORK_URL=$(read_yaml '.fork.url')
FORK_DEFAULT_BRANCH=$(read_yaml '.fork.default_branch')
UPSTREAM_URL=$(read_yaml '.upstream.url')
UPSTREAM_BRANCH=$(read_yaml '.upstream.branch')

# Row context (#637): the event payload carries the row (theirs/ours) + the
# stable conflict branch for mapping-table defs; legacy single-row events
# carry empty fields — fall back to the def's top-level (the degenerate
# one-row table) and the dated rezus/sync-<date> branch. One contract, every
# def shape.
# shellcheck source=scripts/conflict-event.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/conflict-event.sh"
EVENT_THEIRS=""; EVENT_OURS=""; EVENT_CONFLICT_BRANCH=""
if [ -n "${EVENT_PAYLOAD:-}" ]; then
  IFS='|' read -r EVENT_THEIRS EVENT_OURS EVENT_CONFLICT_BRANCH <<<"$(event_row_context "$EVENT_PAYLOAD")"
fi
# The payload is EXTERNAL INPUT (the resolver's /events endpoint forwards
# whatever was POSTed) — the row context is validated against the def before
# it becomes a git argument: (theirs, ours) must be a declared row (exact
# string match — payload values never interpolate into any query) and the
# branch must be exactly the row's conflict branch. Mismatch → warn + def
# fallback. (#637 review finding 3.)
if [ -n "$EVENT_THEIRS" ] || [ -n "$EVENT_OURS" ] || [ -n "$EVENT_CONFLICT_BRANCH" ]; then
  ROW_DECLARED=false
  while read -r rt ro; do
    { [ -n "$rt" ] && [ "$rt" = "$EVENT_THEIRS" ] && [ "$ro" = "$EVENT_OURS" ]; } && ROW_DECLARED=true
  done <<< "$(read_yaml '.mappings[] | .theirs + " " + .ours' 2>/dev/null || true)"
  # legacy payload shape: the def's own top-level pair is a valid "row"
  { [ "$EVENT_THEIRS" = "$UPSTREAM_BRANCH" ] && [ "$EVENT_OURS" = "$FORK_DEFAULT_BRANCH" ]; } && ROW_DECLARED=true
  BRANCH_DECLARED=false
  [ -z "$EVENT_CONFLICT_BRANCH" ] && BRANCH_DECLARED=true
  [ "$EVENT_CONFLICT_BRANCH" = "$(conflict_branch_for "$EVENT_THEIRS")" ] && BRANCH_DECLARED=true
  if [ "$ROW_DECLARED" != true ] || [ "$BRANCH_DECLARED" != true ]; then
    echo "WARNING: event row context does not match the def (theirs='$EVENT_THEIRS' ours='$EVENT_OURS' branch='$EVENT_CONFLICT_BRANCH') — discarding, falling back to the def" >&2
    EVENT_THEIRS=""; EVENT_OURS=""; EVENT_CONFLICT_BRANCH=""
  fi
fi
THEIRS="${EVENT_THEIRS:-$UPSTREAM_BRANCH}"
OURS="${EVENT_OURS:-$FORK_DEFAULT_BRANCH}"

echo "=== resolve-conflict: $FORK_NAME (merge + harmostes) ==="
source "$SCRIPT_DIR/git-host.sh"
host_setup

WORKDIR=$(mktemp -d)
WIKI_DIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR" "$WIKI_DIR"' EXIT

# ── Phase 1: clone fork + upstream + wiki; start the merge ───────────────────
echo ""
echo "=== Cloning fork + upstream ==="
git clone --depth 100 "$FORK_URL" "$WORKDIR"
cd "$WORKDIR"
git remote add upstream "$UPSTREAM_URL"
# Fetch THE ROW's branch — for a mapping row THEIRS is NOT the def's
# top-level upstream.branch, and an unfetched row ref made the redo-merge die
# as "not something we can merge"; the agent then ran on a markerless tree
# and the gate passed vacuously (#637 review finding 1). Legacy: THEIRS ==
# UPSTREAM_BRANCH — same line.
git fetch --depth 100 upstream "$THEIRS" --tags

MERGE_BASE=$(git merge-base "HEAD" "upstream/$THEIRS" 2>/dev/null || echo "")
SYNC_DATE=$(date +%Y-%m-%d)
SYNC_BRANCH="${EVENT_CONFLICT_BRANCH:-rezus/sync-${SYNC_DATE}}"

# Merge model: branch off the RELEASE line and merge upstream into it (not
# cherry-pick onto fresh upstream). This re-creates the exact conflict the plugin
# hit, so the agent resolves the real 3-way regions. With the stable per-row
# conflict branch (#637) this REPLAYS onto the branch the plugin pushed — the
# existing PR stays the single thread and gets merged, never orphaned.
git checkout -B "$SYNC_BRANCH" "$OURS"

# Clone the org wiki for the fork's intent (the "Fork Maintenance" chapter).
WIKI_PAGE=""
if git clone --depth 1 "$WIKI_REPO" "$WIKI_DIR" 2>/dev/null; then
  for cand in "wiki/entities/${FORK_NAME}.md" "wiki/concepts/${FORK_NAME}.md"; do
    [ -f "$WIKI_DIR/$cand" ] && { WIKI_PAGE="$WIKI_DIR/$cand"; break; }
  done
fi

echo ""
echo "=== Merging upstream/$THEIRS into $SYNC_BRANCH ==="
NEEDS_LLM=0
if ! git merge --no-ff --no-edit \
     -m "RZ/sync: merge upstream ${THEIRS} into ${OURS} (${SYNC_DATE})" \
     "upstream/${THEIRS}"; then
  NEEDS_LLM=1
  echo "  merge stopped on a conflict — harmostes will drive it"
else
  echo "  merge clean"
fi

# ── Phase 2: harmostes — agent task → gate → feedback-as-session-continuation ─
# harmostes drives ONE warm pi RPC session. The agent resolves the merge's 3-way
# conflict regions + pushes; harmostes runs gate-resolved.sh (markers +
# validate-fork.sh + signatures); on failure it feeds the error back to the SAME
# session up to RESOLVER_FIX_RETRIES. Exit 0 = gate green; 1 = failed after N; 2 = pi error.
if [ "$NEEDS_LLM" = "1" ]; then
  CONFLICT_FILES=$(git diff --name-only --diff-filter=U 2>/dev/null | grep -v '^$' || true)
  cat > "/tmp/resolve-${FORK_NAME}-task.txt" <<PROMPT
You are resolving a git merge conflict.

Working directory: $WORKDIR  (clone of the '$FORK_NAME' fork; on branch $SYNC_BRANCH,
mid-merge — merging upstream $THEIRS into the release line. The merge
brought upstream's delta ON TOP of our customizations; only the regions where
upstream AND our patches both changed are in conflict.)

Conflicted files right now (also see \`git status\`):
$(echo "$CONFLICT_FILES" | sed 's/^/  - /')

Intent context — READ THIS to know WHY each customization exists and how to port it:
$([ -n "$WIKI_PAGE" ] && echo "  $WIKI_PAGE  (the \"## Fork Maintenance\" chapter)" || echo "  (no wiki chapter found — infer intent from the fork definition patches + the diff)")
  Skill: $SKILL_PATH  (references/conflict-resolution.md)
  Fork definition: $DEF_FILE  (patches with signatures + descriptions)

Drive the merge to completion, in a loop:
1. Resolve every conflicted file: remove ALL <<<<<<< / ======= / >>>>>>> markers,
   porting each customization onto upstream's new shape (use the wiki intent — a
   customization whose signature no longer matches means upstream changed the API
   it depends on: port it, never drop it). \`git add\` each resolved file.
2. \`git merge --continue\` (concludes the merge with a commit). A single merge has
   one set of conflicts — if new ones appear after --continue, resolve them too.
3. Repeat 1–2 until the merge is FINISHED: \`git status\` is clean (no unmerged
   paths) AND there is no merge in progress (\`test ! -e .git/MERGE_HEAD\`).
4. Then:
       git push -f origin $SYNC_BRANCH
5. STOP. Do NOT merge into the release, open/comment on PRs, or run validation.
   Pushing the clean branch ends your work — the gate runs separately.

If a later validation gate fails (you'll be told the exact error in this same
session), fix it on $SYNC_BRANCH and push again. The release branch is sacrosanct.
PROMPT

  echo ""
  echo "=== harmostes: agent task → gate → feedback (warm pi RPC session) ==="
  set +e
  "${HARMOSTES_CMD[@]}" task \
    --skill "$SKILL_PATH" --model "$MODEL" --tools read,bash,edit,grep \
    --workdir "$WORKDIR" \
    --task-file "/tmp/resolve-${FORK_NAME}-task.txt" \
    --gate "bash '$MAINT_DIR/checks/gate-resolved.sh' '$FORK_NAME' '$WORKDIR'" \
    --max-fixes "${RESOLVER_FIX_RETRIES:-3}" \
    --log "/tmp/resolve-${FORK_NAME}-events.jsonl" \
    --timeout "${RESOLVER_TIMEOUT:-1800}"
  HARMOSTES_RC=$?
  set -e
  if [ "$HARMOSTES_RC" -ne 0 ]; then
    echo ""
    echo "=== Not resolved (harmostes exit $HARMOSTES_RC) — PR stays labelled needs-conflict-resolution ==="
    git push --quiet origin "$SYNC_BRANCH" 2>&1 || true   # push partial work for review
    exit 1
  fi
fi

# ── Phase 3: gate green — PR-merge the sync branch into the release + release ─
# (merge model: the sync branch is release + upstream merge. PR-merge it into
# the release — APPEND, never force-replace. host_pr_merge does the host-routed merge.)
git checkout --quiet "$SYNC_BRANCH" 2>/dev/null || true
git add -A 2>/dev/null || true
git diff --cached --quiet || git commit --no-edit --quiet 2>/dev/null || true
git push --quiet origin "$SYNC_BRANCH" 2>&1 || true

echo ""
echo "=== Conflicts resolved — opening PR + triggering merge ==="
host_label_create "auto-merge" 0E8A16 2>/dev/null || true
PR_URL=$(host_pr_create "$OURS" "$SYNC_BRANCH" \
  "RZ/resolve: $FORK_NAME — merge conflicts resolved by agent ($SYNC_DATE)" \
  "Upstream merge conflicts (localized 3-way regions) resolved via harmostes (pi RPC + skill + wiki intent + gate-feedback loop)." \
  "auto-merge" 2>/dev/null || echo "")
echo "  PR: ${PR_URL:-<none>} (existing conflict PR reused when open — stable branch, #637)"

host_pr_merge "$SYNC_BRANCH" >/dev/null 2>&1 || echo "WARNING: PR merge failed for $SYNC_BRANCH"

# Supersession + release mint — only when the merge actually landed, i.e. the
# release line now CONTAINS the upstream row head (ours ⊇ theirs). The
# containment check is the truth; host_pr_merge's echo is not.
git fetch --quiet origin "$OURS" 2>/dev/null || true
if git merge-base --is-ancestor "upstream/$THEIRS" "origin/$OURS" 2>/dev/null; then
  host_pr_close_conflicts "$OURS" "$SYNC_BRANCH" || true

  # #627 shared derivation — the SAME helpers phase_tag and
  # mapping_maybe_cut use (exact/behind checked against the upstream HOST,
  # ordinal reset on identity change). No private describe/ordinal math.
  # auto.release is the merge-mode key, release.auto_cut the mapping key —
  # tri-state there (true / "label-pr" / false|"none", #639). Plain // chain +
  # "off" sentinel: works on every yq v4 (the if/elif form needs a newer lexer
  # than the CI runner ships); explicit auto_cut:false lands on "off", which is
  # exactly its meaning. The case below never booleanizes "label-pr" away.
  git checkout --quiet "$OURS" 2>/dev/null || true
  git reset --hard --quiet "origin/$OURS"
  # shellcheck source=scripts/derive-release-version.sh
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/derive-release-version.sh"
  AUTO_RELEASE=$(read_yaml '(.auto.release // .release.auto_cut // "off")')
  UPSTREAM_PATTERN=$(read_yaml '.versioning.upstream_pattern // "auto"' 2>/dev/null || echo auto)
  case "$AUTO_RELEASE" in
    true)
      if derive_upstream_identity "HEAD" "$UPSTREAM_URL" "$UPSTREAM_PATTERN"; then
        if [ "$IDENTITY_STATE" = "behind" ]; then
          echo "=== NOT minting: upstream $REMOTE_LATEST content is not in $OURS (#627 exact mapping — declare upstream.release_refs or sync the release line first) ===" >&2
        elif REL=$(mint_release_tag "HEAD" "$IDENTITY" "$FORK_URL") && [ -n "${REL:-}" ]; then
          echo "=== Released $REL (identity $IDENTITY — ordinal resets on upstream change) → image build → Flux deploys ==="
        fi
      else
        echo "=== NOT minting: no upstream release derivable (#627: never mint blind) ===" >&2
      fi
      ;;
    label-pr)
      # The cut-request PR flow belongs to the mapping walk (mapping_maybe_cut);
      # say so instead of silently deferring a declared release preference.
      echo "=== No release (auto_cut=label-pr — tag deferred to the next green walk, which opens the cut-request PR) ===" >&2
      ;;
    *)
      echo "=== No release (auto_release=$AUTO_RELEASE) ===" >&2
      ;;
  esac
else
  # The resolution did NOT reach the release line (host_pr_merge failed, or a
  # re-entrant walk force-push raced the resolver's non-forced push). This is
  # NOT success: exit 1 so the subscriber/graph node sees red and the next
  # event re-escalates — green here would re-introduce the green-on-conflict
  # pattern this contract removes (#637 review round 2).
  echo "ERROR: release line does not contain upstream/$THEIRS after merge — resolution did NOT land (supersession + mint skipped)" >&2
  exit 1
fi

echo ""
echo "=== resolve-conflict complete: $FORK_NAME (merged) ==="
exit 0
