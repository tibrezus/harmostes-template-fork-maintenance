# harmostes-template-fork-maintenance

The fork-maintenance **template repo** — first archetype of the three-tier
split (ADR-0011 amendment, phase 3a). One repo owns one pipeline end to end:
the WorkflowTemplate CR, the deterministic engine, the checks (and their
executable proofs), the conflict hooks, and the skill the resolver agent
reads.

```
template.yaml    the WorkflowTemplate CR (spec.source → THIS repo; #787)
scripts/         the engine: sync-fork.sh + mapping/subtree modes + resolver
scripts/tests/   the bash contract suites (release identity, conflict contract)
checks/          the sync gates + the go_test-gate fixture proof (testdata/)
hooks/           per-fork post-sync hooks (dapr, signoz)
skill/           the conflict resolver's SKILL.md (canonical — #606 retarget)
forks/           the fork-def SCHEMA; def DATA lives in harmostes-config
```

## What moved where

| Was | Now |
|---|---|
| `chart/fork-maintenance/**` (engine, verbatim) | this repo |
| chart values `workflowTemplates.fork-maintenance` | `template.yaml` here |
| agents-repo skill copy | canonical = `skill/` here (the agents guard retargets) |
| fork def DATA (per-project) | `harmostes-config` overlays (per env) |

The kernel chart keeps rendering its copy until the phase-4 decommission —
the flip is per-environment (dev first), and until then THIS repo's CI runs
the same suites the kernel ran, so the copies cannot drift silently.

## The fork-conflict-resolver — a COMPONENT of this workflow

This repo delivers the resolver workload (`resolver.yaml`: Service +
Deployment) alongside the engine CMs — the component-localization hard
requirement (ADR-0011 amendment 2026-11-03): every logic and workload
shape related to fork-maintenance lives HERE; the kernel chart renders
only the workflow-core unifier; deployment DECISIONS (the model,
resources) live in the config tier as patches on this resource (the
fork-maintenance Kustomization in k8s-config; render-conformance
enforces the model patch).

Roll-on-change: the resolver mounts RESOLVER-SCOPED generated CMs
(hashed names — kustomize rewrites the Deployment refs), so any engine,
skill, or extension edit in this repo rolls the resolver automatically.
The defs CM is config-tier static (same posture as the pool's).

The pinned litellm-provider extension copy (`litellm-provider/`) is
drift-guarded in CI against the kernel at the `KERNEL_CHART` tag — the
same pattern as the skill drift guard.

