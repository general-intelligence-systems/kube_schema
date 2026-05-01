# Schema Versions

This guide covers working with different Kubernetes schema versions.

## Bundled Schemas

Bundled schemas ship with the gem for Kubernetes 1.19 through 1.35. Updated automatically via CI.

## Setting a Version

```ruby
Kube::Schema.schema_version = "1.31"
Kube::Schema["Deployment"]  # uses 1.31
```

## Discovery

```ruby
Kube::Schema.schema_versions    # => ["1.19", "1.20", ..., "1.35"]
Kube::Schema.latest_version     # => "1.35"

Kube::Schema["1.34"].list_resources
# => ["Binding", "CSIDriver", "ConfigMap", "Deployment", ...]
```

## Version-Specific Access

```ruby
Kube::Schema["1.34"]["Deployment"]
Kube::Schema["1.31"]["Pod"]
```
