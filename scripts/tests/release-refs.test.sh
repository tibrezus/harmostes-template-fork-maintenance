#!/usr/bin/env bash
# Tests for the #627 release-refs coverage — the dapr shape: upstream cuts
# releases on release-N.NN branches NEVER merged to master, so a converged
# fork must still owe the release line a merge before it can claim the
# identity. Exercises sync-fork.sh phase_merge against file:// fixtures.
#
# Run: bash chart/fork-maintenance/scripts/tests/release-refs.test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || { fail "$3 (got '$1', want '$2')"; }; }

WORK=$(mktemp -d /var/tmp/rr.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
git config --global user.email t@local >/dev/null 2>&1 || true
git config --global user.name test >/dev/null 2>&1 || true
git config --global init.defaultBranch master >/dev/null 2>&1 || true

# ── Fixture: the dapr shape ────────────────────────────────────────────────
UP="$WORK/up.git"; FORK="$WORK/fork.git"
git init -q --bare "$UP"
U="$WORK/u"; git init -q "$U"; cd "$U"
git remote add origin "$UP"
echo r1 > f && git add f && git commit -qm r1 && git tag v1.18.0
git push -q origin master refs/tags/v1.18.0
git checkout -qb release-1.18
echo fix1184 > f && git commit -qam "1.18.4 fix" && git tag v1.18.4
git push -q origin release-1.18 refs/tags/v1.18.4
git checkout -q master && echo dev > devfile && git add devfile && git commit -qm dev-work
git push -q origin master

# fork: converged on upstream master (dev-work merged) + one patch, but the
# release line is NOT merged — the post-sync converged state.
git init -q --bare "$FORK"
F="$WORK/f"; git init -q "$F"; cd "$F"
git fetch -q "$UP" master && git checkout -q -b rezus/master FETCH_HEAD
echo forkpatch > forkfile && git add forkfile && git commit -qm "fork: otel patch"
git tag v1.18.0-rezus.1
git remote add origin "$FORK"
git push -q origin rezus/master refs/tags/v1.18.0-rezus.1
git --git-dir="$FORK" symbolic-ref HEAD refs/heads/rezus/master

# ── Engine payload (staged like the worker mounts it) ──────────────────────
FM="$WORK/fm"; mkdir -p "$FM/scripts" "$FM/forks"
cp -r "$ROOT/scripts/." "$FM/scripts/"
cat > "$FM/forks/dapr.yaml" <<EOF
name: dapr
mode: merge
upstream:
  url: $UP
  branch: master
  release_refs:
    - release-1.18
fork:
  url: $FORK
  default_branch: rezus/master
  mirror_branch: master
  platform: github
  token_env: GITHUB_TOKEN
versioning:
  tag_pattern: "v*-rezus.*"
auto:
  merge: true
  release: true
EOF

cd "$FM"
export GITHUB_TOKEN=dummy-dummy
OUT=$(timeout 240 bash scripts/sync-fork.sh dapr all 2>&1)
STATUS=$?
echo "$OUT" > /var/tmp/rr-test-out.log

echo "── converged fork + pending release line"
if echo "$OUT" | grep -q "master already contained — syncing the pending release line"; then
  ok "the up-to-date skip did not eat the pending release line"
else
  fail "release-refs coverage did not run (up-to-date skip won)"
fi
if echo "$OUT" | grep -q "Merge completed cleanly"; then
  ok "the release line merged as the sync delta (clean merge)"
else
  fail "the release-line merge never completed"
fi

echo "── host PR merge simulation (file:// shim can't auto-merge)"
SYNC_BRANCH=$(git --git-dir="$FORK" for-each-ref --format='%(refname:short)' 'refs/heads/rezus/sync-*' | tail -1)
if [ -n "$SYNC_BRANCH" ]; then
  MC="$WORK/merge-clone"; rm -rf "$MC"
  git clone -q "$FORK" "$MC"
  git -C "$MC" config user.email t@local; git -C "$MC" config user.name test
  git -C "$MC" checkout -q rezus/master
  git -C "$MC" merge -q --no-ff -m "host merge (simulated)" "origin/$SYNC_BRANCH"
  git -C "$MC" push -q origin rezus/master
  ok "host merge simulated: $SYNC_BRANCH → rezus/master"
else
  fail "no sync branch pushed — the merge phase never produced one"
fi
source "$ROOT/scripts/derive-release-version.sh"
cd "$MC"
derive_upstream_identity "HEAD" "$UP"

assert_eq "$(next_rezus_ordinal v1.18.4 "$FORK")" "1" "ordinal resets at the upstream change (pre-mint)"

echo "── second sync on the converged fork: the release cut must fire"
OUT2=$(cd "$WORK" && timeout 240 bash "$FM/scripts/sync-fork.sh" dapr all 2>&1)
if echo "$OUT2" | grep -q "tagging rezus/master as v1.18.4-rezus.1"; then
  ok "converged second sync minted v1.18.4-rezus.1 (exact identity, ordinal reset)"
else
  fail "the converged second sync never cut v1.18.4-rezus.1"
  echo "$OUT2" | tail -20
fi
derive_upstream_identity "HEAD" "$UP"
assert_eq "$IDENTITY" "v1.18.4" "identity = the release line's tag"
assert_eq "$IDENTITY_STATE" "exact" "exact mapping once the line is merged"

echo ""
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
