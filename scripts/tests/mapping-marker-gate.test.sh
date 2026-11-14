#!/usr/bin/env bash
# Tests for the #627 residue: mapping-mode's clean-merge MARKER GATE.
# A merge can be "clean" (no conflicted hunks) while still carrying conflict-
# marker TEXT — an upstream commit that added a marker line merges without
# conflict. Sync mode guards this at its final assertion (sync-fork.sh);
# mapping mode pushed straight through the repo-local validation delegate,
# which may only build — the vacuous-gates class. The gate must run BEFORE
# validation and push, and refuse (rc 1, nothing pushed).
#
# Hermetic: file:// bare repos, platform: local (no auth, no API), a stub
# validation delegate that records whether it ran.
#
# Run: bash scripts/tests/mapping-marker-gate.test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }

WORK=$(mktemp -d /var/tmp/mmg.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
git config --global user.email t@local >/dev/null 2>&1 || true
git config --global user.name test >/dev/null 2>&1 || true
git config --global init.defaultBranch master >/dev/null 2>&1 || true

# ── Fixture builder: upstream release line + fork superset ─────────────────
# build_fixture <name> <upstream-extra-file-content>
#   upstream: master @ r1 (tag v1.0.0), release line v16.0/line adds a file
#   fork:     rezus/line = upstream master + one fork patch
build_fixture() {
  local name="$1" extra="$2"
  local UP="$WORK/$name-up.git" FORK="$WORK/$name-fork.git"
  git init -q --bare "$UP"
  local U="$WORK/$name-u"; git init -q "$U"
  ( cd "$U"
    git remote add origin "$UP"
    echo r1 > f && git add f && git commit -qm r1 && git tag v1.0.0
    git push -q origin master refs/tags/v1.0.0
    git checkout -qb v16.0/line
    printf '%s\n' "$extra" > upstream-new.txt
    git add upstream-new.txt && git commit -qm "upstream: new file"
    git push -q origin v16.0/line )
  git init -q --bare "$FORK"
  local F="$WORK/$name-f"; git init -q "$F"
  ( cd "$F"
    git fetch -q "$UP" master && git checkout -q -b rezus/line FETCH_HEAD
    echo forkpatch > forkfile && git add forkfile && git commit -qm "fork: patch"
    git remote add origin "$FORK"
    git push -q origin rezus/line )
  git --git-dir="$FORK" symbolic-ref HEAD refs/heads/rezus/line
  echo "$UP $FORK"
}

# stage_engine <name> <up> <fork> <delegate-body>
#   stages the engine payload like the worker mounts it; the validation
#   delegate is repo-local (the fixture writes it into the fork's tree so
#   the clone carries it) — here we point validation_command at a stub in
#   the staged payload instead, recording invocation.
stage_engine() {
  local name="$1" up="$2" fork="$3" delegate="$4"
  local FM="$WORK/$name-fm"; mkdir -p "$FM/scripts" "$FM/forks"
  cp -r "$ROOT/scripts/." "$FM/scripts/"
  cat > "$FM/stub-validate.sh" <<EOF
#!/usr/bin/env bash
echo "delegate-ran" >> "$WORK/$name-delegate.log"
$delegate
EOF
  chmod +x "$FM/stub-validate.sh"
  cat > "$FM/forks/$name.yaml" <<EOF
name: $name
mode: mapping
upstream:
  url: $up
fork:
  url: $fork
  platform: local
validation_command: $FM/stub-validate.sh
mappings:
  - theirs: v16.0/line
    ours: rezus/line
    tags: derive
versioning:
  upstream_pattern: "v1.0.*"
  tag_pattern: "v*-rezus.*"
release:
  auto_cut: none
EOF
  echo "$FM"
}

run_engine() { # run_engine <fm> <name> → echoes output, sets RC
  local FM="$1" name="$2"
  OUT=$(cd "$FM" && timeout 120 bash scripts/sync-fork.sh "$name" all 2>&1)
  RC=$?
}

fork_head() { git --git-dir="$1" rev-parse refs/heads/rezus/line; }

# ── Case 1: clean merge carrying marker TEXT must be refused ───────────────
echo "# case 1: marker text in a clean merge — refuse, nothing pushed"
read -r UP1 FORK1 <<< "$(build_fixture poisoned $'<<<<<<< HEAD\nrezus side\n=======\nupstream side\n>>>>>>> v16.0/line')"
FM1=$(stage_engine poisoned "$UP1" "$FORK1" "exit 0")
HEAD_BEFORE=$(fork_head "$FORK1")
run_engine "$FM1" poisoned
if [ "$RC" -ne 0 ]; then ok "walk refused (rc=$RC)"; else fail "walk returned 0 on a marker-carrying merge"; fi
if echo "$OUT" | grep -q "conflict markers present after a clean merge"; then
  ok "refusal names the marker gate"
else
  fail "refusal did not name the marker gate"; echo "$OUT" | tail -8
fi
if [ "$(fork_head "$FORK1")" = "$HEAD_BEFORE" ]; then
  ok "nothing pushed (fork head unchanged)"
else
  fail "fork head MOVED — the poisoned merge was pushed"
fi
if [ -f "$WORK/poisoned-delegate.log" ]; then
  fail "validation delegate ran — the gate must precede validation"
else
  ok "validation delegate never ran (gate precedes it)"
fi
if echo "$OUT" | grep -q "upstream-new.txt"; then
  ok "refusal lists the offending file"
else
  fail "refusal did not list the offending file"
fi

# ── Case 2: genuinely clean merge still flows (no false positive) ──────────
echo "# case 2: clean merge without markers — validate, push, cut report"
read -r UP2 FORK2 <<< "$(build_fixture clean "a normal upstream change")"
FM2=$(stage_engine clean "$UP2" "$FORK2" "exit 0")
HEAD_BEFORE2=$(fork_head "$FORK2")
run_engine "$FM2" clean
if [ "$RC" -eq 0 ]; then ok "walk green (rc=0)"; else fail "walk failed on a clean merge (rc=$RC)"; echo "$OUT" | tail -8; fi
if [ "$(fork_head "$FORK2")" != "$HEAD_BEFORE2" ]; then
  ok "fork head advanced (merge pushed)"
else
  fail "fork head unchanged — the clean merge was not pushed"
fi
if [ -f "$WORK/clean-delegate.log" ]; then
  ok "validation delegate ran"
else
  fail "validation delegate never ran on the clean path"
fi
if git --git-dir="$FORK2" show refs/heads/rezus/line:upstream-new.txt 2>/dev/null | grep -q "a normal upstream change"; then
  ok "upstream content landed in the fork"
else
  fail "upstream content missing from the pushed head"
fi

# ── Case 3: delegate failure still refuses (the pre-existing contract) ─────
echo "# case 3: clean merge, delegate fails — nothing pushed (unchanged contract)"
read -r UP3 FORK3 <<< "$(build_fixture delegatefail "another normal change")"
FM3=$(stage_engine delegatefail "$UP3" "$FORK3" "exit 1")
HEAD_BEFORE3=$(fork_head "$FORK3")
run_engine "$FM3" delegatefail
if [ "$RC" -ne 0 ]; then ok "walk refused on delegate failure (rc=$RC)"; else fail "walk returned 0 despite delegate failure"; fi
if [ "$(fork_head "$FORK3")" = "$HEAD_BEFORE3" ]; then
  ok "nothing pushed on delegate failure"
else
  fail "fork head moved despite delegate failure"
fi

echo ""
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]