#!/usr/bin/env bash
# Dapr post-merge hook: go mod tidy (components-contrib dependency)
set -euo pipefail
cd "${FORK_DIR:?FORK_DIR must be set}"
echo "[dapr-hook] running go mod tidy"
go mod tidy 2>/dev/null || echo "[dapr-hook] WARNING: go mod tidy had issues"
echo "[dapr-hook] done"
