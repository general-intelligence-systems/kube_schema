#!/usr/bin/env ruby
# frozen_string_literal: true

# Thorough example exercising vCluster Platform (management.loft.sh) schemas.
#
# Demonstrates:
#   - Creating a multi-tenant vCluster Platform setup
#   - Projects, Teams, Virtual Cluster Templates, Space Templates
#   - Virtual Cluster Instances, Space Instances
#   - RBAC: Cluster Access, Cluster Role Templates
#   - Shared Secrets
#   - Schema validation (valid and invalid resources)
#   - Manifest assembly and YAML output
#
# Run:  bundle exec ruby examples/vcluster.rb

require_relative "../lib/kube/schema"
require "tmpdir"

Manifest = Kube::Schema::Manifest

puts "=" * 60
puts "vCluster Platform (management.loft.sh) Schema Example"
puts "=" * 60
puts

# ── Verify loft types are loaded ────────────────────────────

schema = Kube::Schema["1.34"]
loft_kinds = schema.list_resources.select { |k|
  entry = schema.send(:find_gvk_entry, k)
  entry && entry[:group].include?("loft.sh")
}

puts "Available loft.sh resource kinds: #{loft_kinds.length}"
puts "  #{loft_kinds.sort.first(10).join(", ")}..."
puts


# ══════════════════════════════════════════════════════════════
#  1. TEAMS — define who can access what
# ══════════════════════════════════════════════════════════════

platform_admins = Kube::Schema["Team"].new {
  metadata.name = "platform-admins"
  spec.displayName = "Platform Administrators"
  spec.description = "Full access to all platform resources"
  spec.users = ["admin@company.com", "ops-lead@company.com"]
  spec.groups = ["platform-admins"]
  spec.clusterRoles = [
    { clusterRole: "cluster-admin" }
  ]
  spec.access = [
    {
      verbs: ["get", "update", "delete"],
      subresources: ["*"],
      users: ["admin@company.com"]
    }
  ]
}

dev_team = Kube::Schema["Team"].new {
  metadata.name = "backend-devs"
  spec.displayName = "Backend Developers"
  spec.description = "Backend engineering team"
  spec.users = [
    "alice@company.com",
    "bob@company.com",
    "carol@company.com"
  ]
  spec.groups = ["engineering", "backend"]
}

ml_team = Kube::Schema["Team"].new {
  metadata.name = "ml-engineers"
  spec.displayName = "ML Engineers"
  spec.description = "Machine learning and data platform team"
  spec.users = [
    "dave@company.com",
    "eve@company.com"
  ]
  spec.groups = ["engineering", "ml"]
}

puts "1. Teams created:"
puts "   - #{platform_admins.metadata[:name]}: #{platform_admins.spec[:users]&.length || 0} users"
puts "   - #{dev_team.metadata[:name]}: #{dev_team.spec[:users]&.length || 0} users"
puts "   - #{ml_team.metadata[:name]}: #{ml_team.spec[:users]&.length || 0} users"
puts


# ══════════════════════════════════════════════════════════════
#  2. CLUSTER ROLE TEMPLATES — reusable RBAC policies
# ══════════════════════════════════════════════════════════════

namespace_admin_role = Kube::Schema["ClusterRoleTemplate"].new {
  metadata.name = "namespace-admin"
  spec.displayName = "Namespace Admin"
  spec.description = "Full admin access within assigned namespaces"
  spec.access = [
    {
      verbs: ["get"],
      subresources: ["*"],
      teams: ["platform-admins"]
    }
  ]
  spec.clusterRoleTemplate = {
    metadata: {
      labels: { "loft.sh/managed" => "true" }
    },
    rules: [
      {
        apiGroups: ["", "apps", "batch", "networking.k8s.io"],
        resources: ["*"],
        verbs: ["*"]
      },
      {
        apiGroups: ["rbac.authorization.k8s.io"],
        resources: ["roles", "rolebindings"],
        verbs: ["*"]
      }
    ]
  }
}

readonly_role = Kube::Schema["ClusterRoleTemplate"].new {
  metadata.name = "readonly-viewer"
  spec.displayName = "Read-Only Viewer"
  spec.description = "Read-only access for auditing and troubleshooting"
  spec.clusterRoleTemplate = {
    rules: [
      {
        apiGroups: ["*"],
        resources: ["*"],
        verbs: ["get", "list", "watch"]
      }
    ]
  }
}

puts "2. ClusterRoleTemplates created:"
puts "   - #{namespace_admin_role.metadata[:name]}"
puts "   - #{readonly_role.metadata[:name]}"
puts


# ══════════════════════════════════════════════════════════════
#  3. CLUSTER ACCESS — bind teams to cluster roles
# ══════════════════════════════════════════════════════════════

dev_cluster_access = Kube::Schema["ClusterAccess"].new {
  metadata.name = "backend-dev-access"
  spec.displayName = "Backend Dev Cluster Access"
  spec.description = "Grants backend devs namespace-admin on dev clusters"
  spec.clusters = ["dev-cluster-us", "dev-cluster-eu"]
  spec.access = [
    {
      verbs: ["get"],
      subresources: ["*"],
      teams: ["backend-devs"]
    }
  ]
  spec.localClusterAccessTemplate = {
    spec: {
      teams: ["backend-devs"],
      clusterRole: "namespace-admin"
    }
  }
}

puts "3. ClusterAccess created:"
puts "   - #{dev_cluster_access.metadata[:name]}: #{dev_cluster_access.spec[:clusters]&.length || 0} clusters"
puts


# ══════════════════════════════════════════════════════════════
#  4. VIRTUAL CLUSTER TEMPLATE — reusable vcluster blueprints
# ══════════════════════════════════════════════════════════════

standard_vcluster_template = Kube::Schema["VirtualClusterTemplate"].new {
  metadata.name = "standard-vcluster"
  metadata.labels = {
    "loft.sh/tier" => "standard",
    "company.com/managed" => "true"
  }
  spec.displayName = "Standard Virtual Cluster"
  spec.description = "Default vCluster template with k3s, resource limits, and auto-sleep"
  spec.owner = {
    team: "platform-admins"
  }
  spec.template = {
    metadata: {
      labels: {
        "loft.sh/template" => "standard-vcluster"
      },
      annotations: {
        "loft.sh/custom-links" => "https://docs.internal/vclusters"
      }
    },
    accessPoint: {
      ingress: {}
    },
    helmRelease: {
      chart: {
        version: "0.33.0"
      },
      values: <<~YAML
        sync:
          toHost:
            ingresses:
              enabled: true
          fromHost:
            nodes:
              enabled: true
        networking:
          replicateServices:
            fromHost:
              - from: kube-system/kube-dns
                to: kube-system/kube-dns
      YAML
    },
    spaceTemplate: {
      metadata: {},
      objects: <<~YAML
        apiVersion: v1
        kind: ResourceQuota
        metadata:
          name: vcluster-quota
        spec:
          hard:
            requests.cpu: "4"
            requests.memory: 8Gi
            limits.cpu: "8"
            limits.memory: 16Gi
            pods: "50"
      YAML
    }
  }
  spec.access = [
    {
      verbs: ["get"],
      subresources: ["*"],
      teams: ["platform-admins", "backend-devs", "ml-engineers"]
    }
  ]
}

gpu_vcluster_template = Kube::Schema["VirtualClusterTemplate"].new {
  metadata.name = "gpu-vcluster"
  metadata.labels = {
    "loft.sh/tier" => "gpu",
    "company.com/managed" => "true"
  }
  spec.displayName = "GPU Virtual Cluster"
  spec.description = "vCluster template for GPU workloads with NVIDIA device plugin sync"
  spec.owner = { team: "platform-admins" }
  spec.template = {
    helmRelease: {
      chart: { version: "0.33.0" },
      values: <<~YAML
        sync:
          toHost:
            ingresses:
              enabled: true
          fromHost:
            nodes:
              enabled: true
              selector:
                labels:
                  nvidia.com/gpu.present: "true"
      YAML
    },
    spaceTemplate: {
      objects: <<~YAML
        apiVersion: v1
        kind: ResourceQuota
        metadata:
          name: gpu-quota
        spec:
          hard:
            requests.cpu: "16"
            requests.memory: 64Gi
            nvidia.com/gpu: "4"
            pods: "20"
      YAML
    }
  }
}

puts "4. VirtualClusterTemplates created:"
puts "   - #{standard_vcluster_template.metadata[:name]}"
puts "   - #{gpu_vcluster_template.metadata[:name]}"
puts


# ══════════════════════════════════════════════════════════════
#  5. SPACE TEMPLATE — namespace blueprints
# ══════════════════════════════════════════════════════════════

isolated_space_template = Kube::Schema["SpaceTemplate"].new {
  metadata.name = "isolated-namespace"
  spec.displayName = "Isolated Namespace"
  spec.description = "Namespace with network policies that deny all ingress/egress by default"
  spec.owner = { team: "platform-admins" }
  spec.template = {
    metadata: {
      labels: {
        "loft.sh/isolation" => "strict"
      }
    },
    objects: <<~YAML
      apiVersion: networking.k8s.io/v1
      kind: NetworkPolicy
      metadata:
        name: default-deny-all
      spec:
        podSelector: {}
        policyTypes:
          - Ingress
          - Egress
      ---
      apiVersion: v1
      kind: LimitRange
      metadata:
        name: default-limits
      spec:
        limits:
          - default:
              cpu: 500m
              memory: 512Mi
            defaultRequest:
              cpu: 100m
              memory: 128Mi
            type: Container
    YAML
  }
  spec.access = [
    {
      verbs: ["get"],
      subresources: ["*"],
      teams: ["platform-admins", "backend-devs"]
    }
  ]
}

puts "5. SpaceTemplate created:"
puts "   - #{isolated_space_template.metadata[:name]}"
puts


# ══════════════════════════════════════════════════════════════
#  6. PROJECT — multi-tenant isolation boundary
# ══════════════════════════════════════════════════════════════

backend_project = Kube::Schema["Project"].new {
  metadata.name = "backend"
  spec.displayName = "Backend Services"
  spec.description = "Project for backend microservices team"
  spec.owner = {
    team: "platform-admins"
  }
  spec.members = [
    {
      team: "backend-devs",
      clusterRole: "loft-management-project-admin"
    },
    {
      team: "platform-admins",
      clusterRole: "loft-management-project-admin"
    }
  ]
  spec.allowedClusters = [
    { name: "dev-cluster-us" },
    { name: "dev-cluster-eu" },
    { name: "staging-cluster" }
  ]
  spec.allowedTemplates = [
    { kind: "VirtualClusterTemplate", name: "standard-vcluster" },
    { kind: "SpaceTemplate", name: "isolated-namespace" }
  ]
  spec.quotas = {
    project: {
      "requests.cpu": "32",
      "requests.memory": "64Gi",
      "pods": "200",
      "count/virtualclusterinstances": "5",
      "count/spaceinstances": "10"
    }
  }
  spec.requireTemplate = {
    enforced: false
  }
}

ml_project = Kube::Schema["Project"].new {
  metadata.name = "ml-platform"
  spec.displayName = "ML Platform"
  spec.description = "Project for ML training and inference workloads"
  spec.owner = { team: "platform-admins" }
  spec.members = [
    {
      team: "ml-engineers",
      clusterRole: "loft-management-project-admin"
    }
  ]
  spec.allowedClusters = [
    { name: "gpu-cluster-us" }
  ]
  spec.allowedTemplates = [
    { kind: "VirtualClusterTemplate", name: "gpu-vcluster" },
    { kind: "VirtualClusterTemplate", name: "standard-vcluster" }
  ]
  spec.quotas = {
    project: {
      "nvidia.com/gpu": "8",
      "requests.cpu": "64",
      "requests.memory": "256Gi"
    }
  }
}

puts "6. Projects created:"
puts "   - #{backend_project.metadata[:name]}: #{backend_project.spec[:allowedClusters]&.length || 0} clusters, #{backend_project.spec[:members]&.length || 0} members"
puts "   - #{ml_project.metadata[:name]}: #{ml_project.spec[:allowedClusters]&.length || 0} clusters, #{ml_project.spec[:members]&.length || 0} members"
puts


# ══════════════════════════════════════════════════════════════
#  7. VIRTUAL CLUSTER INSTANCES — actual vclusters
# ══════════════════════════════════════════════════════════════

dev_vcluster = Kube::Schema["VirtualClusterInstance"].new {
  metadata.name = "backend-dev"
  metadata.namespace = "loft-p-backend"
  metadata.labels = {
    "app.kubernetes.io/managed-by" => "loft",
    "env" => "development"
  }
  metadata.annotations = {
    "loft.sh/custom-links" => "https://grafana.internal/d/vcluster?var-name=backend-dev"
  }
  spec.displayName = "Backend Dev Cluster"
  spec.description = "Development vCluster for the backend team"
  spec.owner = { team: "backend-devs" }
  spec.templateRef = {
    name: "standard-vcluster"
  }
  spec.clusterRef = {
    cluster: "dev-cluster-us",
    namespace: "loft-backend-dev"
  }
  spec.access = [
    {
      verbs: ["get", "update"],
      subresources: ["*"],
      teams: ["backend-devs"]
    }
  ]
}

staging_vcluster = Kube::Schema["VirtualClusterInstance"].new {
  metadata.name = "backend-staging"
  metadata.namespace = "loft-p-backend"
  metadata.labels = {
    "app.kubernetes.io/managed-by" => "loft",
    "env" => "staging"
  }
  spec.displayName = "Backend Staging Cluster"
  spec.description = "Staging vCluster that mirrors production topology"
  spec.owner = { team: "platform-admins" }
  spec.templateRef = {
    name: "standard-vcluster"
  }
  spec.clusterRef = {
    cluster: "staging-cluster",
    namespace: "loft-backend-staging"
  }
  spec.parameters = "sleepAfter: 7200\ndeleteAfter: 604800"
}

ml_training_vcluster = Kube::Schema["VirtualClusterInstance"].new {
  metadata.name = "ml-training"
  metadata.namespace = "loft-p-ml-platform"
  metadata.labels = {
    "env" => "training",
    "workload-type" => "gpu"
  }
  spec.displayName = "ML Training Cluster"
  spec.description = "GPU-enabled vCluster for model training"
  spec.owner = { team: "ml-engineers" }
  spec.templateRef = {
    name: "gpu-vcluster"
  }
  spec.clusterRef = {
    cluster: "gpu-cluster-us"
  }
}

puts "7. VirtualClusterInstances created:"
puts "   - #{dev_vcluster.metadata[:name]} (#{dev_vcluster.spec[:templateRef][:name]})"
puts "   - #{staging_vcluster.metadata[:name]} (#{staging_vcluster.spec[:templateRef][:name]})"
puts "   - #{ml_training_vcluster.metadata[:name]} (#{ml_training_vcluster.spec[:templateRef][:name]})"
puts


# ══════════════════════════════════════════════════════════════
#  8. SPACE INSTANCES — managed namespaces
# ══════════════════════════════════════════════════════════════

ci_space = Kube::Schema["SpaceInstance"].new {
  metadata.name = "ci-runners"
  metadata.namespace = "loft-p-backend"
  spec.displayName = "CI Runners"
  spec.description = "Isolated namespace for CI/CD pipeline runners"
  spec.owner = { team: "platform-admins" }
  spec.templateRef = {
    name: "isolated-namespace"
  }
  spec.clusterRef = {
    cluster: "dev-cluster-us"
  }
}

puts "8. SpaceInstance created:"
puts "   - #{ci_space.metadata[:name]}"
puts


# ══════════════════════════════════════════════════════════════
#  9. SHARED SECRETS — cross-project secrets
# ══════════════════════════════════════════════════════════════

docker_creds = Kube::Schema["SharedSecret"].new {
  metadata.name = "registry-credentials"
  metadata.namespace = "loft-p-backend"
  spec.displayName = "Container Registry Credentials"
  spec.description = "Shared credentials for pulling from the private container registry"
  spec.access = [
    {
      verbs: ["get"],
      subresources: ["*"],
      teams: ["backend-devs", "ml-engineers"]
    }
  ]
  spec.data = {
    ".dockerconfigjson" => "eyJhdXRocyI6eyJyZWdpc3RyeS5jb21wYW55LmNvbSI6e319fQ=="
  }
}

puts "9. SharedSecret created:"
puts "   - #{docker_creds.metadata[:name]}"
puts


# ══════════════════════════════════════════════════════════════
# 10. VALIDATION — prove schemas actually validate
# ══════════════════════════════════════════════════════════════

puts "10. Validation checks:"

# All resources should be valid
all_resources = [
  platform_admins, dev_team, ml_team,
  namespace_admin_role, readonly_role,
  dev_cluster_access,
  standard_vcluster_template, gpu_vcluster_template,
  isolated_space_template,
  backend_project, ml_project,
  dev_vcluster, staging_vcluster, ml_training_vcluster,
  ci_space,
  docker_creds
]

all_resources.each do |r|
  kind = r.to_h[:kind]
  name = r.metadata[:name]
  puts "    #{kind}/#{name}: valid? = #{r.valid?}"
end

# Deliberately invalid resource: wrong types
puts
puts "    Checking invalid resource detection..."
bad_vci = Kube::Schema["VirtualClusterInstance"].new {
  metadata.name = 99999                      # should be string
  spec.description = ["not", "a", "string"]  # should be string
}
puts "    Invalid VCI valid? = #{bad_vci.valid?}"

begin
  bad_vci.valid!
rescue Kube::ValidationError => e
  puts "    Caught ValidationError: #{e.errors.length} error(s)"
  e.errors.each do |err|
    puts "      - #{err["data_pointer"]}: #{err["type"]}"
  end
end
puts


# ══════════════════════════════════════════════════════════════
# 11. MANIFEST — assemble and output YAML
# ══════════════════════════════════════════════════════════════

puts "11. Assembling full platform manifest..."

manifest = Manifest.new

# RBAC layer
manifest << platform_admins
manifest << dev_team
manifest << ml_team
manifest << namespace_admin_role
manifest << readonly_role
manifest << dev_cluster_access

# Templates
manifest << standard_vcluster_template
manifest << gpu_vcluster_template
manifest << isolated_space_template

# Projects
manifest << backend_project
manifest << ml_project

# Instances
manifest << dev_vcluster
manifest << staging_vcluster
manifest << ml_training_vcluster
manifest << ci_space

# Secrets
manifest << docker_creds

puts "    #{manifest.size} resources in manifest"
puts

# Write to temp file and read back
tmpdir = Dir.mktmpdir("vcluster_example")
path = File.join(tmpdir, "platform.yaml")
manifest.write(path)
puts "    Written to: #{path}"
puts "    File size: #{File.size(path)} bytes"

# Round-trip: read it back
loaded = Manifest.open(path)
puts "    Round-trip loaded: #{loaded.size} resources"
puts

# Print the first few resources as YAML
puts "=" * 60
puts "YAML Output (first 3 resources):"
puts "=" * 60
manifest.first(3).each { |r| puts r.to_yaml }

# Cleanup
FileUtils.rm_rf(tmpdir)

puts
puts "Done."
