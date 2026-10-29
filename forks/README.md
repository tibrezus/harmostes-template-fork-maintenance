# Fork definitions — the SCHEMA lives here, the DATA lives in harmostes-config

A fork def (consumed by `scripts/sync-fork.sh`, validated by
`checks/validate-fork.sh`) is a YAML file: `<name>.yaml` with the fork's
upstream/downstream coordinates and its validation block. The DATA is
per-project configuration — it belongs to the config tier
(`tibrezus/harmostes-config`, per-environment overlays), delivered to the
cluster as the fork-defs ConfigMap.

This directory carries the shape contract + an annotated example. CI
validates every example against the live validator (mutation: a def that
should fail does fail).
