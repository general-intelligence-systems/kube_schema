#!/usr/bin/env ruby
# frozen_string_literal: true

# Demonstrates Kube::Schema::SubSpec — typed, schema-validated wrappers
# for non-resource Kubernetes definitions (Container, Volume, Probe, etc.).
#
# SubSpec objects validate against the OpenAPI JSON Schema and auto-coerce
# to plain hashes when placed inside Resource specs.
#
# Run:  bundle exec ruby examples/sub_specs.rb

require_relative "../lib/kube/schema"

SubSpec  = Kube::Schema::SubSpec
Manifest = Kube::Schema::Manifest

puts "=" * 60
puts "Kube::Schema::SubSpec Examples"
puts "=" * 60
puts


# ══════════════════════════════════════════════════════════════
#  1. CONTAINER — the core use case
# ══════════════════════════════════════════════════════════════

app = SubSpec["Container"].new {
  self.name  = "app"
  self.image = "myapp:1.4.2"
  self.imagePullPolicy = "IfNotPresent"
  self.command = ["/usr/bin/myapp"]
  self.args    = ["--config", "/etc/myapp/config.yaml"]
  self.ports = [
    { name: "http",    containerPort: 8080, protocol: "TCP" },
    { name: "metrics", containerPort: 9090, protocol: "TCP" }
  ]
  self.env = [
    { name: "LOG_LEVEL",  value: "info" },
    { name: "WORKERS",    value: "4" },
    { name: "DB_PASSWORD", valueFrom: { secretKeyRef: { name: "db-creds", key: "password" } } }
  ]
  self.resources.requests = { cpu: "100m", memory: "128Mi" }
  self.resources.limits   = { cpu: "500m", memory: "256Mi" }
  self.volumeMounts = [
    { name: "config", mountPath: "/etc/myapp",  readOnly: true },
    { name: "data",   mountPath: "/var/data" }
  ]
  self.livenessProbe = {
    httpGet: { path: "/healthz", port: 8080 },
    initialDelaySeconds: 10,
    periodSeconds: 30
  }
  self.readinessProbe = {
    httpGet: { path: "/ready", port: 8080 },
    initialDelaySeconds: 5,
    periodSeconds: 10
  }
  self.securityContext.runAsNonRoot = true
  self.securityContext.readOnlyRootFilesystem = true
  self.securityContext.allowPrivilegeEscalation = false
}

puts "1. Container: #{app.name}"
puts "   image: #{app.image}"
puts "   ports: #{app.ports.map { |p| p[:name] }.join(", ")}"
puts "   valid? #{app.valid?}"
puts


# ══════════════════════════════════════════════════════════════
#  2. CONTAINER PORT — typed port definitions
# ══════════════════════════════════════════════════════════════

http_port = SubSpec["ContainerPort"].new {
  self.name          = "http"
  self.containerPort = 8080
  self.protocol      = "TCP"
}

grpc_port = SubSpec["ContainerPort"].new(
  name: "grpc", containerPort: 9090, protocol: "TCP"
)

puts "2. ContainerPorts:"
puts "   - #{http_port.name}: #{http_port.containerPort}"
puts "   - #{grpc_port.name}: #{grpc_port.containerPort}"
puts


# ══════════════════════════════════════════════════════════════
#  3. ENV VAR — plain values and valueFrom references
# ══════════════════════════════════════════════════════════════

env_plain = SubSpec["EnvVar"].new(name: "APP_ENV", value: "production")

env_secret = SubSpec["EnvVar"].new {
  self.name = "DB_PASSWORD"
  self.valueFrom.secretKeyRef = { name: "db-creds", key: "password" }
}

env_configmap = SubSpec["EnvVar"].new {
  self.name = "LOG_FORMAT"
  self.valueFrom.configMapKeyRef = { name: "app-config", key: "log_format" }
}

env_field = SubSpec["EnvVar"].new {
  self.name = "POD_NAME"
  self.valueFrom.fieldRef = { fieldPath: "metadata.name" }
}

puts "3. EnvVars:"
[env_plain, env_secret, env_configmap, env_field].each do |e|
  puts "   - #{e.name}: valid? #{e.valid?}"
end
puts


# ══════════════════════════════════════════════════════════════
#  4. VOLUME + VOLUME MOUNT — paired definitions
# ══════════════════════════════════════════════════════════════

config_volume = SubSpec["Volume"].new {
  self.name = "config"
  self.configMap = { name: "app-config" }
}

secret_volume = SubSpec["Volume"].new {
  self.name = "tls-certs"
  self.secret = { secretName: "tls-secret" }
}

data_volume = SubSpec["Volume"].new {
  self.name = "data"
  self.emptyDir = { sizeLimit: "1Gi" }
}

pvc_volume = SubSpec["Volume"].new(
  name: "storage",
  persistentVolumeClaim: { claimName: "app-pvc" }
)

config_mount = SubSpec["VolumeMount"].new(
  name: "config", mountPath: "/etc/app", readOnly: true
)

tls_mount = SubSpec["VolumeMount"].new {
  self.name      = "tls-certs"
  self.mountPath = "/etc/tls"
  self.readOnly  = true
}

data_mount = SubSpec["VolumeMount"].new(
  name: "data", mountPath: "/var/data"
)

puts "4. Volumes:"
[config_volume, secret_volume, data_volume, pvc_volume].each do |v|
  puts "   - #{v.name}: valid? #{v.valid?}"
end
puts "   Mounts:"
[config_mount, tls_mount, data_mount].each do |m|
  puts "   - #{m.name} -> #{m.mountPath}"
end
puts


# ══════════════════════════════════════════════════════════════
#  5. PROBE — liveness, readiness, startup
# ══════════════════════════════════════════════════════════════

http_probe = SubSpec["Probe"].new {
  self.httpGet = { path: "/healthz", port: 8080 }
  self.initialDelaySeconds = 15
  self.periodSeconds       = 20
  self.timeoutSeconds      = 3
  self.failureThreshold    = 3
}

tcp_probe = SubSpec["Probe"].new {
  self.tcpSocket = { port: 5432 }
  self.initialDelaySeconds = 5
  self.periodSeconds       = 10
}

exec_probe = SubSpec["Probe"].new {
  self.exec = { command: ["/bin/sh", "-c", "pg_isready -U postgres"] }
  self.initialDelaySeconds = 10
  self.periodSeconds       = 30
}

grpc_probe = SubSpec["Probe"].new {
  self.grpc = { port: 50051 }
  self.periodSeconds = 10
}

puts "5. Probes:"
puts "   - HTTP:  valid? #{http_probe.valid?}"
puts "   - TCP:   valid? #{tcp_probe.valid?}"
puts "   - Exec:  valid? #{exec_probe.valid?}"
puts "   - gRPC:  valid? #{grpc_probe.valid?}"
puts


# ══════════════════════════════════════════════════════════════
#  6. SECURITY CONTEXT — hardened container
# ══════════════════════════════════════════════════════════════

hardened = SubSpec["SecurityContext"].new {
  self.runAsNonRoot             = true
  self.runAsUser                = 1000
  self.runAsGroup               = 1000
  self.readOnlyRootFilesystem   = true
  self.allowPrivilegeEscalation = false
  self.capabilities = { drop: ["ALL"] }
  self.seccompProfile = { type: "RuntimeDefault" }
}

puts "6. SecurityContext:"
puts "   runAsUser: #{hardened.runAsUser}"
puts "   readOnlyRootFilesystem: #{hardened.readOnlyRootFilesystem}"
puts "   valid? #{hardened.valid?}"
puts


# ══════════════════════════════════════════════════════════════
#  7. TOLERATION + TOPOLOGY SPREAD CONSTRAINT
# ══════════════════════════════════════════════════════════════

gpu_toleration = SubSpec["Toleration"].new(
  key: "nvidia.com/gpu", operator: "Exists", effect: "NoSchedule"
)

spot_toleration = SubSpec["Toleration"].new {
  self.key      = "kubernetes.azure.com/scalesetpriority"
  self.operator = "Equal"
  self.value    = "spot"
  self.effect   = "NoSchedule"
}

zone_spread = SubSpec["TopologySpreadConstraint"].new {
  self.maxSkew           = 1
  self.topologyKey       = "topology.kubernetes.io/zone"
  self.whenUnsatisfiable = "DoNotSchedule"
  self.labelSelector = { matchLabels: { app: "web" } }
}

puts "7. Scheduling:"
puts "   Tolerations:"
puts "   - #{gpu_toleration.key}: valid? #{gpu_toleration.valid?}"
puts "   - #{spot_toleration.key}: valid? #{spot_toleration.valid?}"
puts "   TopologySpreadConstraint:"
puts "   - #{zone_spread.topologyKey}: valid? #{zone_spread.valid?}"
puts


# ══════════════════════════════════════════════════════════════
#  8. SERVICE PORT — for Service specs
# ══════════════════════════════════════════════════════════════

svc_http = SubSpec["ServicePort"].new(
  name: "http", port: 80, targetPort: 8080, protocol: "TCP"
)

svc_https = SubSpec["ServicePort"].new {
  self.name        = "https"
  self.port        = 443
  self.targetPort  = 8443
  self.protocol    = "TCP"
  self.appProtocol = "kubernetes.io/h2c"
}

puts "8. ServicePorts:"
puts "   - #{svc_http.name}: #{svc_http.port} -> #{svc_http.targetPort}"
puts "   - #{svc_https.name}: #{svc_https.port} -> #{svc_https.targetPort}"
puts


# ══════════════════════════════════════════════════════════════
#  9. COMPOSING A FULL DEPLOYMENT — tying it all together
# ══════════════════════════════════════════════════════════════

# Build typed sub-specs
web_container = SubSpec["Container"].new {
  self.name  = "web"
  self.image = "nginx:1.27-alpine"
  self.ports = [http_port.to_h]
  self.resources.requests = { cpu: "50m",  memory: "64Mi" }
  self.resources.limits   = { cpu: "200m", memory: "128Mi" }
  self.volumeMounts = [config_mount.to_h, tls_mount.to_h]
  self.livenessProbe  = http_probe.to_h
  self.readinessProbe = http_probe.to_h
  self.securityContext = hardened.to_h
}

sidecar = SubSpec["Container"].new {
  self.name  = "log-shipper"
  self.image = "fluent/fluent-bit:3.2"
  self.resources.requests = { cpu: "25m",  memory: "32Mi" }
  self.resources.limits   = { cpu: "100m", memory: "64Mi" }
  self.volumeMounts = [data_mount.to_h]
  self.securityContext = hardened.to_h
}

# Compose into a Deployment — SubSpec instances auto-coerce
deployment = Kube::Schema["Deployment"].new {
  metadata.name      = "web"
  metadata.namespace = "production"
  metadata.labels    = { app: "web", tier: "frontend" }

  spec.replicas = 3
  spec.selector.matchLabels = { app: "web" }
  spec.strategy.type = "RollingUpdate"
  spec.strategy.rollingUpdate = { maxSurge: 1, maxUnavailable: 0 }

  spec.template.metadata.labels = { app: "web", tier: "frontend" }

  # Auto-coercion: SubSpec instances become plain hashes automatically
  spec.template.spec.containers = [web_container, sidecar]
  spec.template.spec.volumes    = [config_volume, secret_volume, data_volume]

  spec.template.spec.tolerations = [spot_toleration]
  spec.template.spec.topologySpreadConstraints = [zone_spread]

  spec.template.spec.securityContext.fsGroup    = 1000
  spec.template.spec.securityContext.runAsGroup = 1000
  spec.template.spec.serviceAccountName = "web"
  spec.template.spec.terminationGracePeriodSeconds = 30
}

# Also compose a Service using typed ServicePorts
service = Kube::Schema["Service"].new {
  metadata.name      = "web"
  metadata.namespace = "production"
  metadata.labels    = { app: "web" }
  spec.selector = { app: "web" }
  spec.type     = "ClusterIP"
  spec.ports    = [svc_http, svc_https]
}

puts "9. Composed resources:"
puts "   Deployment: #{deployment.metadata[:name]} (#{deployment.spec[:replicas]} replicas)"
puts "   - containers: #{deployment.to_h[:spec][:template][:spec][:containers].map { |c| c[:name] }.join(", ")}"
puts "   - volumes: #{deployment.to_h[:spec][:template][:spec][:volumes].map { |v| v[:name] }.join(", ")}"
puts "   - valid? #{deployment.valid?}"
puts
puts "   Service: #{service.metadata[:name]}"
puts "   - ports: #{service.to_h[:spec][:ports].map { |p| "#{p[:name]}:#{p[:port]}" }.join(", ")}"
puts "   - valid? #{service.valid?}"
puts


# ══════════════════════════════════════════════════════════════
# 10. VALIDATION — catching errors on sub-specs
# ══════════════════════════════════════════════════════════════

puts "10. Validation examples:"

# Missing required field: Container requires "name"
bad_container = SubSpec["Container"].new(image: "nginx")
puts "    Container without name: valid? #{bad_container.valid?}"

begin
  bad_container.valid!
rescue Kube::ValidationError => e
  puts "    Error: #{e.errors.length} error(s)"
  puts "    #{e.message.lines.grep(/required/).first&.strip}"
end
puts

# Wrong type: ports should be an array
bad_ports = SubSpec["Container"].new(name: "app", ports: "not-an-array")
puts "    Container with string ports: valid? #{bad_ports.valid?}"
puts

# VolumeMount missing required fields
bad_mount = SubSpec["VolumeMount"].new(name: "data")
puts "    VolumeMount without mountPath: valid? #{bad_mount.valid?}"

begin
  bad_mount.valid!
rescue Kube::ValidationError => e
  puts "    #{e.message.lines.grep(/required/).first&.strip}"
end
puts


# ══════════════════════════════════════════════════════════════
# 11. DISCOVERY — what sub-specs are available?
# ══════════════════════════════════════════════════════════════

instance = Kube::Schema::Instance.new("1.34")
all_defs = instance.list_definitions

puts "11. Discovery:"
puts "    Total definitions available: #{all_defs.length}"
puts "    Container-related:"
all_defs.select { |d| d.include?("Container") }.each { |d| puts "      - #{d}" }
puts "    Volume-related:"
all_defs.select { |d| d.start_with?("Volume") }.each { |d| puts "      - #{d}" }
puts


# ══════════════════════════════════════════════════════════════
# 12. YAML OUTPUT
# ══════════════════════════════════════════════════════════════

manifest = Manifest.new(deployment, service)

puts "=" * 60
puts "YAML Output:"
puts "=" * 60
puts manifest.to_yaml
