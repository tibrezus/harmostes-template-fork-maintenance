#!/usr/bin/env bash
# =============================================================================
# validate-fork.sh — Centralized, UNIVERSAL fork validation
# =============================================================================
# Runs build + test + clean-tree + integration checks against a fork's working
# directory. Which checks run is declared per-fork in the fork definition
# (`forks/<name>.yaml` → `validation:`), so this script is host-agnostic and
# language-agnostic — it does NOT hardcode any fork's structure.
#
# Called by sync-fork.sh AFTER the post-merge hook (which owns code generation)
# and BEFORE the sync PR is pushed. Results are written to a PER-FORK file so
# they cannot leak between forks sharing the same pod.
#
# Declared checks (all optional; a fork with no `validation:` block passes):
#
#   validation:
#     go_build:               # compile Go packages (any Go fork)
#       - module: .           #   working dir (module root) within the workdir
#         packages: [./cmd/community]
#     go_test:                # run Go packages' tests (BEHAVIORAL gate #564)
#       - module: pkg/metrics #   presence ≠ behavior: signatures prove the
#         packages: [./...]   #   patch survived the merge; tests prove the
#         timeout: 120s       #   feature still works (timeout REQUIRED-guard:
#                             #   packages must be declared EXPLICITLY — no
#                             #   silent ./... fallback)
#     clean_tree:             # verify generated code is committed (codegen drift)
#       paths: [staging/.../zz_generated_*.go]
#     integration:            # opt-in; `kind` selects the harness routine
#       kind: forgejo-live    #   only forgejo-live today
#       image: codeberg.org/forgejo/forgejo:15-rootless
#       module: staging/src/forgejo.org/fj
#       env: {KEY: value}
#
# Usage: validate-fork.sh <fork-name> <fork-workdir>
# Returns: 0 if all declared checks pass (or none declared), 1 if any fail
# =============================================================================
set -uo pipefail   # NOT -e: collect all check results before exiting

FORK_NAME="${1:?Usage: validate-fork.sh <fork-name> <workdir>}"
WORKDIR="${2:?Usage: validate-fork.sh <fork-name> <workdir>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAINT_DIR="$(dirname "$SCRIPT_DIR")"
DEF_FILE="$MAINT_DIR/forks/${FORK_NAME}.yaml"

if [ ! -f "$DEF_FILE" ]; then
  echo "ERROR: fork definition not found: $DEF_FILE" >&2
  exit 1
fi

# yq reader with a null-safe default
ry() { yq -r "$1" "$DEF_FILE" 2>/dev/null; }

# ── Schema validation for GROUP defs (kind: group) ───────────────────────────
# A group def is DISCOVERY + DEFAULTS data, never a single fork's sync spec.
# The single-fork schema below is unreachable for groups — groups run per-
# member validation against each member's OWN (or synthesized) def.
DEF_KIND=$(ry '.kind // "project"')
if [ "$DEF_KIND" = "group" ]; then
  GROUP_FAIL=""
  gcheck() { [ -n "$2" ] || GROUP_FAIL="$GROUP_FAIL\n  - $1"; }
  gcheck "group.org is required" "$(ry '.group.org // ""')"
  gp=$(ry '.group.platform // "github"')
  case "$gp" in github|forgejo) ;; *) GROUP_FAIL="$GROUP_FAIL\n  - group.platform must be github|forgejo (got '$gp')" ;; esac
  if [ "$gp" = "forgejo" ]; then gcheck "group.api_url is required for forgejo groups" "$(ry '.group.api_url // ""')"; fi
  ginc=$(ry '.group.include // [] | length')
  gexc=$(ry '.group.exclude // [] | length')
  if [ "${ginc:-0}" -gt 0 ] && [ "${gexc:-0}" -gt 0 ]; then
    GROUP_FAIL="$GROUP_FAIL\n  - group.include and group.exclude are mutually exclusive"
  fi
  # entries are bare repo names — no org/ prefixes, no globs
  for key in include exclude; do
    n=$(ry ".group.$key // [] | length")
    for ((i=0; i<n; i++)); do
      e=$(ry ".group.$key[$i] // \"\"")
      case "$e" in */*) GROUP_FAIL="$GROUP_FAIL\n  - group.$key entries are bare repo names (got '$e')" ;; esac
    done
  done
  # upstream_map entries: name → {url, branch}, both non-empty
  umn=$(ry '.group.upstream_map // {} | keys | length')
  for ((i=0; i<umn; i++)); do
    k=$(ry ".group.upstream_map // {} | keys | .[$i]")
    gcheck "group.upstream_map.$k.url required" "$(ry ".group.upstream_map.\"$k\".url // \"\"")"
    gcheck "group.upstream_map.$k.branch required" "$(ry ".group.upstream_map.\"$k\".branch // \"\"")"
  done
  # Single-fork sync keys are meaningless at group level — they silently
  # would do nothing (patches/release of WHAT?). defaults carries the
  # inheritable block; everything per-member lives in member def files.
  for bad in upstream fork versioning patches additive_paths deletions post_merge_hook release validation mappings mode; do
    [ "$(ry ".${bad} // \"\"" | head -c 1)" = "" ] || GROUP_FAIL="$GROUP_FAIL\n  - '$bad:' is a single-fork key — groups carry group:/defaults: (member defs own the rest)"
  done
  if [ -n "$GROUP_FAIL" ]; then
    printf '%b\n' "ERROR: invalid group def '$FORK_NAME':$GROUP_FAIL" >&2
    exit 1
  fi
  echo "group def '$FORK_NAME' schema: ✓ (org=$(ry '.group.org'), platform=$gp)"
  exit 0
fi

RESULTS_FILE=$(mktemp)
trap "rm -f $RESULTS_FILE" EXIT

{
  echo ""
  echo "## Validation Results"
  echo ""
} >> "$RESULTS_FILE"

ALL_PASS=true
HAS_ANY=false

# =============================================================================
# Toolchain resolution (Go) — pick the exact Go minor the fork needs.
# =============================================================================
# A fork built with the wrong Go silently fails on internal-runtime reach-through
# (e.g. bytedance/sonic v1.14.1 uses Go internals that changed between 1.25 and
# 1.26 → undefined: GoMapIterator). The CronJob image is a recent golang; we pin
# the build to the fork's declared or go.mod-declared Go via GOTOOLCHAIN, which
# the go command honors by downloading the exact toolchain automatically.
#
# Precedence: validation.toolchain.go (declared) > go.mod `go` directive.
GO_TC=$(ry '.validation.toolchain.go // ""')
if [ -z "$GO_TC" ] && [ -f "$WORKDIR/go.mod" ]; then
  GO_TC=$(grep -m1 '^go ' "$WORKDIR/go.mod" | awk '{print $2}')  # e.g. 1.25.7
fi
if [ -n "$GO_TC" ]; then
  export GOTOOLCHAIN="go${GO_TC}"
  echo "=== Toolchain: GOTOOLCHAIN=${GOTOOLCHAIN} (declared/go.mod) ==="
fi

# =============================================================================
# Check: go_build — compile declared Go packages
# =============================================================================
BUILD_COUNT=$(ry '.validation.go_build // [] | length')
if [ "${BUILD_COUNT:-0}" -gt 0 ]; then
  HAS_ANY=true
  echo "=== Check: Go build ==="
  {
    echo "### Go Build"
    echo ""
    echo '```'
  } >> "$RESULTS_FILE"
  for i in $(seq 0 $((BUILD_COUNT - 1))); do
    module=$(ry ".validation.go_build[$i].module // \".\"")
    mapfile -t pkgs < <(ry ".validation.go_build[$i].packages[]")
    [ "${#pkgs[@]}" -eq 0 ] && pkgs=("./...")
    build_ok=true
    ( cd "$WORKDIR/$module" && go build "${pkgs[@]}" 2>&1 ) || build_ok=false
    status=$(if $build_ok; then echo '✅'; else echo '❌'; fi)
    echo "  $status  $module  [${pkgs[*]}]"
    echo "  $module [${pkgs[*]}]: $status" >> "$RESULTS_FILE"
    $build_ok || ALL_PASS=false
  done
  echo '```' >> "$RESULTS_FILE"
fi

# =============================================================================
# Check: go_test — run declared Go packages' tests (behavioral gate, #564)
# =============================================================================
# Complementary to signatures: a signature proves the patch TEXT survived the
# merge; a test proves the FEATURE works on the merged tree. A semantic break
# (upstream changed an API our patch depends on) greps clean and compiles —
# only the tests fail. Declare TARGETED feature packages, never upstream's
# full suite: the gate runs per sync and must stay fast and deterministic.
TEST_COUNT=$(ry '.validation.go_test // [] | length')
if [ "${TEST_COUNT:-0}" -gt 0 ]; then
  HAS_ANY=true
  echo "=== Check: Go test ==="
  {
    echo "### Go Test"
    echo ""
    echo '```'
  } >> "$RESULTS_FILE"
  for i in $(seq 0 $((TEST_COUNT - 1))); do
    module=$(ry ".validation.go_test[$i].module // \".\"")
    mapfile -t pkgs < <(ry ".validation.go_test[$i].packages[]")
    if [ "${#pkgs[@]}" -eq 0 ]; then
      # Hard, visible error — NOT a ./... default. A forgotten packages key
      # on a monorepo module would run upstream's entire (flaky, networked)
      # suite in a blocking gate and fail every sync for an unreadable reason.
      echo "  ❌  go_test[$i]: packages must be declared explicitly (no silent ./... fallback)"
      echo "  go_test[$i]: ❌ packages must be declared explicitly (no silent ./... fallback)" >> "$RESULTS_FILE"
      ALL_PASS=false
      continue
    fi
    timeout_s=$(ry ".validation.go_test[$i].timeout // \"120s\"")
    test_ok=true
    # Explicit bound: go's default is 10m PER PACKAGE — a hung test would
    # cost N×10m inside the sync and yield no verdict at all.
    ( cd "$WORKDIR/$module" && go test -timeout="$timeout_s" "${pkgs[@]}" 2>&1 ) || test_ok=false
    status=$(if $test_ok; then echo '✅'; else echo '❌'; fi)
    echo "  $status  $module  [${pkgs[*]}]"
    echo "  $module [${pkgs[*]}]: $status" >> "$RESULTS_FILE"
    $test_ok || ALL_PASS=false
  done
  echo '```' >> "$RESULTS_FILE"
fi

# =============================================================================
# Check: clean_tree — generated code must match what is committed (no drift)
# =============================================================================
# The post-merge hook already regenerated code in-place. If the committed
# source was already the correct generator output, regeneration produces
# identical bytes → clean tree → ✅. Drift → ❌.
CT_COUNT=$(ry '.validation.clean_tree.paths // [] | length')
if [ "${CT_COUNT:-0}" -gt 0 ]; then
  HAS_ANY=true
  echo "=== Check: clean tree (codegen drift) ==="
  {
    echo "### Clean Tree (codegen drift)"
    echo ""
    echo '```'
  } >> "$RESULTS_FILE"
  paths=()
  for i in $(seq 0 $((CT_COUNT - 1))); do
    paths+=("$(ry ".validation.clean_tree.paths[$i]")")
  done
  drift=$( cd "$WORKDIR" && git status --porcelain -- "${paths[@]}" 2>/dev/null )
  if [ -z "$drift" ]; then
    echo "  Clean tree: ✅" >> "$RESULTS_FILE"
  else
    echo "  Clean tree: ❌ (generated code differs from committed)" >> "$RESULTS_FILE"
    echo "$drift" | sed 's/^/    /' >> "$RESULTS_FILE"
    ALL_PASS=false
  fi
  echo '```' >> "$RESULTS_FILE"
fi

# =============================================================================
# Check: integration — opt-in, dispatched by `kind`
# =============================================================================
INT_KIND=$(ry '.validation.integration.kind // ""')
if [ -n "$INT_KIND" ]; then
  HAS_ANY=true
  echo "=== Check: integration ($INT_KIND) ==="
  {
    echo "### Integration Tests"
    echo ""
    echo '```'
  } >> "$RESULTS_FILE"
  case "$INT_KIND" in
    forgejo-live)
      run_forgejo_live_integration "$WORKDIR" >> "$RESULTS_FILE" 2>&1
      ;;
    *)
      echo "  Integration: ⚠️ unknown kind '$INT_KIND' (skipped)" >> "$RESULTS_FILE"
      ;;
  esac
  echo '```' >> "$RESULTS_FILE"
  grep -q 'Integration: ❌' "$RESULTS_FILE" && ALL_PASS=false
fi

# =============================================================================
# Summary
# =============================================================================
if ! $HAS_ANY; then
  echo "_(no validation checks declared for this fork — nothing to verify)_" >> "$RESULTS_FILE"
fi
echo "" >> "$RESULTS_FILE"
if $ALL_PASS; then
  echo "✅ **All validation checks passed.**" >> "$RESULTS_FILE"
else
  echo "❌ **Some validation checks failed.** Review the output above." >> "$RESULTS_FILE"
fi

cat "$RESULTS_FILE"
$ALL_PASS && exit 0 || exit 1

# =============================================================================
# Harness: forgejo-live — spin up a Forgejo pod/container + run integration tests
# =============================================================================
# The only fork-specific integration routine today. Parameterized entirely from
# the fork definition (image, test module, env), so validate-fork.sh itself
# stays generic. Runs in-cluster (kubectl) or locally (docker); skips otherwise.
run_forgejo_live_integration() {
  local workdir="$1"
  local image module
  image=$(ry '.validation.integration.image // "codeberg.org/forgejo/forgejo:15-rootless"')
  module=$(ry '.validation.integration.module // ""')

  if [ -z "$module" ]; then
    echo "  Integration: ⚠️ SKIP (no test module declared)"
    return
  fi

  if command -v kubectl >/dev/null 2>&1; then
    local pod="forgejo-test-${FORK_NAME}-$$"
    echo "  Starting Forgejo test pod ($pod)..."
    kubectl run "$pod" --image="$image" --namespace=fork-maintenance \
      --env=FORGEJO__security__INSTALL_LOCK=true \
      --env=FORGEJO__database__DB_TYPE=sqlite3 \
      --port=3000 >/dev/null 2>&1 || true
    local i ip token
    for i in $(seq 1 30); do
      kubectl exec -n fork-maintenance "$pod" -- curl -sf http://localhost:3000/api/v1/version >/dev/null 2>&1 && break
      sleep 3
    done
    ip=$(kubectl get pod -n fork-maintenance "$pod" -o jsonpath='{.status.podIP}' 2>/dev/null)
    if [ -n "$ip" ]; then
      kubectl exec -n fork-maintenance "$pod" -- forgejo admin user create \
        --admin --username root --password root123456 \
        --email root@test.local --must-change-password=false 2>/dev/null || true
      token=$(kubectl exec -n fork-maintenance "$pod" -- forgejo admin user generate-access-token \
        --username root --token-name ci --scopes all --raw 2>/dev/null || echo "")
      if [ -n "$token" ]; then
        if ( cd "$workdir/$module" && \
             FORGEJO_TEST_URL="http://$ip:3000" FORGEJO_TEST_TOKEN="$token" \
             FORGEJO_TEST_USER=root FORGEJO_REPO_ROOT="$workdir" \
             go test -v -tags=integration -timeout=120s ./tests/integration/... 2>&1 ); then
          echo "  Integration: ✅"
        else
          echo "  Integration: ❌ (some tests failed)"
        fi
      else
        echo "  Integration: ⚠️ SKIP (could not create token)"
      fi
    else
      echo "  Integration: ⚠️ SKIP (Forgejo pod not ready)"
    fi
    kubectl delete pod -n fork-maintenance "$pod" --force --grace-period=0 >/dev/null 2>&1 || true

  elif command -v docker >/dev/null 2>&1; then
    local c="forgejo-test-${FORK_NAME}-$$" token
    docker run -d --name "$c" -p 3199:3000 \
      -e FORGEJO__security__INSTALL_LOCK=true -e FORGEJO__database__DB_TYPE=sqlite3 \
      "$image" >/dev/null 2>&1 || true
    sleep 10
    docker exec "$c" forgejo admin user create --admin --username root --password root123456 \
      --email root@test.local --must-change-password=false 2>/dev/null || true
    token=$(docker exec "$c" forgejo admin user generate-access-token \
      --username root --token-name ci --scopes all --raw 2>/dev/null || echo "")
    if [ -n "$token" ]; then
      if ( cd "$workdir/$module" && \
           FORGEJO_TEST_URL=http://localhost:3199 FORGEJO_TEST_TOKEN="$token" \
           FORGEJO_TEST_USER=root FORGEJO_REPO_ROOT="$workdir" \
           go test -v -tags=integration -timeout=120s ./tests/integration/... 2>&1 ); then
        echo "  Integration: ✅"
      else
        echo "  Integration: ❌ (some tests failed)"
      fi
    else
      echo "  Integration: ⚠️ SKIP (no token)"
    fi
    docker rm -f "$c" >/dev/null 2>&1 || true
  else
    echo "  Integration: ⚠️ SKIP (no kubectl or docker available)"
  fi
}
