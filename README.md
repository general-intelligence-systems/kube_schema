# Kube::Schema

Ruby objects for Kubernetes OpenAPI schemas.

## Installation

```ruby
gem "kube_schema"
```

## Usage

```ruby
Deployment = Kube::Schema["1.33.6"]["Deployment"]

app = Deployment.new do
  self.description = "My app"
  self.type = "custom"
end

app.description   # => "My app"
app.type          # => "custom"
app.properties    # => {"apiVersion" => ..., "kind" => ..., ...}
```

```ruby
class RailsApp < Kube::Schema["1.33.6"]["Deployment"]
  def is_the_best?
    true
  end
end

app = RailsApp.new
app.is_the_best?  # => true
app.description   # => "Deployment enables declarative updates for Pods and ReplicaSets."
```
