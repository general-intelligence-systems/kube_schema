# Changelog

All notable changes to this project are documented here.

This file starts at 1.10.0; for earlier releases see the git history.

## [Unreleased]

### Changed

- **Schemas are compiled per definition, on demand, and collected afterwards.**
  `Instance#schemer` used to parse `v<version>.json`, merge every
  `*-definitions.json` into it, and hand the whole document to
  `JSONSchemer.schema` — one compiled tree held at the class level for the
  life of the process. That tree was **97,381 `JSONSchemer::Schema` nodes and
  ~406 MB resident** (one `JSONSchemer::Configuration` per node, plus ~230k
  vocabulary keyword objects and 1.2M hashes), built in full whether you
  validated one resource or none.

  Validating a Deployment through the public API now looks like this:

      baseline                        rss=  26.8 MB  schemas=     0
      Instance.new("1.33")            rss=  26.8 MB  schemas=     0
      instance["Deployment"]          rss=  68.5 MB  schemas=     0
      Deployment.new(...)             rss=  68.5 MB  schemas=     0
      after valid?                    rss=  68.5 MB  schemas=   147
      after GC.start                  rss=  42.4 MB  schemas=    16

  Nothing is compiled until something is validated, a Deployment needs 147
  schema nodes rather than 97,381, and they are collectable the moment the
  validation is done — about **90% less memory** than before.

  This works because `json_schemer` resolves `$ref` lazily:
  `Draft202012::Vocab::Core::Ref#ref_schema` is memoized inside `#validate`,
  and an unresolved URI goes through `ref_resolver`. So a single definition is
  compiled as its own root, its `#/definitions/...` pointers are rewritten to
  `kube:///<key>`, and a resolver loads referenced definitions on demand —
  which means the cost scales with the instance being validated, not with the
  size of the schema document.

- **`Kube::Schema.register` no longer compiles the registered schema.** It
  writes the definition to a temp file and stores an index entry, so a
  registered CRD takes the same lazy path as a built-in type. Registering the
  largest bundled CRD (1.1 MB of `io.argoproj.v1alpha1.Workflow`) now compiles
  nothing at registration time; its 9,656 nodes appear on first `#valid?` and
  collect afterwards. `reset_custom_schemas!` removes the temp files.

- `Instance.schemers` is now `Instance.catalogs`, holding a
  `Kube::Schema::Lazy::Index` (definition key to file offset, group/version/kind,
  and property names) instead of a compiled schema. The index is built by
  scanning the JSON for definition boundaries, so the schema documents are
  never parsed whole and nothing but offsets and small metadata is retained.

- **Tests run on [scampi](https://github.com/general-intelligence-systems/scampi)
  instead of RSpec.** The co-located specs moved out of
  `if __FILE__ == $0` blocks and into each file's `__END__` section, so they no
  longer load in production — Ruby stops parsing at `__END__`. `bin/test` is now
  `bundle exec scampi`, which discovers every `.rb` carrying an `__END__` spec
  section and emits TAP version 14. The assertions are scampi's `should` chain
  rather than `expect`, and the devshell gained `ripgrep`, which scampi shells
  out to for discovery.

### Added

- `Kube::Schema::Lazy` — `Scanner` (byte-offset index over the schema files),
  `Index`/`Entry`, `Spill` (temp-file backing for registered schemas), and
  `Source`, which stands in for a compiled schema: it answers `#value`,
  `#valid?`, `#validate` and `#ref`, loading the definition for property names
  and compiling behind a `WeakRef` so repeated validations reuse a live schema
  while the GC can still reclaim it.

- `Kube::MissingSchemaError`, raised when a definition cannot be read at
  validation time. A vanished spilled temp file says so explicitly, since that
  means the `Tempfile` was collected or the tmpdir swept, rather than the
  install being broken.

## [1.12.0]

### Added

- Ruby pattern matching support. `Resource#deconstruct_keys` exposes `to_h`,
  so resources match against hash patterns all the way down; `Manifest#deconstruct`
  exposes the resource array, so manifests match against array patterns.

      resource => {metadata: {name:}}

      Deployment = Kube::Schema["Deployment"]
      manifest => [Deployment => dep, *rest]

  Note that `Kube::Schema["Deployment"]` cannot be written inline in a pattern:
  Ruby parses `Const[...]` as array-pattern syntax, not a method call. Assign
  the class to a constant, or use a pin expression —
  `^(Kube::Schema["Deployment"])`.

## [1.11.0]

### Added

- `Kube::Schema.api_groups` and `Instance#api_groups` — every API group known
  to the schema (built-in types, the merged CRD bundles, and schemas
  registered via `.register`), sorted and deduplicated, with the core group
  as `""`. Intended for consumers that need to distinguish group/resource
  from core resource/subresource strings — e.g. building RBAC rules — without
  hardcoding a group list.

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
