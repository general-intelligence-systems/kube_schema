# Getting Started

This guide walks you through installing kube_schema and creating your first Kubernetes resource object.

## Install

```
gem install kube_schema
```

## Basic Usage

Every Kubernetes kind is a class. Fetch it by name:

```ruby
Kube::Schema["Deployment"]     # => Class < Kube::Schema::Resource
Kube::Schema["Service"]
Kube::Schema["ConfigMap"]
Kube::Schema["NetworkPolicy"]
```

Specific versions:

```ruby
Kube::Schema["1.34"]["Deployment"]
Kube::Schema["1.31"]["Pod"]
```

Discovery:

```ruby
Kube::Schema.schema_versions    # => ["1.19", "1.20", ..., "1.35"]
Kube::Schema.latest_version     # => "1.35"

Kube::Schema["1.34"].list_resources
# => ["Binding", "CSIDriver", "ConfigMap", "Deployment", ...]
```
