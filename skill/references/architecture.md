# Architecture — Centralised GitOps Fork Maintenance

The design goal: maintain N forks of N upstreams, each carrying added features, each continuously synced, each on a different git host, with **one** shared plugin and **zero** per-fork duplication of sync logic. The release branch of every fork stays functional at all times.

## What lives where

### Fork repos — clean, minimal

Each fork repo contains **only**: upstream code + feature patches + additive code + one tag-triggered release workflow. No maintenance scripts, no sync workflows, no manifests, no per-PR CI. Maintenance artifacts that used to live in forks (per-fork sync workflows, divergence manifests, manifest generators) were a smell — they duplicated across forks and drifted. They belong in the GitOps repo.

```text
org/<fork>/                # the fork repo (github OR codeberg)
├── (full upstream source — untouched where unpatched)
├── <additive dirs>/        # our added features (never conflict with upstream)
├── <patched upstream files>
└── .github/workflows/release.yml   # the ONLY CI file — tag-triggered build
```

### GitOps repo — all maintenance logic, version-controlled, GitOps-reconciled

```text
<gitops-repo>/platform/harmostes/fork-maintenance/
├── kustomization.yaml          # ConfigMap generators → scripts delivered GitOps-native
├── namespace.yaml
├── forks/                      # declarative fork definitions (the "what") — one per fork
│   └── <name>.yaml
├── scripts/                    # shared sync logic (the "how") — universal
│   ├── sync-fork.sh            #   merge + hook + validate + open PR
│   ├── git-host.sh             #   github | forgejo host abstraction
│   ├── generate-manifest.sh    #   diff → divergence manifest (audit)
│   ├── verify-patches.sh       #   signature grep verification
│   └── cronjob-entrypoint.sh   #   runtime tool installer
├── checks/
│   └── validate-fork.sh        # universal validation dispatcher (per-fork checks)
├── post-merge-hooks/           # per-fork post-merge logic (codegen etc.)
│   └── <name>.sh
├── manifests/                  # generated divergence manifests (audit trail)
│   └── <name>-rezus.yaml
├── skill/                      # ← CANONICAL skill (source of truth for agents)
│   ├── SKILL.md                #   synced to ~/.agents/skills/fork-maintenance/
│   ├── references/             #   architecture / safeguards / conflict-resolution
│   ├── templates/              #   portable copies of the plugin (drift-guarded)
│   └── scripts/check-drift.sh  #   verifies templates ↔ live scripts match
└── flux/                       # (or equivalent) upstream monitors + sync trigger
    ├── gitrepository-upstreams.yaml
    ├── alert-upstream-changes.yaml
    ├── cronjob-sync-forks.yaml
    └── external-secret-<host>-token.yaml
```

Scripts and definitions are delivered as **ConfigMaps** (via kustomize `configMapGenerator`). Reconciling the GitOps repo updates the ConfigMaps; the CronJob picks up the latest at runtime — no image rebuild, no git clone of the GitOps repo needed inside the job.

## The four shapes of "keep ours current with theirs"

| Shape | Example | What the plugin merges | Gate | Release |
|-------|---------|----------------------|------|---------|
| **merge fork** (fork repo, whole-tree) | dapr, signoz | upstream branch → our release branch (immutable patches as commits) | centralized checks + patch signatures | plugin tags `v*-rezus.*` (opt-in auto) |
| ~~subtree (vendored tree)~~ | *retired from the payload — no def ever shipped with it; vendored-tree forks are served by merge mode (history holds the old machinery)* | | | |
| **merge into monorepo** (mapping table, self-hosted transport) | forgejo itself (codeberg `v16.0/forgejo` → `rezus/forgejo-16`) | upstream release branch → monorepo release branch; regen + repo-local validation before push | repo-local `sync-validate.sh` (regen output committed) | deliberate tags only — a sync never mints a version |

One plugin, one severity model across all shapes: RED = automation should
already have fixed it; WARN = policy-gated human action.

## The sync chain (sequence)

```text
upstream commit
   │
   ▼
Flux GitRepository artifact updates (poll interval, e.g. 30m)
   │             ── or ──
   ▼
Alert fires → (optional) immediate sync trigger
   │
   ▼
CronJob fork-sync (every N m, in-cluster, reads ConfigMaps)
   │  for each fork definition:
   ▼
sync-fork.sh <fork>
   ├── clone fork (shallow) + add upstream remote + fetch
   ├── if upstream unchanged since merge-base → exit (nothing to do)
   ├── create rezus/sync-<date> branch off the release branch
   ├── merge upstream/<branch>
   ├── re-apply permanent divergences (deletions)         [gate 2]
   ├── run post-merge hook (codegen / tidy / strip)        [gate 3]
   ├── scan for textual conflict markers → abort if any    [gate 1]
   ├── verify patch signatures (grep)                      [gate 4]
   ├── run validate-fork.sh (this fork's declared checks)  [gate 5]
   ├── generate divergence manifest → manifests/<fork>-rezus.yaml (audit)
   ├── push sync branch
   ├── open PR (host-routed) with validation results in body
   │            label = auto-merge | needs-fix | needs-conflict-resolution
   └── if label=auto-merge AND auto.merge:                 [gate 7, opt-in]
        ├── host_pr_merge (squash + delete branch)
        └── if auto.release: tag <upstream-ver>-rezus.<N+1>
             → fork release.yml builds image → Flux image automation deploys
                │
                ▼
        human reviews (auto.merge:false) / plugin merges (auto.merge:true) / agent resolves
                │
                ▼
        PR merges → release branch advances (still functional, by construction)
```

## Branch topology

| Branch | Purpose | Content | How it changes |
|--------|---------|---------|----------------|
| `<upstream-default>` (mirror) | Clean upstream mirror | 1:1 with upstream | force-reset to upstream when stale |
| `rezus/<default>` (release) | **The deployed branch** | upstream + patches + additive | **only via merged green PR** — the GitHub/forgejo default branch so tag-triggered release fires |

The mirror exists so `git merge` has a clean upstream ref and `git describe` reaches upstream tags for versioning. It is never the merge target.

### One release line per major

Track the upstream **release/maintenance branch** (e.g. `v16.0/forgejo`), not dev `main` — release branches change slowly, so deltas are small and most merges are clean (the LLM resolver is invoked only on real conflicts). To run multiple upstream majors concurrently, keep one fork release branch per major (`rezus/forgejo-16`, `rezus/forgejo-15`, …), each with its own definition (or a `majors:` list) and synced independently. A bad sync on the staging major cannot touch production. The mirror branch tracks whichever upstream branch the fork line follows.

## Sync model: merge, not replay

The plugin **merges** the upstream release branch into the fork's release branch (off a `rezus/sync-<date>` branch that PRs back). It does **not** cherry-pick / replay customizations onto a fresh upstream. This is the right substrate for an LLM maintainer:

| Property | Merge (this design) | Replay / cherry-pick |
|---|---|---|
| Custom SHAs | immutable, append-only | re-derived each sync (new SHAs) |
| Conflict shape | localized 3-way regions (base/ours/theirs) | per-commit cherry-picks vs a moving base |
| Bad resolution | one revertible merge commit (`git revert -m 1`) | smeared across rebuilt branch |
| Accumulation | impossible (commit reachability) | real footgun (re-applied customs) |
| Bisect / cite | works across syncs | broken |

For the LLM resolver this means: a small, stable conflict surface; concrete 3-way context to reason about; a wrong call that is one revert; and — with release-branch tracking — a resolver that is rarely even invoked. Additive paths (`additive_paths`) never conflict in either model (upstream has no such paths); the model only changes how the shared tree is reconciled.

## Versioning

`v<upstream-version>-rezus.<build-number>` — e.g. `v0.127.0-rezus.2`. SemVer-compatible; the `-rezus.N` suffix sorts correctly and `git describe` works because upstream `v*` tags are reachable through the mirror.

## Multi-platform: host abstraction

`git-host.sh` is sourced by `sync-fork.sh`. Each fork declares:

```yaml
fork:
  url: <host>/org/repo
  platform: github | forgejo      # default github
  api_url: <forgejo REST base>    # forgejo only
  token_env: <env var name>       # default per platform
```

- **Git push**: identical on both — credential helper (`https://x-access-token:<token>@<host>`).
- **Labels**: `gh label create` (github) | `POST /repos/{owner}/{repo}/labels` (forgejo REST).
- **PR**: `gh pr create` (github) | `POST /repos/{owner}/{repo}/pulls` + `POST /issues/{n}/labels` (forgejo REST). Body is JSON-encoded with `jq`.
- **PR merge**: `gh pr merge --squash --delete-branch` (github) | `POST /repos/{owner}/{repo}/pulls/{n}/merge` with `{"Do":"squash",...}` (forgejo REST). Used by the opt-in auto-merge.

Adding a host (GitLab, Bitbucket…): add a `case` arm to `host_setup` / `host_label_create` / `host_pr_create` / `host_pr_merge`. One place each.

## Multi-project: validation as data

`validate-fork.sh` is a **generic dispatcher**. It reads the fork's `validation:` block and runs only the declared checks:

| Check type | Key | What it verifies |
|------------|-----|------------------|
| Toolchain | `validation.toolchain.go` | pins the exact Go minor via `GOTOOLCHAIN` (precedence: declared > `go.mod`) |
| Go build | `validation.go_build[]` | declared packages compile, per module, with the declared toolchain |
| Go test | `validation.go_test[]` | declared packages' tests pass — the BEHAVIORAL gate (#564): a signature proves the patch text survived the merge, a test proves the feature works. Declare targeted feature packages, never upstream's full suite (the gate runs per sync: fast + deterministic) |
| Clean tree | `validation.clean_tree.paths` | generated code committed matches freshly-regenerated (no codegen drift) |
| Integration | `validation.integration.kind` | opt-in harness routine (e.g. `forgejo-live`) |

Adding a language/ecosystem = adding a check type (`cargo_build`, `cmake_build`, `npm_build`, `dotnet_test`…). The dispatcher stays generic; one fork's checks never leak into another's.

**Critical**: validation output goes to a **per-fork** file (`/tmp/fork-validation-<name>.md`), never a shared path. One CronJob pod syncs many forks — a shared file is how fork A's results end up in fork B's PR body.

## Adding a new fork

1. `forks/<name>.yaml` — the definition (host, patches w/ signatures, additive paths, deletions, validation, release).
2. `post-merge-hooks/<name>.sh` — per-fork logic, or a no-op.
3. Flux `GitRepository` + `Alert` for the upstream (in `flux/`).
4. If forgejo-hosted: add the PAT to the ExternalSecret and set `fork.api_url` + `fork.token_env`.
5. Register the hook + def in `kustomization.yaml`'s `configMapGenerator`.
6. Commit + push the GitOps repo → reconcile → next run syncs the new fork.

No change to `sync-fork.sh`, `git-host.sh`, or `validate-fork.sh`. No change to the fork repo (beyond its existing patches + one `release.yml`).

## Automation model

- **Trigger**: Flux `GitRepository` polls upstream (event-driven artifact update); a `*/N m` CronJob is the executor; an `Alert` can trigger an immediate sync on upstream change. Either way, sync is automatic and regular.
- **Human action**: review + merge green PRs — **unless** the fork opts into `auto.merge: true`, in which case a green PR merges itself and (with `auto.release: true`) cuts the next release tag with no human in the loop. The centralized gates are the CI; there is no per-PR GitHub Actions to wait for.
- **Escalation**: mechanical conflicts auto-resolve; semantic conflicts are labelled `needs-fix` and resolved by a human or an agent (see [conflict-resolution.md](conflict-resolution.md)).
- **Safety**: the release branch is modified **only** by a merged PR. A broken sync cannot deploy.

## Reference implementation

`platform/harmostes/` in k8s-config is the production instance (forks: forgejo, signoz, dapr — defs live in the HelmRelease values at `platform/harmostes/gitrepository.yaml`, ADR-0011). It demonstrates the cases: a Go monorepo with codegen + integration (forgejo), a Go single-module with permanent divergence (signoz — strips `ee/`), and a Go single-module (dapr). llama.cpp was retired from tracking (k8s-config !286); the derive-release-version test keeps its b-revision fixture purely as the non-`vX.Y.Z` pattern example.
