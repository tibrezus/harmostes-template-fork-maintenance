# Vendored-tree mode (subtree sources)

Some upstreams aren't forked — they're **vendored** inside a monorepo at a
pinned version (`runner/`, `charts/forgejo/` in the forgejo monorepo).
Same plugin, `mode: subtree` in the fork def; the sync unit is
*(target repo, vendored path, pin file)* and the plugin never edits
vendored content itself.

## Decision model (priority order — only the patch class auto-merges, ever)

1. **patch** — newest tag in the pin's own `major.minor` lane → auto PR +
   auto-merge *only after the PR's CI is green* (never red)
2. **minor** — newest tag in the pin's major → prepared PR, **manual
   merge** + validation contract (changelog/CVE review, smoke dispatch)
3. **major** — advisory only, never the bump (upstream majors are
   evaluations)

## Gate flavors

- **pristine** (no `patches_file`) — byte-diff vs the upstream archive;
  EOL normalization is policy, not drift.
- **patch-accounting** (`subtree.patches_file`) — a contract in the
  TARGET repo: `preserve:` paths — verified *present*, a vanished
  preserve entry is invisible to a diff — plus `patches:` entries each
  carrying a signature. The same contract file is read by the target
  repo's CI guard: one source of truth.

OCI upstreams (`oci://…`) list tags via the v2 registry API and probe
with `helm pull`.

**Releases are structural**: a subtree bump rides the target repo's own
release cycle (`v*-rezus.*`); the plugin never tags — its tag phase
reports `unreleased-pending` until the release ships. `DRY_RUN=1` runs
the full decision path with zero writes — the onboarding rehearsal.

## Operations (all data, in `forks/<name>.yaml`)

| Operation | How |
|-----------|-----|
| bump (patch) | nothing — the plugin auto-PRs and auto-merges on CI green |
| bump (minor) | nothing — the plugin prepares the PR; review + validation contract, merge manually |
| bump (major) | deliberate: change the pin lane by hand (edit the pin file), then the plugin resumes patch mechanics |
| add a patch | edit the target repo's contract (`PATCHES.yaml`): add `patches:` entry with signature; apply in the sync delegate |
| change policy | edit the `policy:` matrix (propagate/merge per class) |
| drift triage | CI guard RED → re-vendor via the delegate (mechanical); WARN stale entry → drop or justify the contract entry |
| escape hatch | a subtree outgrowing vendoring moves to a fork repo: change the def from `mode: subtree` to merge-mode (data change) |

## Onboarding a new vendored source (the whole recipe)

pin file in the target repo → sync delegate (takes `<tag>`, writes the
pin) → CI guard reading the contract → CR with `mode: subtree`
(+ `patches_file` if patch-carrying) → `DRY_RUN=1` rehearsal → wire the
schedule.
