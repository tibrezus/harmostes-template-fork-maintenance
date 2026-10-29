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
