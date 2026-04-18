#!/usr/bin/env ruby

require_relative '../lib/kube/schema'

manifest = Kube::Schema::Manifest.new

class NetworkPolicy < Kube::Schema["NetworkPolicy"]
end

deployment = Kube::Schema["Deployment"].new {
  metadata.namespace = "example"
  metadata.name = "example-deployment"
  spec.replicas = 1
  spec.template.spec.containers = [
    { name: "app", image: "ruby:latest" }
  ]
}

puts deployment.to_yaml

namespace = Kube::Schema["Namespace"].new {
  metadata.name = "example"
}

network_policy = NetworkPolicy.new {
  self.apiVersion = "networking.k8s.io/v1"

  metadata.name = "example-policy"
  metadata.labels = {}
  metadata.annotations = {}
  metadata.namespace = "example"

  spec.podSelector = {}
  spec.policyTypes = ["Ingress", "Egress"]
  spec.ingress = []
  spec.egress = []
}

manifest << deployment
manifest << namespace
manifest << network_policy
