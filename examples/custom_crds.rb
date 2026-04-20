#!/usr/bin/env ruby
# frozen_string_literal: true

# Register custom CRD schemas from datreeio/CRDs-catalog
# https://github.com/datreeio/CRDs-catalog

require_relative "../lib/kube/schema"
require "open-uri"
require "json"
require "tmpdir"

CATALOG = "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main"
CACHE   = "/tmp/crds-catalog"

Dir.mkdir(CACHE) unless Dir.exist?(CACHE)

# Download and register schemas
{
  "Certificate"    => ["cert-manager.io/certificate_v1.json",              "cert-manager.io/v1"],
  "Application"    => ["argoproj.io/application_v1alpha1.json",            "argoproj.io/v1alpha1"],
  "PrometheusRule"  => ["monitoring.coreos.com/prometheusrule_v1.json",    "monitoring.coreos.com/v1"],
  "ExternalSecret" => ["external-secrets.io/externalsecret_v1beta1.json",  "external-secrets.io/v1beta1"],
  "ScaledObject"   => ["keda.sh/scaledobject_v1alpha1.json",              "keda.sh/v1alpha1"],
}.each do |kind, (path, api_version)|
  local = File.join(CACHE, File.basename(path))
  URI.open("#{CATALOG}/#{path}") { |f| File.write(local, f.read) } unless File.exist?(local)
  Kube::Schema.register(kind, schema: local, api_version: api_version)
end


# ── Use them alongside built-in k8s types ─────────────────────

manifest = Kube::Schema::Manifest.new

manifest << Kube::Schema["Namespace"].new {
  metadata.name = "prod"
}

manifest << Kube::Schema["Deployment"].new {
  metadata.name = "web"
  metadata.namespace = "prod"
  spec.replicas = 3
  spec.selector = { matchLabels: { app: "web" } }
  spec.template.metadata = { labels: { app: "web" } }
  spec.template.spec.containers = [
    { name: "app", image: "nginx:1.27", ports: [{ containerPort: 80 }] }
  ]
}

manifest << Kube::Schema["Certificate"].new {
  metadata.name = "web-tls"
  metadata.namespace = "prod"
  spec.secretName = "web-tls-secret"
  spec.issuerRef = { name: "letsencrypt-prod", kind: "ClusterIssuer" }
  spec.dnsNames = ["example.com", "www.example.com"]
}

manifest << Kube::Schema["Application"].new {
  metadata.name = "web"
  metadata.namespace = "argocd"
  spec.project = "default"
  spec.source = {
    repoURL: "https://github.com/example/web.git",
    targetRevision: "HEAD",
    path: "k8s/production"
  }
  spec.destination = {
    server: "https://kubernetes.default.svc",
    namespace: "prod"
  }
  spec.syncPolicy = {
    automated: { prune: true, selfHeal: true }
  }
}

manifest << Kube::Schema["ExternalSecret"].new {
  metadata.name = "db-creds"
  metadata.namespace = "prod"
  spec.refreshInterval = "1h"
  spec.secretStoreRef = { name: "aws-sm", kind: "ClusterSecretStore" }
  spec.target = { name: "db-creds", creationPolicy: "Owner" }
  spec.data = [
    { secretKey: "password", remoteRef: { key: "prod/db", property: "password" } }
  ]
}

manifest << Kube::Schema["ScaledObject"].new {
  metadata.name = "web-scaler"
  metadata.namespace = "prod"
  spec.scaleTargetRef = { name: "web" }
  spec.minReplicaCount = 2
  spec.maxReplicaCount = 20
  spec.triggers = [
    { type: "prometheus", metadata: {
      serverAddress: "http://prometheus:9090",
      query: 'sum(rate(http_requests_total{app="web"}[2m]))',
      threshold: "100"
    }}
  ]
}

manifest << Kube::Schema["PrometheusRule"].new {
  metadata.name = "web-alerts"
  metadata.namespace = "monitoring"
  spec.groups = [{
    name: "web.rules",
    rules: [{
      alert: "HighErrorRate",
      expr: 'rate(http_requests_total{status=~"5.."}[5m]) > 0.1',
      "for": "5m",
      labels: { severity: "critical" },
      annotations: { summary: "High 5xx error rate on web" }
    }]
  }]
}

puts manifest.to_yaml
