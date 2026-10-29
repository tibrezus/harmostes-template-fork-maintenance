#!/usr/bin/env bash
# Tests for derive-release-version.sh — the #627 upstream-identity contract.
# Hermetic: builds throwaway upstream/fork repos over file:// remotes, so no
# network and no credentials. Mutation-probed before landing (see PR).
#
# Run: bash chart/fork-maintenance/scripts/tests/derive-release-version.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../derive-release-version.sh
source "$SCRIPT_DIR/derive-release-version.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }
assert_eq() { # assert_eq <got> <want> <what>
  if [ "$1" = "$2" ]; then ok "$3"; else fail "$3 (got '$1', want '$2')"; fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

git config --global user.email t@local >/dev/null 2>&1 || true
git config --global user.name test >/dev/null 2>&1 || true
git config --global init.defaultBranch master >/dev/null 2>&1 || true

# ── Fixtures ────────────────────────────────────────────────────────────────
# upstream: master carries v1.18.0 only; v1.18.1..v1.18.4 are cut on the
# release-1.18 branch (the dapr model — releases never merged to master).
UP="$WORK/upstream.git"; FORK="$WORK/fork.git"
git init -q --bare "$UP"; git init -q --bare "$FORK"
U="$WORK/u-wt"; git init -q "$U"; cd "$U"
git remote add origin "$UP"
echo r1 > f; git add f; git commit -qm r1; git tag v1.18.0
git push -q origin master
git checkout -qb release-1.18
echo r2 > f; git commit -qam r2; git tag v1.18.1
echo r3 > f; git commit -qam r3; git tag v1.18.4
git push -q origin release-1.18 refs/tags/v1.18.1 refs/tags/v1.18.4
git checkout -q master
echo dev > devfile; git add devfile; git commit -qm dev-work   # master moved past v1.18.0
git push -q origin master

# fork: descends from upstream master (a real fork), carries rezus tags for
# the OLD identity only (the pre-#627 world).
F="$WORK/f-wt"; git init -q "$F"; cd "$F"
git fetch -q "$UP" master
git checkout -q -b master FETCH_HEAD
git remote add origin "$FORK"
echo forkpiece > forkfile; git add forkfile; git commit -qm base
git push -q origin master
git tag v1.18.0-rezus.7
echo addon1 > g; git add g; git commit -qm addon
git tag v1.18.0-rezus.8
git push -q origin master refs/tags/v1.18.0-rezus.7 refs/tags/v1.18.0-rezus.8

echo "── identity derivation (the dapr shape: releases off-branch)"
derive_upstream_identity "origin/master" "$UP"
assert_eq "$IDENTITY_STATE" "behind" "release-only content reported behind, never claimed"
assert_eq "$REMOTE_LATEST" "v1.18.4" "remote latest seen through ls-remote (no shallow blind spot)"
assert_eq "$IDENTITY" "v1.18.4" "identity names the newest release, flagged not mintable"

echo "── after the release line is merged: exact mapping"
git fetch -q "$UP" "+refs/heads/release-1.18:refs/heads/release-1.18"
git merge -q --no-ff --no-edit refs/heads/release-1.18
git push -q origin HEAD:master
derive_upstream_identity "origin/master" "$UP"
assert_eq "$IDENTITY_STATE" "exact" "merged release line maps exactly"
assert_eq "$IDENTITY" "v1.18.4" "identity = highest release in tree"

echo "── ordinal reset at the upstream change (the contract core)"
assert_eq "$(next_rezus_ordinal v1.18.4 "$FORK")" "1" "new upstream identity resets ordinal to 1"
assert_eq "$(next_rezus_ordinal v1.18.0 "$FORK")" "9" "unchanged identity keeps counting (8+1)"
assert_eq "$(previous_anchor "$FORK")" "v1.18.0" "previous anchor = the stale identity"

echo "── mint is reset-aware and idempotent"
TAG=$(mint_release_tag "origin/master" "v1.18.4" "$FORK")
assert_eq "$TAG" "v1.18.4-rezus.1" "minted tag mirrors upstream m.m.p with a fresh ordinal"
TAG2=$(mint_release_tag "origin/master" "v1.18.4" "$FORK")
assert_eq "$TAG2" "" "re-mint on a tagged head is a no-op"
assert_eq "$(next_rezus_ordinal v1.18.4 "$FORK")" "2" "post-mint ordinal advances"

echo "── custom pattern (llama.cpp b-revision model)"
git checkout -qb b-branch
for n in 100 101; do echo "b$n" >> bf; git add bf; git commit -qm "b$n"; git tag "b$n"; done
git push -q origin b-branch refs/tags/b100 refs/tags/b101
derive_upstream_identity "origin/b-branch" "$UP" "b[0-9]*"
assert_eq "$IDENTITY" "b101" "pattern glob maps non-semver identities"
assert_eq "$IDENTITY_STATE" "exact" "custom-pattern state derives"

echo "── #664: the mint's own -rezus.* output tags never become the identity"
# A custom pattern like "v16.0.*" is start-anchored only; with a rezus tag on
# the release line the reachable scan used to pick IT as the identity and mint
# the nested v16.0.5-rezus.2-rezus.1 (live: forgejo, 2026-10-09).
git checkout -qb rezus-line
echo r1 > rf; git add rf; git commit -qm r1
git tag "v1.18.4-rezus.2"           # an output tag the pattern would prefix-match
if derive_upstream_identity "HEAD" "$UP" "v1.18.*"; then
  assert_eq "$IDENTITY" "v1.18.4" "rezus output tag excluded — identity stays the upstream release"
  assert_eq "$IDENTITY_STATE" "exact" "state still derives (fixture line contains the release)"
else
  fail "derive must succeed with the rezus output tag filtered out"
fi
git tag -d "v1.18.4-rezus.2" >/dev/null

echo "── no upstream releases at all: refuse to derive"
BARE="$WORK/empty.git"; git init -q --bare "$BARE"
git checkout -q --orphan orph 2>/dev/null
git rm -rqf . 2>/dev/null || true
echo x > x; git add x; git commit -qm orph
if derive_upstream_identity "HEAD" "$BARE" 2>/dev/null; then
  fail "no-release upstream must fail derivation"
else
  ok "no-release upstream refuses derivation"
fi

echo ""
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
