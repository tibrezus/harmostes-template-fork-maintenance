# Operations — agent interventions, backports, onboarding, automation opt-in

The rare procedures, extracted from [`SKILL.md`](../SKILL.md). The daily
ops (sync, validate, verify patches) stay there.

## Resolve a conflict automatically (agent — `resolve-conflict.sh`)

When a sync hits a conflict, the plugin emits a `fork.conflict.needs-resolution`
event with a structured `needs-fix` payload (conflicting files, patches at
risk, upstream range). The resolver — `resolve-conflict.sh <fork>` — is the
agentic consumer, also runnable standalone (locally or as a one-off Job):

```bash
# locally / as a one-off Job — needs ZAI_API_KEY + the host token + pi on PATH
MAINT_DIR=/workspace ZAI_API_KEY=… /workspace/scripts/resolve-conflict.sh forgejo
# exit 0 = resolved + deployed (merged); 1 = escalated (PR left labelled)
```

It recreates the conflict deterministically (re-merge upstream), invokes
the pi.dev harness with **this skill** + the `needs-fix` payload, then
re-runs the non-negotiable gates — marker scan, `validate-fork.sh`, patch
signatures — as **proof** (an agent's "I resolved it" is a claim; green
gates are proof). On green it pushes the sync branch and auto-merges (+
auto-releases if opted in) so the fork deploys. On failure it pushes the
partial work and leaves the PR labelled `needs-conflict-resolution` for a
human — the release branch is never the experiment. See
[conflict-resolution.md](conflict-resolution.md).
`git-host.sh` supports `platform: local` (file:// repos, no auth, merge
in-tree) so the whole loop is testable without a git host.

## Backport an upstream fix now (agent — `backport.sh`)

Backporting critical upstream fixes (security/integrity) ahead of the next
upstream release is a deterministic plugin pass:

```bash
FORK_NAME=<fork> bash scripts/backport.sh <fork> <upstream-sha> [<upstream-sha> …]
# exit 0 = backported (PR merged if auto.merge); 2 = cherry-pick conflict; 3 = push failure
```

The script verifies each SHA is on the upstream release branch, cherry-picks
with `-x` (provenance line), rewords the subject to `RZ/bp: <original>`,
runs the same non-negotiable gates (marker scan + `validate-fork.sh` +
patch signatures), and PRs into the release branch. **No release tag is
cut** — a backport only advances the branch; the next sync's auto-release
(or a manual `v*-rezus.N` tag) builds the image.

On cherry-pick conflict (exit 2) it pushes the partial branch and writes
`manifests/<fork>-needs-fix.json` — the pi agent then resolves the 3-way
regions per [conflict-resolution.md](conflict-resolution.md), rewords to
`RZ/bp:`, re-runs the gates, and pushes (gate-as-proof, same as a sync
conflict).

## Agent interventions (human touchpoints → automated equivalents)

| Human touchpoint | Here |
|------------------|------|
| Merge upstream regularly | Event-driven sync: mirror-branch push webhook → `sync-fork.sh` (no human) |
| Resolve merge conflicts | `resolve-conflict.sh`: pi agent + skill + gate-feedback loop (no human) |
| Backports of critical fixes | `backport.sh` (deterministic; agent on conflict) |
| Start the next major's release line | **Major-version transition runbook** (below) |

The agent replaces the human; the gates replace peer review.

**Major-version transition runbook** (agent-executable; every step must
pass its gate before the next):

1. **Detect.** The upstream-mirror Action auto-discovers new release
   branches (e.g. `v17.0/forgejo` appears as a mirror branch). The agent
   confirms the upstream tag (`v17.0.0`) is stable, not `-rc`.
2. **Branch.** Create `rezus/<fork>-17` from `rezus/<fork>-16` (carry the
   customizations — merge model; SHAs stay immutable), then merge
   `upstream/v17.0/<branch>` into it. Expect conflicts — resolve per
   [conflict-resolution.md](conflict-resolution.md) with `RZ/resolve:`
   provenance.
3. **Gate.** The full chain on the new branch: marker scan, divergence,
   patch signatures, `validate-fork.sh` (the fork's toolchain),
   integration.
4. **Flip.** Merge the PR, then update the *data*: fork definition
   (`upstream.branch`, `fork.default_branch`, `fork.mirror_branch`), the
   Workflow CR `source.branch` (webhook now fires on the v17 mirror), the
   GitHub default branch, and the deployed chart's image tag. Old majors
   keep their release branches — they simply stop being synced when the
   Workflow CR moves.
5. **Prove.** One webhook-triggered sync on the new line must come back
   green and cut `v17.0.0-rezus.1` before the transition is done.

## Resolve a sync PR with conflicts (manual path)

1. Pull the sync branch locally.
2. `git grep -l -E '^(<<<<<<<|>>>>>>>|=======) '` — list files with
   unresolved markers.
3. For each: decide **mechanical** (re-apply our patch) or **semantic**
   (upstream changed an API we depend on) → follow
   [conflict-resolution.md](conflict-resolution.md).
4. Resolve, `git grep` again (must be empty), rebuild, run
   `validate-fork.sh`.
5. Push to the sync branch. The PR re-runs validation and flips to
   `auto-merge` if green (and merges automatically if the fork opted in).

## Add a new fork

Edit only data + one hook. No plugin changes. See
[architecture.md](architecture.md#adding-a-new-fork) and
[`templates/fork.yaml`](../templates/fork.yaml):

1. `forks/<name>.yaml` — declarative definition (upstream, fork, host,
   patches, additive paths, deletions, validation, release, optional
   `auto:`).
2. `post-merge-hooks/<name>.sh` — per-fork logic (or a no-op).
3. Flux `GitRepository` (`flux/gitrepository-upstreams.yaml`) + `Alert`
   (`flux/alert-upstream-changes.yaml`) for the upstream.
4. Register both the hook + the def in `kustomization.yaml`'s
   `configMapGenerator`.
5. If forgejo-hosted: the PAT in your secret store + `fork.api_url`.
6. Commit the GitOps repo → Flux reconciles ConfigMaps → next sync run
   (cron or event) picks it up.

## Enable full automation for a fork

Add (or flip) the `auto:` block in `forks/<name>.yaml`:

```yaml
auto:
  merge: true      # merge the green PR immediately (no human review)
  release: true    # also tag <upstream-ver>-rezus.<N+1> → image build → Flux deploys
```

`release: true` requires `merge: true`. With both on, a green sync goes
all the way to a deployed image with no human in the loop — the
centralized gates **are** the CI (there is no per-PR GitHub Actions to
wait for). Leave `merge: false` (the default) for forks that need review.

## Keep the skill in sync with the implementation

```bash
bash skill/scripts/check-drift.sh          # verify script templates match live scripts (CI-gatable)
bash skill/scripts/check-drift.sh --sync   # regenerate verbatim templates after changing the impl
```

Then sync the canonical skill to where agents load it: `cp -r
platform/fork-maintenance/skill/* ~/.agents/skills/fork-maintenance/`.
