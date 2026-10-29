# Fork definitions — the SCHEMA lives here, the DATA lives in harmostes-config

A fork def (validated by `checks/validate-fork.sh`) declares the fork's
validation contract: per-check blocks (go_build, go_test, …) whose packages
are declared EXPLICITLY. The DATA (live defs per fork) is per-project
configuration — it belongs to the config tier (`tibrezus/harmostes-config`,
per-environment overlays), delivered to the cluster as the fork-defs
ConfigMap. This directory carries the shape contract: an annotated example
(CI: the validator accepts it) and an invalid def (CI: hard-rejected).
