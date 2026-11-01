#!/usr/bin/env bash
# Tests for GROUP defs (kind: group) — org-level fork maintenance with
# exclusions. Exercises the group dispatcher in sync-fork.sh:
#   discovery (stubbed host enumeration) → exclude/include filtering →
#   per-member def resolution (own file wins; synthesis from defaults +
#   upstream_map; skip-loud when unmapped) → outcome aggregation →
#   worst-outcome exit contract → aggregate PluginResult final line.
#
# Members are STUBBED (HARMOSTES_SYNC_CHILD) — no clones, no hosts: the
# stub echoes the child's view (its HARMOSTES_FORK_DEF) and a scripted
# outcome. The bootstrap path (real git) is covered by its own fixture.
#
# Run: bash scripts/tests/group-defs.test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || { fail "$3 (got '$1', want '$2')"; }; }
assert_contains() { grep -qF -- "$1" <<<"$2" && ok "$3" || { fail "$3 (missing '$1')"; }; }

WORK=$(mktemp -d /var/tmp/grp.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
MAINT="$WORK/maint"
mkdir -p "$MAINT/scripts" "$MAINT/checks" "$MAINT/forks"
cp "$ROOT/scripts/sync-fork.sh" "$ROOT/scripts/git-host.sh" "$MAINT/scripts/"
cp "$ROOT/checks/validate-fork.sh" "$MAINT/checks/"

# ── Fixture: the rezusforks group def ─────────────────────────────────────
cat > "$MAINT/forks/rezusforks.yaml" <<'EOF'
name: rezusforks
kind: group
group:
  platform: github
  org: rezusforks
  exclude:
    - external-dns
  upstream_map:
    cilium:
      url: https://github.com/cilium/cilium
      branch: main
defaults:
  fork:
    platform: github
    token_env: GITHUB_TOKEN
  versioning:
    tag_pattern: "v*-rezus.*"
  auto:
    merge: false
    release: false
EOF

# a REAL member def (composition check: it must WIN over defaults/synthesis)
cat > "$MAINT/forks/signoz.yaml" <<'EOF'
name: signoz
upstream:
  url: https://github.com/SigNoz/signoz
  branch: main
fork:
  url: https://github.com/rezusforks/signoz
  default_branch: rezus/main
  platform: github
  token_env: GITHUB_TOKEN
auto:
  merge: false
  release: false
EOF
cat > "$MAINT/forks/dapr.yaml" <<'EOF'
name: dapr
upstream:
  url: https://github.com/dapr/dapr
  branch: master
fork:
  url: https://github.com/rezusforks/dapr
  default_branch: rezus/master
  platform: github
  token_env: GITHUB_TOKEN
versioning:
  tag_pattern: "v*-rezus.*"
auto:
  merge: true
  release: true
validation:
  go_test:
    - module: .
      packages: [./pkg/metrics]
EOF

# stub gh: enumerate the org exactly as the API would (emulating `gh api -q`
# — the engine's query extracts bare names; the stub reproduces that contract).
# notafork is a non-fork repo the REAL gh would filter; the stub never emits it.
mkdir "$WORK/bin"
cat > "$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [ "$2" = "orgs/rezusforks/repos" ]; then
  echo cilium
  echo dapr
  echo external-dns   # the exclusion under test
  echo signoz
  exit 0
fi
if [ "$1" = "api" ] && [ "$2" = "orgs/rezusforks2/repos" ]; then
  echo cilium
  echo dapr
  echo orphan         # no def, no upstream_map → the skip-loud case
  exit 0
fi
exit 1
EOF
chmod +x "$WORK/bin/gh"

run_group() { PATH="$WORK/bin:$PATH" bash "$MAINT/scripts/sync-fork.sh" rezusforks all 2>&1; }

echo "── discovery, exclusion, non-fork filtering, per-member dispatch"
# stub members: record which defs they received; cilium no-op, dapr changed,
# signoz conflict (2) — a MIXED group exercise.
cat > "$WORK/bin/stub-member" <<'EOF'
#!/usr/bin/env bash
member="$1"
echo "MEMBER-RUN: $member def=${HARMOSTES_FORK_DEF:-NONE}" >> "${DISPATCH_LOG:?DISPATCH_LOG must be set}"
if [ -n "${HARMOSTES_FORK_DEF:-}" ]; then cp "$HARMOSTES_FORK_DEF" "${DISPATCH_DIR:-/tmp}/def-$member.yaml"; fi
case "$member" in
  cilium) echo "=== Already up to date ==="; exit 0 ;;
  dapr)   echo "=== Sync complete ==="; exit 0 ;;
  signoz) echo "conflict"; exit 2 ;;
esac
EOF
chmod +x "$WORK/bin/stub-member"
run_group() { DISPATCH_LOG="$WORK/dispatch.log" DISPATCH_DIR="$WORK" HARMOSTES_SYNC_CHILD="$WORK/bin/stub-member %MEMBER%" PATH="$WORK/bin:$PATH" bash "$MAINT/scripts/sync-fork.sh" rezusforks all 2>&1; }
OUT=$(run_group); RC=$?

assert_eq "$RC" "2" "worst-outcome exit: a conflicted member → 2 (0 fine, one conflict)"
assert_contains "excluded (def): external-dns" "$OUT" "the exclusion is loud (external-dns)"
assert_contains "discovered (4)" "$OUT" "four fork repos discovered"
assert_contains "maintaining (3): cilium dapr signoz" "$OUT" "maintained set = discovery − exclusion"
assert_contains "member signoz: CONFLICT" "$OUT" "conflict outcome reported"
# non-fork repo never dispatched
grep -q "MEMBER-RUN: notafork" "$WORK/dispatch.log" && fail "non-fork repo was dispatched" || ok "non-fork repo not maintained"
grep -q "MEMBER-RUN: external-dns" "$WORK/dispatch.log" && fail "excluded member was dispatched" || ok "excluded member not dispatched"
# final line = aggregate PluginResult with a members array
LAST=$(grep -v '^$' <<<"$OUT" | tail -1)
python3 - "$LAST" <<'EOF' && ok "aggregate PluginResult parses (changed:true, 3 members, outcomes)" || fail "aggregate PluginResult malformed"
import json, sys
d = json.loads(sys.argv[1])
assert d["changed"] is True, d                       # dapr changed
assert d["artifact"] == "fork-sync-rezusforks", d
names = {m["name"]: m["outcome"] for m in d["members"]}
assert names == {"cilium": "no-op", "dapr": "changed", "signoz": "conflict"}, names
EOF

echo "── member-def composition (own file wins; synthesis from defaults+map)"
# dapr HAS a def file → the child runs with its OWN def path (not a temp synthesis)
grep -q "MEMBER-RUN: dapr def=$MAINT/forks/dapr.yaml" "$WORK/dispatch.log" && ok "dapr: own def file used (HARMOSTES_FORK_DEF = the member's own file)" || fail "dapr: own-def path not passed through"
# cilium has no file → synthesized: upstream from upstream_map, fork branch convention, defaults merged
if [ -f "$WORK/def-cilium.yaml" ]; then
  python3 - "$WORK/def-cilium.yaml" <<'EOF' && ok "cilium def synthesized: upstream_map + rezus/<default> convention + defaults" || fail "cilium synthesized def wrong"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert d["upstream"] == {"url": "https://github.com/cilium/cilium", "branch": "main"}, d["upstream"]
assert d["fork"]["url"] == "https://github.com/rezusforks/cilium", d["fork"]
assert d["fork"]["default_branch"] == "rezus/main", d["fork"]
assert d["fork"]["token_env"] == "GITHUB_TOKEN", d["fork"]
assert d["auto"] == {"merge": False, "release": False}, d["auto"]
EOF
else
  fail "cilium synthesized def wrong (no def-cilium.yaml handed to the member)"
fi

echo "── skip-loud for an unmapped, undef'd member"
cat > "$MAINT/forks/rezusforks2.yaml" <<'EOF'
name: rezusforks2
kind: group
group:
  platform: github
  org: rezusforks2
  exclude: [cilium]   # → members: dapr (own def), orphan (nothing — the skip)
EOF
OUT2=$(DISPATCH_LOG="$WORK/dispatch2.log" HARMOSTES_SYNC_CHILD="$WORK/bin/stub-member %MEMBER%" PATH="$WORK/bin:$PATH" bash "$MAINT/scripts/sync-fork.sh" rezusforks2 all 2>&1); RC2=$?
assert_contains "SKIPPED (no upstream" "$OUT2" "undef'd + unmapped member is SKIPPED, never guessed"
grep -q "member orphan: SKIPPED" <<<"$OUT2" && ok "orphan: no def, no map, detached parent → skipped" || fail "orphan not skipped"
grep -q "MEMBER-RUN: dapr" "$WORK/dispatch2.log" && ok "dapr still maintained via its own def while others skip" || fail "dapr should run (own def)"
assert_eq "$RC2" "0" "skip does not fail the group; the remaining member runs clean"

echo "── include mode + all-failed exit contract"
cat > "$MAINT/forks/rezusforks3.yaml" <<'EOF'
name: rezusforks3
kind: group
group:
  platform: github
  org: rezusforks
  include: [dapr, external-dns, notafork]   # include REPLACES exclusion; unknown entries warn
EOF
OUT3=$(DISPATCH_LOG="$WORK/dispatch3.log" HARMOSTES_SYNC_CHILD="$WORK/bin/stub-member %MEMBER%" PATH="$WORK/bin:$PATH" bash "$MAINT/scripts/sync-fork.sh" rezusforks3 all 2>&1); RC3=$?
assert_contains "included (def): dapr external-dns notafork" "$OUT3" "include mode: explicit member list"
assert_contains "WARNING: include entries not discovered: notafork" "$OUT3" "unknown include entry warns"
cat > "$WORK/bin/stub-member2" <<'EOF'
#!/usr/bin/env bash
echo "boom"; exit 9
EOF
chmod +x "$WORK/bin/stub-member2"
OUT4=$(HARMOSTES_SYNC_CHILD="$WORK/bin/stub-member2 %MEMBER%" PATH="$WORK/bin:$PATH" bash "$MAINT/scripts/sync-fork.sh" rezusforks3 all 2>&1); RC4=$?
assert_eq "$RC4" "1" "ALL members failed → group exit 1"

echo ""
echo "── bootstrap fixture (real git: absent release branch seeds from the fork default)"
BS="$WORK/bs"; mkdir -p "$BS"
# file:// URLs: --depth on a local PATH clone misreports the repo as empty
# (git quirk; the release-refs fixture uses file:// for the same reason)
UP_PATH="$BS/up.git"; FORK_PATH="$BS/fork.git"   # raw paths (creation + asserts)
UP="file://$BS/up.git"; FORK="file://$BS/fork.git" # def URLs (file://: --depth quirk on path clones)
git init -q --bare "$UP_PATH"
U="$BS/u"; git init -q "$U"; cd "$U"
git remote add origin "$UP"
echo r1 > f && git add f && git commit -qm r1 && git push -q origin master:main
# bare fork: only 'main' (upstream snapshot), NO rezus/main
git init -q --bare "$FORK_PATH"
git init -q "$BS/f"; cd "$BS/f"; git remote add origin "$FORK"
git fetch -q "$UP_PATH" main && git checkout -qB main FETCH_HEAD && git push -q origin main
# bare-repo HEAD → main (init.defaultBranch=master makes HEAD point at a ref
# that doesn't exist; the clone would land on an unborn branch and the
# bootstrap would seed from nothing)
git --git-dir="$FORK_PATH" symbolic-ref HEAD refs/heads/main
mkdir -p "$BS/maint/scripts" "$BS/maint/forks"
cp "$ROOT/scripts/sync-fork.sh" "$ROOT/scripts/git-host.sh" "$ROOT/scripts/conflict-event.sh" "$BS/maint/scripts/"
cat > "$BS/maint/forks/canary2.yaml" <<EOF
name: canary2
upstream:
  url: $UP
  branch: main
fork:
  url: $FORK
  default_branch: rezus/main
  platform: local
EOF
# merge phase only: upstream main (FETCH_HEAD) == fork main → the bootstrap
# seeds rezus/main, then the is-ancestor check sees upstream contained → no-op
cd "$BS"
OUT5=$(HOME="$BS" bash "$BS/maint/scripts/sync-fork.sh" canary2 merge 2>&1); RC5=$?
assert_eq "$RC5" "0" "bootstrap run completes (upstream contained after seeding)"
git --git-dir="$FORK_PATH" rev-parse --verify -q refs/heads/rezus/main >/dev/null && ok "rezus/main exists on the fork after bootstrap" || fail "rezus/main not seeded"
git --git-dir="$FORK_PATH" rev-parse refs/heads/rezus/main > "$WORK/seeded.sha"
git --git-dir="$FORK_PATH" rev-parse refs/heads/main > "$WORK/main.sha"
assert_eq "$(cat "$WORK/seeded.sha")" "$(cat "$WORK/main.sha")" "seeded release branch == fork default (bare fork → upstream snapshot)"
grep -q "BOOTSTRAP" <<<"$OUT5" && ok "bootstrap is loud" || fail "bootstrap not announced"

echo ""
echo "════════════════════════════════════"
echo "group-defs: PASS=$PASS FAIL=$FAIL"
exit $FAIL
