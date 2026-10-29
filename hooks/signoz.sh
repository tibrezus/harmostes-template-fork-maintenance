#!/usr/bin/env bash
# SigNoz post-merge hook: strip ee/ directory (permanent divergence)
set -euo pipefail
cd "${FORK_DIR:?FORK_DIR must be set}"
echo "[signoz-hook] stripping ee/ (community-only build)"
git rm -rf ee/ 2>/dev/null || true
echo "[signoz-hook] done"
