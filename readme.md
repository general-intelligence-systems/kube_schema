# kube_schema

Ruby objects for every Kubernetes resource. Validated against the real OpenAPI spec.

```ruby
Kube::Schema["Deployment"].new {
  metadata.name = "web"
  metadata.namespace = "prod"
  spec.replicas = 3
  spec.template.spec.containers = [
    { name: "app", image: "nginx:1.27", ports: [{ containerPort: 80 }] }
  ]
}
```

No YAML. No hash literals. Just Ruby blocks that know their schema.

## Usage

Please see the [project documentation](https://general-intelligence-systems.github.io/kube_schema/) for more details.

  - [Getting Started](https://general-intelligence-systems.github.io/kube_schema/guides/getting-started/index) - This guide walks you through installing kube_schema and creating your first Kubernetes resource object.

  - [The Block DSL](https://general-intelligence-systems.github.io/kube_schema/guides/block-dsl/index) - This guide covers the block DSL for defining Kubernetes resources with nested attributes.

  - [Validation](https://general-intelligence-systems.github.io/kube_schema/guides/validation/index) - This guide covers schema validation against the full Kubernetes OpenAPI spec.

  - [Manifests](https://general-intelligence-systems.github.io/kube_schema/guides/manifests/index) - This guide covers grouping resources into multi-document YAML manifests.

  - [Schema Versions](https://general-intelligence-systems.github.io/kube_schema/guides/schema-versions/index) - This guide covers working with different Kubernetes schema versions.

## Related Projects

- [kube_cluster](https://github.com/general-intelligence-systems/kube_cluster) -- OOP resource management with dirty tracking and persistence
- [kube_kubectl](https://github.com/general-intelligence-systems/kube_ctl) -- Ruby DSL that compiles to kubectl and helm commands
- [kube_kit](https://github.com/general-intelligence-systems/kube_kit) -- Generators for kube_cluster projects
- [kube_engine](https://github.com/general-intelligence-systems/kube_engine) -- Kubernetes engine

## License

Apache-2.0
