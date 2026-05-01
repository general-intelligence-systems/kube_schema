# The Block DSL

This guide covers the block DSL for defining Kubernetes resources with nested attributes.

## Nested Attributes

No intermediate hashes, no string keys:

```ruby
deploy = Kube::Schema["Deployment"].new {
  metadata.name = "web"
  metadata.namespace = "prod"
  metadata.labels = { app: "web" }

  spec.replicas = 3
  spec.selector.matchLabels = { app: "web" }

  spec.template.metadata.labels = { app: "web" }
  spec.template.spec.containers = [
    { name: "app", image: "nginx:1.27", ports: [{ containerPort: 80 }] }
  ]
}
```

`apiVersion` and `kind` are derived from the schema automatically:

```ruby
deploy.to_h[:apiVersion]  # => "apps/v1"
deploy.to_h[:kind]        # => "Deployment"
```

## Subclassing

```ruby
class RailsApp < Kube::Schema["Deployment"]
  def default_image
    "ruby:3.4"
  end
end

app = RailsApp.new {
  metadata.name = "rails"
  spec.template.spec.containers = [
    { name: "web", image: "myapp:latest" }
  ]
}

app.default_image  # => "ruby:3.4"
app.valid?         # => true
```
