# Conflict Resolution — Mechanical and Agentic

The sync uses the **merge model**: it runs `git merge upstream/<release-branch>` into the fork's release branch (off a `rezus/sync-<date>` branch). So every conflict is a **localized 3-way region** — `base` (merge-base), `ours` (our immutable patched version), `theirs` (upstream's new version) — where upstream *and* our patch both changed since the merge-base. This is the ideal input for an LLM resolver: a small, concrete, bounded region per file, with the patch's declared intent (the fork's wiki chapter) as the missing context. A resolution is a single edit to the sync branch that earns trust only by passing the gates; a wrong one is one `git revert -m 1`.

Upstream merges produce two kinds of conflict. They need different resolution strategies. Both resolve **on the sync branch** (never the release branch) and both must pass the full [safeguard gate chain](safeguards.md) before merge.

## Classify the conflict first

For each file with a `<<<<<<<` marker, ask one question:

> **Did upstream change the *shape* our patch depends on, or just the *surrounding text*?**

- **Surrounding text changed, our patch's intent still applies verbatim** → **mechanical**. Re-apply our lines, drop the marker. Automatable, deterministic.
- **Upstream changed the API/type/signature/contract our patch relies on** → **semantic**. Our patch may be obsolete, may need rewriting against the new API, or may be unnecessary (upstream fixed the bug). Requires understanding. This is where an agent (or human) earns its place.

## Gate 4 (patch signatures) tells you which it is, cheaply

Before reading diffs, run the signature check from the fork definition:

```bash
# for each patch: grep -c "<signature>" <file>
```

- Signature still present (correct count) → our patch survived; any remaining marker is **mechanical**. Re-apply mechanically.
- Signature absent → our patch was dropped/refactored by upstream → **semantic**. Investigate.

This is a O(files) grep, not a reasoning task. Do it first.

## Mechanical resolution (automatable)

The vast majority of conflicts are mechanical: upstream edited an unrelated part of the same file, the textual regions overlap, but our change is still valid.

```bash
# For each conflicted file, take our side (HEAD), then verify it still builds
git checkout --ours -- <file>        # keep our version of the hunk
# OR, if upstream's hunk is unrelated noise we don't want:
#   edit the file, remove the markers, keep our lines
git grep -E '^(<<<<<<<|>>>>>>>|=======) ' -- <file>   # must be empty
```

Then: rebuild, run `validate-fork.sh`. If green, push — the plugin's gate-1 marker scan and gate-5 build will confirm.

**Never** blindly `git checkout --ours` on a file with a *semantic* conflict — that silently drops upstream's fix. Gate 4 (signature) + a build must confirm our intent still holds.

## Semantic resolution (agentic protocol)

When upstream changed something our patch depends on, follow this loop. It is designed so an **agent** can drive it, but a human uses the exact same steps.

### 1. Gather the decision context (structured payload)

Assemble, for the agent (or yourself):

- The conflicting file with both sides (`git diff <merge-base> upstream/<branch> -- <file>` and `git diff <merge-base> HEAD -- <file>`).
- Our patch's **declared intent** (`description` + `signature` from `forks/<name>.yaml`).
- The function/type upstream changed (the `=======` hunk and its surrounding signatures).
- The build error if any (gate 5 output).
- Relevant tests for the patched behaviour.

### 2. Enumerate resolutions (never accept the first)

Generate 2–4 ranked options. Typical axes:

- **Port our patch** to upstream's new API (preserve the feature).
- **Adopt upstream** if it now does what our patch did (our patch becomes dead code → delete it, update the fork definition).
- **Reimplement** the feature a different way that fits the new shape.
- **Defer** — keep our patch behind a feature flag pending a larger refactor.

Each option must state a falsifiable prediction: "if I do X, the build passes and `<signature>` reappears."

### 3. Resolve, then RE-VALIDATE (gate 6 — the non-negotiable step)

Apply the chosen resolution. Then it is **just another edit to the sync branch** — it earns trust only by passing the gates:

```bash
git grep -E '^(<<<<<<<|>>>>>>>|=======) ' -- .          # gate 1: empty
bash checks/validate-fork.sh <fork> <workdir>           # gate 5: green
# for each patch: grep -c "<signature>" <file>           # gate 4: count correct
```

An agent's "I resolved it" is a claim. A green `validate-fork.sh` + intact signatures is proof. **Never mark a PR auto-mergeable after agentic resolution without re-running the gates.** This is what stops a hallucinated resolution from deploying.

### 4. Update the fork definition if the patch changed

If the resolution changed *how* the feature is expressed (new signature string, new file), update `forks/<name>.yaml` so future syncs verify the **new** signature. A stale signature makes gate 4 meaningless. Commit the definition change in the same GitOps PR or a follow-up.

### 5. Document the resolution in the PR body

State which option was chosen, why, and what was validated. The next person debugging a regression in this area needs the decision, not just the diff.

## When to escalate to a human

Escalate (label `needs-conflict-resolution`, do not auto-merge) when:

- The patch's declared intent is ambiguous and the agent can't pick a clearly-correct option (low-confidence on all enumerated resolutions).
- Upstream changed a security/auth/data-integrity boundary our patch touches — the cost of a wrong resolution is too high to automate.
- The resolution requires a coordinated change across multiple patches or the fork definition's *intent*.
- Gate 5 fails after the resolution and the agent can't tell whether the failure is the resolution being wrong or a pre-existing upstream breakage.

The escalation is a **label and a stop**, not a silent merge. The release branch is untouched either way.

## Agentic integration shape

For full automation, the sync emits a `needs-fix` payload the agent consumes:

```json
{
  "fork": "signoz",
  "sync_branch": "rezus/sync-2026-06-27",
  "conflict_files": ["pkg/authz/openfgaauthz/provider.go"],
  "patches_at_risk": [{
    "file": "...", "signature": "...", "description": "...", "status": "LOST"
  }],
  "validation_output": "...",
  "upstream_range": "<base>..<head>"
}
```

The agent runs the protocol above and pushes to the *same sync branch*. The existing PR re-runs validation; green → `auto-merge`. No special merge path — the agent is just another contributor whose edits must pass the gates.

## The invariant holds

Through every path — mechanical, agentic, or human — the release branch changes **only** when a merged PR has passed every gate. A botched resolution stays on the sync branch, labelled, until it's right. The deployed fork is never the experiment.
