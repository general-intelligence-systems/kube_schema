# Manifests

This guide covers grouping resources into multi-document YAML manifests.

## Creating a Manifest

```ruby
manifest = Kube::Schema::Manifest.new

manifest << Kube::Schema["Namespace"].new {
  metadata.name = "prod"
}

manifest << Kube::Schema["Deployment"].new {
  metadata.name = "web"
  metadata.namespace = "prod"
  spec.replicas = 3
  spec.template.spec.containers = [
    { name: "app", image: "nginx:1.27" }
  ]
}

manifest << Kube::Schema["Service"].new {
  metadata.name = "web"
  metadata.namespace = "prod"
  spec.selector = { app: "web" }
  spec.ports = [{ port: 80, targetPort: 8080 }]
}

puts manifest.to_yaml
```

## File I/O

```ruby
# Write
manifest.write("cluster.yaml")

# Read
loaded = Kube::Schema::Manifest.open("cluster.yaml")

# Modify and write back
loaded << new_resource
loaded.write
```

## Composition

Manifests flatten into each other. No nesting.

```ruby
infra = Kube::Schema::Manifest.new(namespace, configmap, secret)
app   = Kube::Schema::Manifest.new(deployment, service)

combined = Kube::Schema::Manifest.new
combined << infra
combined << app
combined.size  # => 5
```

## Enumerable

```ruby
manifest.map { |r| r.to_h[:kind] }
manifest.select { |r| r.to_h[:kind] == "Service" }
manifest.any? { |r| r.to_h[:kind] == "Pod" }
manifest.count
```
