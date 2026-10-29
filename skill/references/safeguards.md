# Safeguards — the Gate Chain

The release branch is always functional because a sync PR may merge **only** after every gate passes. Each gate is independent, falsifiable, and prevents a specific class of production failure. This document lists the gates, the failure each prevents, and the real bugs that motivated them.

## The gates (in order)

### Gate 1 — No unresolved conflict markers in file content

After `git merge`, scan for textual markers:

```bash
MARKER_FILES=$(git grep -l -E '^(<<<<<<<|>>>>>>>|=======) ' -- . 2>/dev/null || true)
[ -z "$MARKER_FILES" ] || { echo "$MARKER_FILES"; exit 2; }
```

**Why both index and content**: `git diff --name-only --diff-filter=U` reports unmerged paths at the *index* level. But the divergence-cleanup step runs `git add -A`, which **clears that unmerged state** while leaving `<<<<<<<` markers in the actual file bytes. An index-only check passes; a non-building branch ships. Always `git grep` the content.

**Prevents**: a sync PR that doesn't compile because of leftover `<<<<<<< HEAD` / `>>>>>>> upstream/main` blocks. (This shipped `pkg/authz/openfgaauthz/provider.go` broken in a real signoz sync — upstream changed a function signature, the merge conflicted, `git add -A` hid it.)

**Merge-model note**: because the plugin merges (not replays), a conflict is always a genuine 3-way region on the sync branch — there is no separate "cherry-pick accumulation" failure mode where a customization is re-applied or duplicated across syncs. Git's commit reachability tracks "is this custom already merged?" structurally, so that entire class of bug cannot occur.

### Gate 2 — Permanent divergences re-applied

Deletions declared in the fork definition (`deletions: [ee/]`) are re-deleted each sync. Additive paths (`additive_paths`) are preserved (they never conflict — pure additions).

**Prevents**: upstream re-introducing a directory we permanently remove (e.g. an enterprise `ee/` we strip for community-only builds). Without re-deletion, the merge brings it back every sync.

### Gate 3 — Post-merge hook succeeded

The per-fork hook (`post-merge-hooks/<name>.sh`) runs after the merge, before validation. It owns **code generation**: swagger → SDK/CLI, `go mod tidy`, vendoring, ee-stripping, SCIP graph generation. If the hook fails, the PR is flagged for review.

**Prevents**: stale generated code. The committed generated files must match what the generator produces from the merged source — otherwise the next human build regenerates and produces a surprise diff.

### Gate 4 — Patch signatures intact

Every feature patch declares a grep-verifiable **signature** — a proof string that confirms the patch survived the merge:

```yaml
patches:
  - file: pkg/prometheus/label.go
    signature: "case promql.String:"
```

The plugin counts occurrences after merge. Zero occurrences → the patch was lost (upstream refactored the function) → PR labelled `needs-review`, not auto-merged.

**Prevents**: a silent regression where upstream's refactor removes our fix and nobody notices because the build still passes (our code path just isn't called anymore). The signature is evidence the patch is *live*, not just present.

**Signatures must be chosen carefully**: a string unique to our change, ideally on the line our patch adds. `if ctx.Err() != nil {` is good; `return nil` is useless. Verify the signature has the expected occurrence count in a clean tree before relying on it.

### Gate 4b — Divergence integrity (additive paths + deletions, auto-derived)

Gate 4 only covers *modified* files (signatures). **Added** paths — a helm chart,
licensing code, a workflow — are not compiled, so the build gate (5) cannot see
them either. A sync that drops one ships a release that builds but is *missing
a feature*. This is the real bug behind the 2026-07-09 signoz sync, which dropped
both `deploy/charts/signoz-community/` and `pkg/licensing/communitylicensing/`
(the Flux HelmRelease went `SourceNotReady`; restored manually in a8b0b5e3 /
still-pending). `additive_paths` was declared in the fork definition but nothing
enforced it.

`divergence-track.sh` closes this with three deterministic passes over the git
*TREES* (no LLM, no prose source of truth, immune to squash/merge-base drift):

| Pass | When | What |
|------|------|------|
| `capture` | before sync | Snapshot **declared** additive paths (fork-def `additive_paths` — authoritative intent) ∪ **auto** minimal added roots (`git diff <upstream>..<fork>` — surfaces undeclared divergences) ∪ declared **deletions** → JSON baseline |
| `reapply` | after merge | **Self-heal**: restore any dropped declared/auto root from the fork's release ref. Safe — these paths don't exist upstream, so nothing can conflict |
| `verify` | gate, before merge/release | Every declared path **exists** (strict: declared ⟹ present, so a *drifted release* is caught even though a diff-against-release would false-GREEN), every auto root **matches** the release, every deletion **absent** |

**Why declared is existence-checked but auto is diff-checked**: a declared path
MUST be present (intent). An auto-detected path merely must survive verbatim. If
the release itself already lost a declared path (communitylicensing), a
diff-against-release check would false-GREEN; only strict existence catches a
drifted release — and `reapply` flags it *unrecoverable* (needs a manual restore
from the last-good sync branch) instead of silently propagating the loss.

**Prevents**: a sync dropping any added fork feature (chart, licensing, workflow,
additive module) and auto-merging/auto-releasing it. Both sync paths carry it:
`sync-fork.sh` (clean merge) and `resolve-conflict.sh` (agent-driven
resolution — the actual 07-09 path). RED ⟹ `needs-fix` / no auto-merge.

### Gate 5 — Validation passed (the checks THIS fork declares)

`validate-fork.sh` runs only the checks in the fork's `validation:` block, in a **real toolchain** (the CronJob image must match the project's build env — e.g. `golang:1.25-alpine` for a Go `1.25.x` project, not whatever Go the operator's laptop has).

- `go_build` — declared packages compile.
- `go_test` — declared feature packages' tests pass (#564 behavioral gate: a signature proves the patch text survived the merge, a test proves the feature works; packages must be declared explicitly — no `./...` fallback — and each run is bounded by an explicit `-timeout`, default 120s).
- `clean_tree` — after the hook regenerated code, `git status` shows no drift (generated == committed).
- `integration` — opt-in live harness (e.g. spin up the real server, run SDK tests).

Output → **per-fork** file → embedded in the PR body.

**Prevents**: a branch that merges cleanly but doesn't build (gate 1 only checks markers; a clean merge can still be broken by an API change upstream made consistently). This is the gate that catches semantic breakage the merge didn't flag as a conflict.

**Two production bugs this gate (and its universality) prevent**:

1. **Hardcoded validator**: an earlier `validate-fork.sh` checked `cmd/fj`, swagger codegen, and a live forgejo — forgejo's structure. Every non-forgejo fork's PR showed false `Build ❌` from checks that don't apply to it. **Lesson**: the validator is a generic dispatcher over per-fork data; it never encodes one fork's structure.
2. **Shared result file**: results written to a single `/tmp/fork-validation-results.md` were read by the next fork's PR body, so signoz's PR displayed forgejo's validation output. **Lesson**: per-fork result files, always. One pod syncing many forks must not share scratch state.

### Gate 6 — Agentic resolution re-validated

If a semantic conflict was resolved by the LLM resolver (see [conflict-resolution.md](conflict-resolution.md)), the resolution is **not trusted** — it is re-run through gates 1, 4, and 5 before the PR can be marked auto-mergeable. The LLM's "I fixed it" is a claim; a green build is proof.

**Prevents**: an agent hallucinating a resolution that looks plausible but doesn't compile, or that drops a patch. The agent's output is just another edit to the sync branch; it earns mergeability only by passing the same gates a human edit would.

## PR labels

| Label | Meaning |
|-------|---------|
| `auto-merge` | All gates green; merged automatically if `auto.merge: true`, else ready for review. |
| `needs-fix` | Validation failed (gate 5) or a conflict was auto-resolved but not yet re-validated. |
| `needs-conflict-resolution` | Gate 1 or 4 failed — unresolved markers or a lost patch; needs human/agent resolution. |

## The cardinal rule, enforced by construction

> The release branch is modified **only** by a merged PR. The sync never pushes to it directly — it pushes to `rezus/sync-<date>` and opens a PR. Therefore a broken sync (one that fails any gate) can never reach the release branch. The worst case is a stale sync PR, never a broken deployment.

This is why the invariant holds even when automation fails: the failure is contained to the PR.
