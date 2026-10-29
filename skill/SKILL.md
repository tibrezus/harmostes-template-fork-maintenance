---
name: fork-maintenance
description: Maintain forks of upstream projects that carry added features — keep them continuously synced with upstream, automatically, across multiple git hosts (GitHub, Forgejo/Gitea/Codeberg) and multiple projects, while guaranteeing the deployed release branch is always functional. Everything lands via a PR with a safeguard chain (merge-clean, textual conflict-marker scan, post-merge codegen, patch signatures, real build + codegen-drift + integration validation) so only working code merges. Forks can opt into full auto-merge + auto-release (green PR → merged → tagged → image built → deployed by Flux image automation, no human in the loop). Use when setting up or operating fork sync, resolving a sync PR/conflict, debugging "why does our fork drift / fail to build / show another fork's errors", or designing automated/agentic upstream-sync for any forked repo.
---

# Fork Maintenance — Universal Upstream Sync with an Always-Functional Release Branch

This skill maintains **forks that add features on top of an upstream project** and must stay current with upstream — *without ever breaking the deployed release branch*. The cardinal invariant, non-negotiable:

> **The release branch (`rezus/<default>` / `main` / your default) is always buildable and deployable. Every change lands through a PR. Only PRs that pass every safeguard gate merge — and only then can an opt-in auto-merge/auto-release fire.**

The process is **universal** along two axes:

- **Multi-platform** — the fork repo can live on GitHub, Forgejo, Gitea, or Codeberg. Git push, labels, PR creation, **and PR merge** dispatch to the right host API (`gh` CLI vs Forgejo REST — no `tea` dep).
- **Multi-project** — one shared sync implementation + validator serves every fork. Per-fork differences are *data* (a declarative fork definition), not code. New language? new host? new build system? — add a check type or a host routine, never fork the plugin.

Sync uses the **merge model** — the plugin merges the upstream release branch into the fork's release branch (see [Sync model](#sync-model-merge--an-llm-maintainer) below). Conflicts are therefore **localized 3-way regions** (base / ours / theirs), resolved **automatically** when mechanical and via an **LLM-driven agentic protocol** when semantic (upstream changed an API our patch depends on). Either way the resolution lands in the PR for review — never directly on the release branch.

**The canonical source of truth for this skill is co-located with the reference implementation** at `platform/harmostes/fork-maintenance/skill/` in the GitOps repo that owns the maintenance system. The live scripts live one directory up (`scripts/`, `checks/`, `flux/`). `skill/scripts/check-drift.sh` verifies the skill's script templates stay byte-identical to the live scripts, so what an agent reads always matches what the CronJob runs. The copy in `~/.agents/skills/fork-maintenance/` is a synced derivative for agents to load; change the canonical one and re-sync.

## The two-branch topology (load this into your head first)

Every fork has exactly two branches (per major — see below):

| Branch | Role | Mutability |
|--------|------|------------|
| `<upstream-release>` (mirror) | Clean 1:1 upstream mirror, read-only reference | Force-reset to upstream when needed |
| `rezus/<default>` (release) | Upstream + feature patches + additive code. **This is the GitHub default branch** so tag-triggered release workflows fire here. **Always functional.** | Only via merged, green PR |

There is no third branch. You never commit to the release branch directly.

**Branch-per-major:** the release branch is named for the upstream major it tracks (`rezus/forgejo-16`), and each major gets its own release line synced independently — a bad sync on the staging major cannot touch production. A new upstream major spawns a NEW branch; it never rebases the old one (see [Major-version transition](#agent-interventions) below).

## The generic model (read this first)

Fork maintenance is a **mapping table**: rows map `theirs → ours`
(e.g. `v16.0/forgejo → rezus/forgejo-16`). The invariant per row:
`ours ⊇ theirs`. Sync restores it; release derives identities across it
(theirs = identity, ours = ordinal; stable tags cut deliberately).
Operations are ROW operations: add (major upgrade = new row + one merge
of the old ours + green proof), edit, delete. The registry defs in
`forks/` state the table; transports execute it.

- **forgejo**: self-hosted — `.github/workflows/sync.yml` in the fork
  repo walks the table daily; dev-build + Flux ImagePolicy roll prod.
  Engine politely declines mapping defs (`sync-fork.sh forgejo` → exit 0).
- **dapr / signoz**: plugin transport (phase mode below).

## Version identity (upstream-identity versioning)

**The fork mints no version of its own. Identity is the upstream version; everything else is provenance.**

- **The binary reports the upstream version** it is based on (`16.0.2`), never a fork-branded one. There are no hand-edited version files, no hand-bumped build counters, no `16.0.2-rezuscloud.3`.
- **`v*-rezus.N` tags are release TRIGGERS, not identities.** The sync's auto-release cuts them machine-computed (`<upstream-ver>-rezus.<N+1>` from `git describe`). The release workflow derives everything from the tag: identity `16.0.2`, provenance `+rezus.N` (semver *build metadata* — ignored for precedence and identity), docker-hyphen-encoded `16.0.2-rezus.N` (docker forbids `+`), plus a fingerprint tag `16.0.2-rezus.N-<shortsha>`.
- **"What's different vs upstream?" is answered by provenance, not version**: `git log v16.0.2..rezus/forgejo-16 --grep '^RZ/'` (see the commit convention below) plus the structural tools (additive paths, patch signatures).

## Commit convention (RZ/)

Every commit the maintenance system (or its agents) creates on a release branch carries an `RZ/` subject prefix:

| Prefix | Who | Meaning |
|--------|-----|---------|
| `RZ/sync:` | sync plugin | an upstream merge appended to the release line |
| `RZ/bp:` | `backport.sh` / agent | an upstream commit cherry-picked ahead of the next upstream release — carries `(cherry picked from commit …)` |
| `RZ/resolve:` | conflict-resolver agent | conflict resolution on a sync/backport branch |
| `RZ/feat:` / `RZ/fix:` | humans | new fork customizations |

The convention applies to NEW commits (existing history is immutable — merge model). It makes the fork's delta machine-queryable (`--grep '^RZ/'`) and self-explaining in `git log`.

## Sync model: merge + an LLM maintainer

The plugin **merges** the upstream release branch into the fork's release branch — it does **not** cherry-pick / replay customizations onto a fresh upstream. This is the correct substrate for an LLM doing the maintenance:

```bash
git checkout -b rezus/sync-<date> rezus/<default>   # branch off the release line
git merge --no-ff upstream/<branch>                  # append upstream's delta
# …gates… → PR rezus/sync-<date> → rezus/<default>
```

**Why merge (not replay):**

- **Immutable customizations.** Our patches live on the release branch with stable SHAs. Each sync appends an upstream merge; SHAs never change → append-only, bisectable, citable. (Replay re-derives the branch each sync → new SHAs, history churn, and an accumulation footgun.)
- **Localized, well-defined conflicts.** A merge only conflicts where upstream *and* our patch changed the same region since the merge-base — small, precise 3-way regions (`base` / `ours` / `theirs`). Replay forces per-commit cherry-pick resolution against a moving base.
- **Mistakes are isolated & revertible.** A bad resolution is one merge commit → `git revert -m 1`. In a replay a bad resolution is smeared across a rebuilt branch.
- **No accumulation.** Git's commit reachability answers "is this custom already applied?" structurally — the whole class of re-applying/duplicating customizations cannot occur.

**Why this is ideal for an LLM maintainer:** the conflict surface is small and stable, the 3-way context is concrete (the LLM reads base/ours/theirs + each patch's declared intent), a wrong call is one revert, and — because we track **release branches** (below) — most merges are *clean*, so the LLM is invoked only on the rare real conflict. On conflict the LLM resolver ([`resolve-conflict.sh`](templates/resolve-conflict.sh)) re-creates the exact merge and resolves the 3-way regions from the fork's wiki chapter, then re-runs the gates as **proof** before merge (gate 6).

**Track release branches, not main; one release line per major.** Point `upstream.branch` at the upstream **release/maintenance branch** (e.g. `v16.0/forgejo`), not the dev `main`. Release branches change slowly → smaller, stabler deltas → fewer conflicts → fewer chances for the LLM to err. To support multiple upstream majors concurrently, keep **one fork release branch per major** (`rezus/forgejo-16`, `rezus/forgejo-15`, …), each tracking its release branch and synced independently — a bad sync on the staging major cannot touch production. (A fork that must track `main` can still merge `main`; the safety properties of merge hold regardless — release-branch tracking just adds stability.)

## When to use this skill

- "Set up automatic upstream sync for our fork of X"
- "Our fork is behind upstream / drifted / fails to build after a sync"
- "A sync PR has conflicts / failed validation — resolve it"
- "Backport this upstream security fix to our release branch"
- "Upstream cut a new major — transition the fork to it"
- "One fork's PR shows another fork's validation errors" (cross-contamination bug — see [Safeguards](references/safeguards.md))
- "Add a new fork to the maintenance system"
- "Enable auto-merge / auto-release for a fork" (opt-in via `auto.merge`/`auto.release`)
- "Move a fork to a different git host" (GitHub → Codeberg or vice versa)
- "The skill drifted from the implementation" → run `skill/scripts/check-drift.sh`

## The invariant, restated as a gate chain

A sync PR may merge only after **all** gates pass, in order. Each gate is a separate, independently-falsifiable check. See [references/safeguards.md](references/safeguards.md) for the rationale and failure modes.

1. **Merge applied cleanly** — no unresolved conflict markers in file content (not just the git index — see gotcha below).
2. **Permanent divergences re-applied** — deleted upstream dirs re-deleted; additive paths preserved.
3. **Post-merge hook succeeded** — per-fork code generation (SDK regen, swagger, `go mod tidy`, ee-stripping) ran and produced the expected artifacts.
4. **Patch signatures intact** — every feature patch's grep-verifiable proof string is still present (a merge didn't silently drop it).
5. **Validation passed** — the checks *this fork* declares (go_build / go_test / clean_tree / integration), built with the **fork's declared toolchain**, all green, run in a real toolchain.
6. **(Agentic) conflict resolved & re-validated** — if a semantic conflict required agent resolution, the resolution itself was validated before the PR is marked auto-mergeable.
7. **(Opt-in) Auto-merge + auto-release** — if all above pass *and* `auto.merge: true`, the plugin merges the PR immediately; if `auto.release: true` it also cuts the next machine tag `<upstream-ver>-rezus.<N+1>` so the fork's tag-triggered workflow builds an image that Flux image automation deploys (identity = upstream version; see [Version identity](#version-identity-upstream-identity-versioning)).

**The single most important gotcha** (it has shipped broken branches in production): after a conflicted merge, the divergence-cleanup step does `git add -A`, which **clears git's unmerged-path state** (`git diff --diff-filter=U` finds nothing) but **leaves `<<<<<<<` / `=======` / `>>>>>>>` markers in the file content**. The index-based conflict check passes and a non-building branch gets pushed. `sync-fork.sh` therefore *also* `git grep`s for textual markers regardless of index state. This is gate 1.

## Operating commands

These assume the reference implementation in `platform/fork-maintenance/` of the GitOps repo that owns the maintenance system. The skill's [`templates/`](templates/) are portable starting points; the live plugin is `scripts/` + `checks/` + `flux/` (one directory up from this skill).

### Sync one fork now (manual)

```bash
# Run the sync plugin for one fork, locally or via a one-off Job
FORK_NAME=<fork> bash scripts/sync-fork.sh <fork>          # all phases (legacy single-shot)
FORK_NAME=<fork> bash scripts/sync-fork.sh <fork> <phase> # one phase (see below)
# all-mode exit codes: 0 = up to date or PR opened (auto-merged if auto.merge); 2 = conflict; 3 = push failure
```

**Phase mode (graph-native workflows).** The plugin is phase-addressable —
`merge | hook | gates | validate | pr | tag` — and graph-native fork-maintenance
workflows run each phase as its own harmostes node (`plugin fork-sync <fork>
<phase>`). Phases share the clone via `HARMOSTES_WORKDIR/fork-<name>` and pass
state through `.git/harmostes-state.env`. Phase semantics:

| Phase | green | red |
|---|---|---|
| `merge` | `changed:true` merged / `changed:false` no-op (node skipped) | exit 2 conflict → `when:failed` edge → external resolver node |
| `hook` | codegen complete | failed node |
| `gates` | divergence + patches intact | pushes needs-fix PR, then fails honestly |
| `validate` | declared checks green | failed node |
| `pr` | `changed:true` merged / `changed:false` left for review | push failure |
| `tag` | machine-cuts `v<upstream>-rezus.<N+1>` (version from the upstream host; `describe` output must be pure `vX.Y.Z`) | no release |

Phased `merge` reads the **local mirror branch** (the alias remote), never the
upstream host — the mirror action + webhook are the only upstream conduit.

To trigger in-cluster, annotate the Workflow (`harmostes.dev/trigger-revision`)
or push to the fork's mirror branch; watch nodes in the UI (Map/Attempts).

### Validate a fork locally (the same plugin the CronJob uses)

```bash
bash checks/validate-fork.sh <fork> <path-to-fork-checkout>
# exit 0 = all declared checks pass; stdout is a markdown block embedded in the PR body
```

Validate reads the fork's `validation:` block and runs **only** the checks that fork declares. A fork with no checks (e.g. a non-Go project) passes cleanly. It honors `validation.toolchain.go` (precedence: declared > `go.mod`) via `GOTOOLCHAIN` so the build uses the exact Go minor the fork pins.

### Verify patches independently

```bash
bash scripts/verify-patches.sh forks/<fork>.yaml <path-to-fork-checkout>
# exit 0 = all signatures present; 1 = some lost (needs re-application)
```

### Resolve a conflict automatically (agent — `resolve-conflict.sh`)

When a sync hits a conflict, the plugin now emits a `fork.conflict.needs-resolution`
event with a structured `needs-fix` payload (conflicting files, patches at risk,
upstream range). The resolver — `resolve-conflict.sh <fork>` — is the agentic
consumer of that event, and is also runnable standalone (locally or as a
one-off Job):

```bash
# locally / as a one-off Job — needs ZAI_API_KEY + the host token + pi on PATH
MAINT_DIR=/workspace ZAI_API_KEY=… /workspace/scripts/resolve-conflict.sh forgejo
# exit 0 = resolved + deployed (merged); 1 = escalated (PR left labelled)
```

It recreates the conflict deterministically (re-merge upstream), invokes the
pi.dev harness with **this skill** + the `needs-fix` payload, then re-runs the
non-negotiable gates — marker scan, `validate-fork.sh`, patch signatures — as
**proof** (an agent's "I resolved it" is a claim; green gates are proof). On
green it pushes the sync branch and auto-merges (+ auto-releases if opted in) so
the fork deploys. On failure it pushes the partial work and leaves the PR
labelled `needs-conflict-resolution` for a human — the release branch is never
the experiment. See [references/conflict-resolution.md](references/conflict-resolution.md).

`git-host.sh` supports `platform: local` (file:// repos, no auth, merge in-tree)
so the whole loop is testable without a git host.

### Backport an upstream fix now (agent — `backport.sh`)

Backporting critical upstream fixes (security/integrity) ahead of the next
upstream release is a deterministic plugin pass:

```bash
FORK_NAME=<fork> bash scripts/backport.sh <fork> <upstream-sha> [<upstream-sha> …]
# exit 0 = backported (PR merged if auto.merge); 2 = cherry-pick conflict; 3 = push failure
```

The script verifies each SHA is on the upstream release branch, cherry-picks
with `-x` (provenance line), rewords the subject to `RZ/bp: <original>`, runs
the same non-negotiable gates (marker scan + `validate-fork.sh` + patch
signatures), and PRs into the release branch. **No release tag is cut** — a
backport only advances the branch; the next sync's auto-release (or a manual
`v*-rezus.N` tag) builds the image.

On cherry-pick conflict (exit 2) it pushes the partial branch and writes
`manifests/<fork>-needs-fix.json` — the pi agent then resolves the 3-way
regions per [references/conflict-resolution.md](references/conflict-resolution.md),
rewords to `RZ/bp:`, re-runs the gates, and pushes (gate-as-proof, same as a
sync conflict).

### Agent interventions

Upstream maintenance has four human touchpoints. In this system each has an
automated or agent-driven equivalent — **the agent replaces the human, the gates
replace peer review**:

| Human touchpoint | Here |
|------------------|------|
| Merge upstream regularly | Event-driven sync: mirror-branch push webhook → `sync-fork.sh` (no human) |
| Resolve merge conflicts | `resolve-conflict.sh`: pi agent + skill + gate-feedback loop (no human) |
| Backports of critical fixes | `backport.sh` (deterministic; agent on conflict) |
| Start the next major's release line | **Major-version transition runbook** (agent, below) |

**Major-version transition runbook** (agent-executable; every step must pass
its gate before the next):

1. **Detect.** The upstream-mirror Action auto-discovers new release branches
   (e.g. `v17.0/forgejo` appears as a mirror branch). The agent confirms the
   upstream tag (`v17.0.0`) is stable, not `-rc`.
2. **Branch.** Create `rezus/<fork>-17` from `rezus/<fork>-16` (carry the
   customizations — merge model; SHAs stay immutable), then merge
   `upstream/v17.0/<branch>` into it. Expect conflicts — resolve per
   [references/conflict-resolution.md](references/conflict-resolution.md)
   with `RZ/resolve:` provenance.
3. **Gate.** The full chain on the new branch: marker scan, divergence,
   patch signatures, `validate-fork.sh` (the fork's toolchain), integration.
4. **Flip.** Merge the PR, then update the *data*: fork definition
   (`upstream.branch`, `fork.default_branch`, `fork.mirror_branch`), the
   Workflow CR `source.branch` (webhook now fires on the v17 mirror), the
   GitHub default branch, and the deployed chart's image tag. Old majors keep
   their release branches — they simply stop
   being synced when the Workflow CR moves.
5. **Prove.** One webhook-triggered sync on the new line must come back green
   and cut `v17.0.0-rezus.1` before the transition is declared done.

### Resolve a sync PR with conflicts

1. Pull the sync branch locally.
2. `git grep -l -E '^(<<<<<<<|>>>>>>>|=======) '` — list files with unresolved markers.
3. For each: decide **mechanical** (re-apply our patch) or **semantic** (upstream changed an API we depend on) → follow [references/conflict-resolution.md](references/conflict-resolution.md).
4. Resolve, `git grep` again (must be empty), rebuild, run `validate-fork.sh`.
5. Push to the sync branch. The PR re-runs validation and flips to `auto-merge` if green (and merges automatically if the fork opted in).

### Add a new fork

Edit only data + one hook. No plugin changes. See [references/architecture.md](references/architecture.md#adding-a-new-fork) and [`templates/fork.yaml`](templates/fork.yaml):

1. `forks/<name>.yaml` — declarative definition (upstream, fork, host, patches, additive paths, deletions, validation, release, optional `auto:`).
2. `post-merge-hooks/<name>.sh` — per-fork logic (or a no-op).
3. Flux `GitRepository` (`flux/gitrepository-upstreams.yaml`) + `Alert` (`flux/alert-upstream-changes.yaml`) for the upstream.
4. Register both the hook + the def in `kustomization.yaml`'s `configMapGenerator`.
5. If forgejo-hosted: the PAT in your secret store + `fork.api_url`.
6. Commit the GitOps repo → Flux reconciles ConfigMaps → next sync run (cron or event) picks it up.

### Enable full automation for a fork

Add (or flip) the `auto:` block in `forks/<name>.yaml`:

```yaml
auto:
  merge: true      # merge the green PR immediately (no human review)
  release: true    # also tag <upstream-ver>-rezus.<N+1> → image build → Flux deploys
```

`release: true` requires `merge: true`. With both on, a green sync goes all the way to a deployed image with no human in the loop — the centralized gates **are** the CI (there is no per-PR GitHub Actions to wait for). Leave `merge: false` (the default) for forks that need review.

### Keep the skill in sync with the implementation

```bash
bash skill/scripts/check-drift.sh          # verify script templates match live scripts (CI-gatable)
bash skill/scripts/check-drift.sh --sync   # regenerate verbatim templates after changing the impl
```

Then sync the canonical skill to where agents load it: `cp -r platform/fork-maintenance/skill/* ~/.agents/skills/fork-maintenance/`.

## The fork definition (single source of truth)

Every per-fork difference is data here. This is what makes the process multi-project. Full annotated template: [`templates/fork.yaml`](templates/fork.yaml).

```yaml
name: <fork>
upstream:  { url, branch }
fork:
  url: https://github.com/org/repo        # or codeberg.org/...
  default_branch: rezus/<default>-<major> # branch-per-major (rezus/forgejo-16); GitHub default
  mirror_branch: <release-branch>        # clean upstream mirror
  platform: github                        # github | forgejo  ← multi-platform
  api_url: https://codeberg.org/api/v1    # forgejo only (REST base)
  token_env: GITHUB_TOKEN                 # env var holding the host PAT
versioning: { tag_pattern: "v*-rezus.*" } # machine-cut release TRIGGERS — identity is the upstream version (see Version identity)
auto: { merge: false, release: false }    # opt-in full automation (see above)
patches:                                  # feature patches, each grep-verifiable
  - { file, description, signature }
additive_paths: [...]                     # our code that never conflicts with upstream
deletions: [ee/]                          # permanent divergence (re-deleted each sync)
post_merge_hook: post-merge-hooks/<name>.sh
release: { dockerfiles, multi_arch, image_registry, chart_registry, build_cli, version_file }
validation:                               # ← multi-project: declare YOUR checks
  toolchain: { go: "1.25.7" }             # pin Go minor (precedence: declared > go.mod)
  go_build:   [{ module, packages }]
  go_test:    [{ module, packages }]   # behavioral gate (#564): declare TARGETED
                                       # feature packages, never upstream's suite
                                       # (fast + deterministic — runs every sync)
  clean_tree: { paths: [...] }
  integration: { kind: forgejo-live, image, module, env }
```

## How the plugin stays universal

- **Host abstraction** (`scripts/git-host.sh` → [`templates/git-host.sh`](templates/git-host.sh)): each fork declares `platform`; `sync-fork.sh` sources it. Git push = credential helper (both hosts). Labels + PRs + **PR merge** = `gh` CLI (github) or REST API via `curl` (forgejo). Adding a host = one `case` arm in `host_setup`/`host_label_create`/`host_pr_create`/`host_pr_merge`.
- **Universal validator** (`checks/validate-fork.sh` → [`templates/validate-fork.sh`](templates/validate-fork.sh)): a generic dispatcher over the `validation:` block, with **per-fork toolchain** pinning. Adding a language = adding a check type (`go_build`, `cargo_build`, `cmake_build`, …). Never hardcode one fork's structure into the validator — that was the bug that made every non-reference fork's PR show the reference fork's errors (results leaked via a shared temp file).
- **Per-fork result files**: validation output goes to `/tmp/fork-validation-<name>.md`, never a shared path. One CronJob pod runs many forks — they must not read each other's results.
- **Patch verifier** (`scripts/verify-patches.sh` → [`templates/verify-patches.sh`](templates/verify-patches.sh)): standalone signature grep, usable outside a full sync.
- **Agentic escalation**: when a merge conflicts, the plugin emits a structured `fork.conflict.needs-resolution` event (Dapr pub/sub when a sidecar is present, else a `manifests/<fork>-needs-fix.json` file). `resolve-conflict.sh` consumes it: it recreates the conflict, invokes pi with this skill + the payload, and re-validates before deploying. See [references/conflict-resolution.md](references/conflict-resolution.md).

## Automation model

Sync is **automatic and regular**: a Flux `GitRepository` polls each upstream (event-driven artifact update); a `*/30 * * * *` CronJob is the executor; an `Alert` can trigger an immediate sync on upstream change. Scripts + definitions are delivered as **ConfigMaps** (`configMapGenerator` in `kustomization.yaml`) — Flux reconciles them on push, no image rebuild or git clone of the GitOps repo inside the job. The GitHub PAT comes from Bitwarden via `ExternalSecrets`.

Depending on the fork's `auto:` settings, a green sync PR either:

- **`auto.merge: false` (default)** — sits for human review/merge.
- **`auto.merge: true`** — merges immediately, and with `auto.release: true` cuts the next machine tag `<upstream-ver>-rezus.<N+1>`. The release workflow derives the pure-upstream VERSION + `+rezus.N` provenance from the tag (identity = upstream) and builds an image that Flux image automation can deploy. **Fully hands-off — no human ever types a version.**

The release branch is touched *only* by a merged PR, so a broken sync can never deploy.

## Deep references (load on demand)

- [**references/architecture.md**](references/architecture.md) — full design: what lives where (fork repo stays clean; maintenance logic centralised in GitOps), the sync chain sequence, branch topology, versioning, the ConfigMap delivery model.
- [**references/safeguards.md**](references/safeguards.md) — the gate chain in depth, each gate's failure mode and the production bugs it prevents (forgejo-hardcoded validator, shared-result-file leak, `git add -A` masking markers, the `ry`/`read_yaml` typo that silently disabled auto-merge).
- [**references/conflict-resolution.md**](references/conflict-resolution.md) — mechanical vs semantic conflicts, the agentic resolution protocol, the resolution-validation loop, when to escalate to a human.

## Templates (portable starting points)

Engine (verbatim copies of the live scripts — drift-guarded by `skill/scripts/check-drift.sh`):

- [`templates/sync-fork.sh`](templates/sync-fork.sh) — universal sync plugin (merge → hook → validate → verify patches → PR → auto-merge/release)
- [`templates/git-host.sh`](templates/git-host.sh) — github | forgejo host abstraction incl. `host_pr_merge`
- [`templates/validate-fork.sh`](templates/validate-fork.sh) — universal validation dispatcher + per-fork toolchain
- [`templates/verify-patches.sh`](templates/verify-patches.sh) — standalone patch-signature verifier
- [`templates/generate-manifest.sh`](templates/generate-manifest.sh) — divergence manifest generator (audit trail)
- [`templates/cronjob-entrypoint.sh`](templates/cronjob-entrypoint.sh) — CronJob entrypoint (installs tools, runs syncs)
- [`templates/cronjob-sync-forks.yaml`](templates/cronjob-sync-forks.yaml) — the CronJob (ConfigMap-mounted scripts)
- [`templates/external-secret-github.yaml`](templates/external-secret-github.yaml) — GitHub PAT from Bitwarden

Generic (hand-maintained examples, not verbatim copies):

- [`templates/fork.yaml`](templates/fork.yaml) — annotated fork definition (with `auto:` + toolchain)
- [`templates/post-merge-hook.sh`](templates/post-merge-hook.sh) — per-fork hook skeleton
- [`templates/alert-upstream-changes.yaml`](templates/alert-upstream-changes.yaml) — Flux Alert + Provider (one per fork)
- [`templates/gitrepository-upstreams.yaml`](templates/gitrepository-upstreams.yaml) — Flux GitRepository (one per fork)

## Checklist before declaring a sync "done"

- [ ] Sync branch pushed; PR open against the **release** branch (not mirror)
- [ ] No `<<<<<<<`/`>>>>>>>` markers anywhere in the tree (gate 1)
- [ ] All declared patch signatures present (gate 4) — PR body says `all-intact`
- [ ] `validate-fork.sh` green for *this* fork, in a real toolchain, with the declared toolchain (gate 5)
- [ ] Engine commits carry their `RZ/` prefix (`RZ/sync:` / `RZ/bp:` / `RZ/resolve:`)
- [ ] PR label is `auto-merge` (or `needs-fix`/`needs-conflict-resolution` with a clear reason if not)
- [ ] If `auto.merge: true`: PR merged by the plugin; release branch still functional
- [ ] If `auto.release: true`: next machine tag `<upstream-ver>-rezus.<N+1>` pushed; release derives pure-upstream VERSION from it; image build triggered
- [ ] Release branch untouched by the sync run (only the PR — or the auto-merge — can change it)
- [ ] If agentic resolution was used: the resolution was re-validated, not trusted (gate 6)
- [ ] No hand-edited version anywhere (identity = upstream version; counters are machine-cut)
