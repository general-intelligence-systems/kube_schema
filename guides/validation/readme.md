# Validation

This guide covers schema validation against the full Kubernetes OpenAPI spec.

## Basic Validation

```ruby
deploy.valid?   # => true

bad = Kube::Schema["Deployment"].new {
  self.apiVersion = 12345
}

bad.valid?   # => false

bad.valid!
# Kube::ValidationError: Schema validation failed for Deployment:
#   - apiVersion = 12345 -- expected string, got Integer
```

## Serialization Safety

`to_yaml` refuses to serialize invalid resources:

```ruby
bad.to_yaml  # raises Kube::ValidationError
```

## Error Messages

Validation errors render annotated YAML with color-coded diagnostics. Error lines are highlighted in red, missing required keys are injected inline, and each problem gets a clear explanation.
