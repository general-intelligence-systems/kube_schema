#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../lib/kube/schema"
require "tmpdir"

Manifest = Kube::Schema::Manifest

# ── Creating resources from schemas ──

deployment = Kube::Schema["Deployment"].new {
  self.apiVersion = "apps/v1"
  self.kind = "Deployment"
  metadata.name = "web"
  metadata.namespace = "prod"
  spec.replicas = 3
  spec.template.spec.containers = [
    { name: "app", image: "nginx:1.27" }
  ]
}

service = Kube::Schema["Service"].new {
  self.apiVersion = "v1"
  self.kind = "Service"
  metadata.name = "web"
  metadata.namespace = "prod"
  spec.selector = { app: "web" }
  spec.ports = [{ port: 80, targetPort: 8080 }]
}

namespace = Kube::Schema["Namespace"].new {
  self.apiVersion = "v1"
  self.kind = "Namespace"
  metadata.name = "prod"
}

configmap = Kube::Schema["ConfigMap"].new {
  self.apiVersion = "v1"
  self.kind = "ConfigMap"
  metadata.name = "app-config"
  metadata.namespace = "prod"
  self.data = { LOG_LEVEL: "info", WORKERS: "4" }
}

secret = Kube::Schema["Secret"].new {
  self.apiVersion = "v1"
  self.kind = "Secret"
  metadata.name = "db-creds"
  metadata.namespace = "prod"
  self.type = "Opaque"
  self.data = { password: "c2VjcmV0" }
}


# ── Empty manifest ──

empty = Manifest.new


# ── Seeding on construction ──

seeded = Manifest.new(namespace, deployment, service)


# ── Appending with << ──

manifest = Manifest.new
manifest << namespace
manifest << deployment
manifest << service


# ── Chaining << ──

chained = Manifest.new
chained << namespace << deployment << service << configmap


# ── Appending an array ──

from_array = Manifest.new
from_array << [namespace, deployment, service]


# ── Flattening manifests (no nesting) ──

infra    = Manifest.new(namespace, configmap)
app      = Manifest.new(deployment, service)
combined = Manifest.new
combined << infra
combined << app


# ── Enumerable ──

manifest = Manifest.new(namespace, deployment, service, configmap)

manifest.each { |r| r.to_h[:kind] }
manifest.map { |r| r.to_h[:kind] }
manifest.select { |r| r.to_h[:kind] == "Service" }
manifest.any? { |r| r.to_h[:kind] == "Pod" }
manifest.first
manifest.count
manifest.size
manifest.length


# ── to_a (returns a copy) ──

resources = manifest.to_a
resources.pop  # doesn't affect the manifest


# ── to_yaml ──

manifest.to_yaml


# ── File I/O ──

tmpdir = Dir.mktmpdir("manifest_example")
path   = File.join(tmpdir, "cluster.yaml")

# Write
manifest = Manifest.new(namespace, deployment, service)
manifest.write(path)
manifest.filename  # => path

# Open
loaded = Manifest.open(path)
loaded.filename  # => path

# Open, modify, write back
manifest = Manifest.open(path)
manifest << configmap
manifest.write

# Write to a different path
manifest.write(File.join(tmpdir, "exported.yaml"))

# Open + tap + write
Manifest.open(path).tap { |m| m << secret }.write

# Filename tracking
Manifest.new.filename                          # => nil
Manifest.new(filename: "a.yaml").filename      # => "a.yaml"
Manifest.open(path).filename                   # => path


# ── Resource#valid? / #valid! ──

valid_deploy = Kube::Schema["Deployment"].new {
  self.apiVersion = "apps/v1"
  self.kind = "Deployment"
  metadata.name = "test"
}
valid_deploy.valid?  # => true
valid_deploy.valid!  # => true

invalid_deploy = Kube::Schema["Deployment"].new {
  self.apiVersion = 12345
}
invalid_deploy.valid?  # => false

begin
  invalid_deploy.valid!  # => raises Kube::ValidationError
rescue Kube::ValidationError => e
  e.message  # => "Schema validation failed for Deployment:\n  - apiVersion = 12345 — expected string, got Integer"
  e.errors   # => [{...}]
end


# Cleanup
FileUtils.rm_rf(tmpdir)
