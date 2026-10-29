#!/usr/bin/env bash
# Tests for conflict-event.sh — the unified conflict-escalation contract (#637).
# Hermetic: stubs curl/sleep via a PATH shim, a stub read_yaml, no network, no
# hosts. Covers:
#   - conflict_branch_for: stable per-row branch (NO date — the PR-pileup fix)
#   - emit_conflict_event: manifest fallback + CloudEvent shape (type/source,
#     row context, conflict branch, conflict files) + legacy empty-row shape
#     + the retry-then-warning path
#   - event_row_context: mapping-mode payload, legacy payload, garbage input
# Mutation-probed before landing (see PR).
#
# Run: bash chart/fork-maintenance/scripts/tests/conflict-contract.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../conflict-event.sh
source "$SCRIPT_DIR/conflict-event.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }
assert_eq() { # assert_eq <got> <want> <what>
  if [ "$1" = "$2" ]; then ok "$3"; else fail "$3 (got '$1', want '$2')"; fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ── conflict_branch_for: stable, date-free, slug-safe ───────────────────────
echo "# conflict_branch_for"
assert_eq "$(conflict_branch_for "v16.0/forgejo")" "conflict/v16.0-forgejo" "row slug: slashes dashed"
assert_eq "$(conflict_branch_for "master")" "conflict/master" "single-segment row"
assert_eq "$(conflict_branch_for "v16.0/forgejo")" "$(conflict_branch_for "v16.0/forgejo")" "stable across calls (same day or not)"
if conflict_branch_for "v16.0/forgejo" | grep -qE '[0-9]{4}-[0-9]{2}-[0-9]{2}'; then
  fail "branch must not embed a date (the daily-PR-pileup bug)"
else
  ok "branch embeds no date"
fi

# ── emit_conflict_event ─────────────────────────────────────────────────────
echo "# emit_conflict_event"
# Stub read_yaml (the lib calls the caller's parser — here: one declared patch,
# present and signature-intact, mirroring a healthy def).
read_yaml() {
  case "$1" in
    '.patches | length') echo 1 ;;
    '.patches[0].file') echo "$WORK/upstream.cfg" ;;
    '.patches[0].signature') echo "rezus-magic-string" ;;
    '.patches[0].description') echo "the one true patch" ;;
    *) echo 0 ;;
  esac
}
echo "keep rezus-magic-string intact" > "$WORK/upstream.cfg"

# curl/sleep shims: capture the POSTed body; no real sleeps.
SHIM="$WORK/bin"; mkdir -p "$SHIM"
cat > "$SHIM/curl" <<SHIM
#!/usr/bin/env bash
for prev in "\$0" "\${CAPTURED:-}"; do :; done
args=("\$@")
prev=""; for a in "\${args[@]}"; do if [ "\$prev" = "-d" ]; then printf '%s' "\$a" > "\$CAPTURE_FILE"; fi; prev="\$a"; done
exit \${CURL_RC:-0}
SHIM
chmod +x "$SHIM/curl"
printf '#!/bin/sh\nexit 0\n' > "$SHIM/sleep" && chmod +x "$SHIM/sleep"

export FORK_NAME=testfork
export UPSTREAM_URL="https://github.com/upstream/x"
export UPSTREAM_BRANCH="master"
export MERGE_BASE="abc123def456"
export UPSTREAM_HEAD="def456abc789"
export MAINT_DIR="$WORK"
export PATH="$SHIM:$PATH"
CAPTURE_FILE="$WORK/ce.json"
export CAPTURE_FILE

emit_conflict_event $'src/a.go\nsrc/b.go' "v16.0/forgejo" "rezus/forgejo-16" "conflict/v16.0-forgejo" >/dev/null

[ -f "$WORK/manifests/testfork-needs-fix.json" ] \
  && ok "needs-fix manifest written (audit / manual-runs fallback)" \
  || fail "needs-fix manifest missing"

assert_eq "$(jq -r '.type' "$CAPTURE_FILE")" "fork.conflict.needs-resolution" "CloudEvent type"
assert_eq "$(jq -r '.source' "$CAPTURE_FILE")" "fork-sync" "CloudEvent source"
assert_eq "$(jq -r '.data.fork' "$CAPTURE_FILE")" "testfork" "payload names the fork"
assert_eq "$(jq -r '.data.row.theirs' "$CAPTURE_FILE")" "v16.0/forgejo" "payload carries row.theirs"
assert_eq "$(jq -r '.data.row.ours' "$CAPTURE_FILE")" "rezus/forgejo-16" "payload carries row.ours"
assert_eq "$(jq -r '.data.conflict_branch' "$CAPTURE_FILE")" "conflict/v16.0-forgejo" "payload carries the conflict branch"
assert_eq "$(jq -r '.data.conflict_files | length' "$CAPTURE_FILE")" "2" "conflict files array populated"
assert_eq "$(jq -r '.data.patches_at_risk[0].status' "$CAPTURE_FILE")" "OK" "patch signature verified (OK)"
assert_eq "$(jq -r '.data.patches_at_risk[0].description' "$CAPTURE_FILE")" "the one true patch" "patch intent carried"

# Legacy call shape: no row args → empty row fields (def-fallback contract).
emit_conflict_event $'one.go' >/dev/null
assert_eq "$(jq -r '.data.row.theirs' "$CAPTURE_FILE")" "" "legacy event: empty row.theirs (def fallback)"
assert_eq "$(jq -r '.data.conflict_branch' "$CAPTURE_FILE")" "" "legacy event: empty conflict_branch"

# Retry-then-warning: resolver unreachable → emit still exits 0 (the conflict
# escalation itself is the caller's exit 2; the emit's job is warn + manifest).
CURL_RC=7 emit_conflict_event $'x.go' "t" "o" "conflict/t" > "$WORK/unreachable.out" 2>&1 \
  && ok "unreachable resolver: emit exits 0 (warning, not failure)" \
  || fail "unreachable resolver made emit fail"
grep -q "WARNING: resolver unreachable" "$WORK/unreachable.out" \
  && ok "unreachable resolver → explicit warning (manifest is the fallback)" \
  || fail "no warning on unreachable resolver"

# ── event_row_context ───────────────────────────────────────────────────────
echo "# event_row_context"
IFS='|' read -r T O B <<<"$(event_row_context '{"row":{"theirs":"v16.0/forgejo","ours":"rezus/forgejo-16"},"conflict_branch":"conflict/v16.0-forgejo","fork":"forgejo"}')"
assert_eq "${T}/${O}/${B}" "v16.0/forgejo/rezus/forgejo-16/conflict/v16.0-forgejo" "mapping-mode payload parsed"
IFS='|' read -r T O B <<<"$(event_row_context '{"fork":"dapr","conflict_files":["go.mod"]}')"
assert_eq "${T}${O}${B}" "" "legacy payload → empty row context (def fallback)"
IFS='|' read -r T O B <<<"$(event_row_context '{"row":{"theirs":"","ours":"rezus/x"}}')"
assert_eq "${T}|${O}|${B}" "|rezus/x|" "partial row: empty field survives (no shift)"
IFS='|' read -r T O B <<<"$(event_row_context 'not json at all')" ; T=${T:-x}; O=${O:-x}; B=${B:-x}
assert_eq "${T}${O}${B}" "xxx" "garbage payload → empty context, no crash"

echo ""
echo "unit: passed $PASS  failed $FAIL"

# ── mint gate def-key chain (#639) — REAL yq, no shim ───────────────────────
echo "# mint gate: auto-release def-key fallback (real yq)"
# $TD lives under $WORK — ONE EXIT trap (a second trap REPLACES the file's
# line-27 cleanup and litters /tmp with the e2e fixture, #639 finding 2).
TD="$WORK/mint"; mkdir -p "$TD"
printf 'release:\n  auto_cut: true\n' > "$TD/mapping.yaml"
printf 'auto:\n  release: true\n' > "$TD/merge.yaml"
printf 'release:\n  auto_cut: label-pr\n' > "$TD/labelpr.yaml"
printf 'release:\n  auto_cut: false\n' > "$TD/explicitoff.yaml"
printf 'foo: bar\n' > "$TD/none.yaml"
# Tri-state chain: // + "off" sentinel (runs on every yq v4 — the if/elif
# form needs a newer lexer than the CI runner's preinstalled yq ships).
# label-pr passes through untouched (#639 finding 1); an explicit
# auto_cut:false lands on "off" — exactly its meaning.
CHAIN='(.auto.release // .release.auto_cut // "off")'
# Pin the SCRIPT, not just the chain: extract the expression resolve-conflict.sh
# actually uses (the yq shim elsewhere is expression-keyed and would mask a
# regression — #639 probe 2). grep -F '.auto' skips the upstream_pattern expr.
SCRIPT_EXPR=$(sed -n "s/.*read_yaml '\([^']*\)'.*/\1/p" "$SCRIPT_DIR/resolve-conflict.sh" \
  | grep -F '.auto' | head -1)
[ "$SCRIPT_EXPR" = "$CHAIN" ] \
  && ok "resolve-conflict.sh reads the tri-state chain (script pinned)" \
  || fail "resolve-conflict.sh mint gate drifted: '$SCRIPT_EXPR'"
yq -r "$CHAIN" "$TD/mapping.yaml" | grep -qx true \
  && ok "mapping def (release.auto_cut) gates the mint on" \
  || fail "mapping def release.auto_cut not honored — resolved conflicts never mint (#639)"
yq -r "$CHAIN" "$TD/merge.yaml" | grep -qx true \
  && ok "merge def (auto.release) still gates the mint on" \
  || fail "merge-mode key regressed"
yq -r "$CHAIN" "$TD/labelpr.yaml" | grep -qx 'label-pr' \
  && ok "tri-state: label-pr passes through (never booleanized to silence)" \
  || fail "label-pr def swallowed — silent deferral (#639 finding 1)"
grep -qF 'auto_cut=label-pr — tag deferred' "$SCRIPT_DIR/resolve-conflict.sh" \
  && ok "label-pr resolves loudly (explicit deferral line, never silent)" \
  || fail "label-pr branch silent again — silent deferral regression"
yq -r "$CHAIN" "$TD/explicitoff.yaml" | grep -qx off \
  && ok "explicit auto_cut:false resolves to off (≡ false)" \
  || fail "explicit false did not resolve to off"
yq -r "$CHAIN" "$TD/none.yaml" | grep -qx off \
  && ok "defs with no release policy keep the mint off" \
  || fail "mint default must stay off"

# ══════════════════════════════════════════════════════════════════════════════
# END-TO-END: resolve-conflict.sh against a two-branch mapping fixture (#637
# review finding 1: the row ref must be fetched; finding 3: payload row context
# validated against the def). Hermetic: file:// remotes, yq/gh/harmostes shims,
# platform=local (no auth, real git merges).
# ══════════════════════════════════════════════════════════════════════════════
echo "# resolve-conflict e2e (mapping row, platform=local)"
E2E="$WORK/e2e"; mkdir -p "$E2E/maint/forks" "$E2E/bin" "$E2E/home"
UP="$E2E/upstream.git"; FORKG="$E2E/fork.git"
git init -q --bare "$UP"; git init -q --bare "$FORKG"

# Deterministic fixture commits (#674 root cause): the fork and upstream
# lines must share the SAME base commit OBJECT — the harness builds them in
# two separate repos with identical content, so the SHAs match only when
# both commits land in the same wall-clock SECOND (git's timestamp
# resolution). A second-boundary tick between the two commits (common on a
# loaded CI runner) made the histories genuinely disjoint, the resolver's
# merge died "refusing to merge unrelated histories", the agent then
# committed a PLAIN non-merge resolution, and four assertions failed
# together (row tip absent from the fork remote, parents=2, forged-row
# exit, mint line missing) — always rerun-green, never reproducible
# without the pin. Pin the clock; the fixture SHAs become stable across
# runs too. (Identity still comes from the runner's git config, set below
# via GIT_CONFIG_GLOBAL for the resolver phase.)
export GIT_AUTHOR_DATE="2026-01-01T00:00:00 +0000"
export GIT_COMMITTER_DATE="2026-01-01T00:00:00 +0000"

# upstream: row branch v16.0/forgejo carries v16.0.5 (tagged); master is a decoy
# ancestor (the def's top-level branch — what the OLD code fetched by mistake).
UWT="$E2E/u"; git init -q "$UWT"; cd "$UWT"
git remote add origin "$UP"
echo base > f.txt; git add f.txt; git commit -qm base
git branch -m master
git push -q origin master
git checkout -qb v16.0/forgejo
echo upstream-v2 > f.txt; git commit -qam "upstream moves f.txt"
git tag v16.0.5
git push -q origin v16.0/forgejo refs/tags/v16.0.5

# fork: rezus/forgejo-16 = base + our delta on the SAME line → real conflict.
FWT="$E2E/f"; git init -q "$FWT"; cd "$FWT"
git remote add origin "$FORKG"
echo base > f.txt; git add f.txt; git commit -qm base; git branch -m rezus/forgejo-16
echo our-delta > f.txt; git commit -qam "our delta"
git push -q origin rezus/forgejo-16
git -C "$FORKG" symbolic-ref HEAD refs/heads/rezus/forgejo-16

# fork def: top-level branch = master (decoy) — the ROW overrides it.
cat > "$E2E/maint/forks/forgejo-e2e.yaml" <<'YAML'
name: forgejo-e2e
upstream:
  url: PLACEHOLDER_UP
  branch: master
fork:
  url: PLACEHOLDER_FORK
  default_branch: rezus/forgejo-16
  platform: local
mappings:
  - theirs: v16.0/forgejo
    ours: rezus/forgejo-16
# MAPPING-schema release policy (#639): forgejo-class defs carry
# release.auto_cut, NOT the merge-mode auto.release — the resolver mint
# gate must honor this shape or a resolved conflict never mints.
release:
  auto_cut: true
YAML
sed -i "s|PLACEHOLDER_UP|file://$UP|; s|PLACEHOLDER_FORK|file://$FORKG|" "$E2E/maint/forks/forgejo-e2e.yaml"
ln -sfn "$SCRIPT_DIR" "$E2E/maint/scripts"          # real engine scripts
ln -sfn "$SCRIPT_DIR/../checks" "$E2E/maint/checks" # real gates

# yq shim: expression-keyed answers for the e2e def (skips CLI flags first —
# callers invoke `yq -r "expr" file`).
cat > "$E2E/bin/yq" <<SHIM
#!/usr/bin/env bash
EXPR=""
for a in "\$@"; do case "\$a" in -*) ;; *) [ -z "\$EXPR" ] && EXPR="\$a" ;; esac; done
case "\$EXPR" in
  ".fork.url // .subtree.url") echo "file://$FORKG" ;;
  ".fork.url") echo "file://$FORKG" ;;
  '.fork.platform // .subtree.platform // "github"') echo "\${E2E_PLATFORM:-local}" ;;
  ".fork.default_branch") echo "rezus/forgejo-16" ;;
  ".upstream.url") echo "file://$UP" ;;
  ".upstream.branch") echo "master" ;;
  '(.auto.release // .release.auto_cut // "off")') echo "true" ;;
  '.versioning.upstream_pattern // "auto"') echo "auto" ;;
  ".mappings[] | .theirs + \" \" + .ours") echo "v16.0/forgejo rezus/forgejo-16" ;;
  ".patches | length") echo 0 ;;
  *) echo "" ;;
esac
SHIM
# harmostes shim: plays the agent (resolve deterministically, push) then runs
# the REAL gate command.
cat > "$E2E/bin/harmostes" <<SHIM
#!/usr/bin/env bash
wd=""; gate=""; prev=""
for a in "\$@"; do
  case "\$prev" in
    --workdir) wd="\$a" ;;
    --gate) gate="\$a" ;;
  esac
  prev="\$a"
done
cd "\$wd"
printf 'resolved-upstream+delta\n' > f.txt
git add -A && git commit -qm "RZ/resolve: fixture resolution" && git push -q origin HEAD
echo "[shim-agent] resolved + pushed \$(git rev-parse --abbrev-ref HEAD)" >> "$E2E/agent.log"
eval "\$gate" >> "$E2E/agent.log" 2>&1
SHIM
chmod +x "$E2E/bin/yq" "$E2E/bin/harmostes"
# The resolver gates on credentials + the pi binary at startup even though the
# shimmed harmostes never invokes either — satisfy the checks.
printf '#!/usr/bin/env bash\nexit 0\n' > "$E2E/bin/pi" && chmod +x "$E2E/bin/pi"
export PATH="$E2E/bin:$PATH"
export MAINT_DIR="$E2E/maint" HOME="$E2E/home" GIT_CONFIG_GLOBAL="$E2E/home/.gitconfig" ZAI_API_KEY=dummy

PAYLOAD='{"fork":"forgejo-e2e","row":{"theirs":"v16.0/forgejo","ours":"rezus/forgejo-16"},"conflict_branch":"conflict/v16.0-forgejo"}'
# platform=local: host_pr_merge merges INSIDE the resolver clone and never
# pushes, so the REMOTE release line does not advance — the containment guard
# correctly refuses to claim success and the resolver exits 1 (round-2 review:
# a resolution that did not land must not report green).
EVENT_PAYLOAD="$PAYLOAD" bash "$E2E/maint/scripts/resolve-conflict.sh" forgejo-e2e > "$E2E/run.out" 2>&1 \
  && { fail "resolver must exit 1 when the resolution did not land (green-on-failure)"; } \
  || { grep -q "resolution did NOT land" "$E2E/run.out" \
        && ok "non-landing resolution: exit 1 + explicit ERROR (no green-on-failure)" \
        || { fail "exit 1 for the wrong reason"; sed -n '1,40p' "$E2E/run.out" >&2; }; }

git -C "$FORKG" rev-parse --verify -q refs/heads/conflict/v16.0-forgejo >/dev/null \
  && ok "resolution pushed to the STABLE row conflict branch" \
  || fail "conflict/v16.0-forgejo missing on the fork remote"
ROW_TIP=$(git -C "$UWT" rev-parse v16.0/forgejo)
if git -C "$FORKG" merge-base --is-ancestor "$ROW_TIP" refs/heads/conflict/v16.0-forgejo; then
  ok "redo-merge used THE ROW ref — upstream row tip contained (fetch-theirs fix)"
else
  fail "upstream row tip NOT contained in the resolution branch (fetch-theirs fix broken)"
fi
PC=$(git -C "$FORKG" rev-list --parents -n1 refs/heads/conflict/v16.0-forgejo | wc -w)
[ "$PC" = "3" ] && ok "resolution is a true two-parent merge commit" || fail "tip is not a merge commit (parents=$PC)"
CONTENT=$(git -C "$FORKG" show refs/heads/conflict/v16.0-forgejo:f.txt)
[ "$CONTENT" = "resolved-upstream+delta" ] \
  && ok "resolved content on the branch (real gate ran green)" \
  || fail "unexpected resolved content: $CONTENT"
grep -q "shim-agent" "$E2E/agent.log" && ok "harmostes agent phase ran (shim)" || fail "agent phase never ran"
grep -q "GATES GREEN" "$E2E/agent.log" && ok "REAL gate-resolved.sh green on the resolution" || fail "gate not green"
grep -q "supersession + mint skipped" "$E2E/run.out" \
  && ok "containment guard: supersession+mint skipped when the release line lacks the row" \
  || fail "containment guard did not fire"

# Negative: a FORGED payload row (not in the def) must be discarded → def
# fallback (upstream.branch=master, an ancestor → clean no-op merge, no agent).
PAYLOAD2='{"fork":"forgejo-e2e","row":{"theirs":"main","ours":"rezus/forgejo-16"},"conflict_branch":"conflict/main"}'
EVENT_PAYLOAD="$PAYLOAD2" bash "$E2E/maint/scripts/resolve-conflict.sh" forgejo-e2e > "$E2E/run2.out" 2>&1 \
  && ok "forged row: resolver exits 0 (def fallback)" || fail "forged row crashed the resolver"
grep -q "does not match the def.*falling back" "$E2E/run2.out" \
  && ok "forged row context discarded with a warning (finding 3)" \
  || fail "forged row context was trusted"
grep -qE "Merging upstream/master into" "$E2E/run2.out" \
  && ok "fell back to the def's top-level branch after discarding" \
  || fail "did not fall back to def values"
grep -q "NOT minting: upstream" "$E2E/run2.out" \
  && ok "mint gate evaluates under the mapping-schema def (behind-refusal decision line, #639)" \
  || fail "mint gate never evaluated — no decision line in resolver output"

# ── host_pr_close_conflicts (github): --arg-safe jq (finding 2) ──────────────
echo "# host_pr_close_conflicts (github, injection probe)"
test_close_conflicts() {
  export E2E_PLATFORM=github
  # shellcheck source=../git-host.sh
  source "$SCRIPT_DIR/git-host.sh"
  DEF_FILE="$E2E/maint/forks/forgejo-e2e.yaml"
  cat > "$E2E/bin/gh" <<SHIM
#!/usr/bin/env bash
echo "\$*" >> "$E2E/gh.log"
if [ "\$1 \$2" = "pr list" ]; then
  printf '%s\\n' '[{"number":148,"headRefName":"conflict/v16.0-forgejo-old"},{"number":149,"headRefName":"conflict/v16.0-forgejo"},{"number":200,"headRefName":"feature/x"}]'
fi
exit 0
SHIM
chmod +x "$E2E/bin/gh"
export FORK_URL="https://github.com/rezuscloud/forgejo-e2e"
: > "$E2E/gh.log"
host_pr_close_conflicts "rezus/forgejo-16" "conflict/v16.0-forgejo"
grep -q "pr close 148" "$E2E/gh.log" && ok "stale conflict PR 148 closed" || fail "stale PR 148 not closed"
grep -qE "pr close (149|200)" "$E2E/gh.log" && fail "close filter widened (149/200 touched)" || ok "keep_head + non-conflict PRs untouched"
# Injection probe: the breakout value from the review must NOT widen the filter.
: > "$E2E/gh.log"
host_pr_close_conflicts "rezus/forgejo-16" 'x" or "y"=="y'
# With a bogus keep BOTH conflict/* PRs are legitimately selected (neither
# equals the keep) — the property under test is that the filter can never
# reach non-conflict PRs.
grep -qE "pr close 200" "$E2E/gh.log" && fail "injection widened the filter to non-conflict PRs" \
  || ok "injection probe: filter confined to conflict/* (200 untouched)"
}
test_close_conflicts

# cleanup the e2e PATH shims so later assertions see the real tools
cd "$WORK"

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
