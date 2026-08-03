# Changelog

All notable changes to this project are documented here.

This file starts at 1.10.0; for earlier releases see the git history.

## [1.10.0]

### Added

- JuiceFS Operator schemas (`juicefs.io/v1`), from
  [juicedata/juicefs-operator](https://github.com/juicedata/juicefs-operator)
  v0.8.5: `CacheGroup`, `CronSync`, `Sync`, `WarmUp`.
- Agent Sandbox schemas, picked up from upstream drift on an already-tracked
  source: `Sandbox` (`agents.x-k8s.io/v1alpha1`), plus `SandboxClaim`,
  `SandboxTemplate` and `SandboxWarmPool`
  (`extensions.agents.x-k8s.io/v1alpha1`).
- VictoriaMetrics `VLDistributed` (`operator.victoriametrics.com/v1alpha1`),
  also from upstream drift.

### Fixed

- Pinned the Gateway API Inference CRD sources to v1.5.0. Upstream removed
  `inferenceobjectives.yaml` and `inferencemodelrewrites.yaml` from `main`,
  which broke schema generation and would otherwise have dropped those kinds.
- Preserved the `metrics.k8s.io/v1beta1` definitions (`PodMetrics`,
  `NodeMetrics`, their list types and `ContainerMetrics`) along with
  `meta.v1.Duration`. Newer k3s images no longer surface the metrics-server
  types in `/openapi/v2`, so regenerating the schemas silently dropped them.

No definitions were removed in this release.
