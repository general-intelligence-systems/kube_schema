# frozen_string_literal: true

module Kube
  module Schema
    class Resource

      def initialize(hash = {}, &block)
        deep_symbolize_keys(self.class.defaults.to_h).then do |defaults|

          # apiVersion and kind are never user-settable.
          # They come only from self.class.defaults.
          deep_symbolize_keys(hash).then do |symbolized|
            @data = defaults

            # Lift top-level properties, e.g. spec, metadata, roleRef.
            # Any other attributes are dropped by design.
            self.class.schema_properties.each do |property|
              if symbolized.key?(property)
                @data[property] = symbolized.delete(property)
              end
            end
          end
        end

        if block_given?
          @data.instance_exec(&block)
        end
      end

      # Overridden by the factory in Kube::Schema::Instance.
      # @returns [JSONSchemer::Schema, nil] the schema, once overridden.
      def self.schema
        raise "Kube::Schema::Resource should NOT be instanciated directly"
      end

      def self.schema_properties
        raise "Kube::Schema::Resource should NOT be instanciated directly"
      end

      # Overridden by the factory in Kube::Schema::Instance.
      # @returns [Hash] a frozen Hash like { "apiVersion" => "apps/v1", "kind" => "Deployment" }.
      def self.defaults
        raise "Kube::Schema::Resource should NOT be instanciated directly"
      end

      def valid?
        if self.class.schema.nil?
          true
        else
          self.class.schema.valid?(deep_stringify_keys(to_h))
        end
      end

      # Like #valid? but raises on failure.
      # @returns [Boolean] true if the resource is valid.
      # @raises [Kube::ValidationError] with details on failure.
      def valid!
        if self.class.schema.nil?
          true
        else
          data = deep_stringify_keys(to_h)
          errors = self.class.schema.validate(data).to_a

          unless errors.empty?
            kind = self.class.defaults&.dig("kind")
            name = data.dig("metadata", "name")
            raise Kube::ValidationError.new(errors, kind: kind, name: name, manifest: data)
          end

          true
        end
      end

      # The resource data as a Hash; apiVersion/kind are authoritative.
      # @returns [Hash] the resource data, symbol-keyed.
      def to_h
        defaults = self.class.defaults
        data = deep_compact(@data)
        data = data.reject { |_, v| v.is_a?(Hash) && v.empty? }

        if defaults
          symbolized = deep_symbolize_keys(defaults)
          # Defaults go first, for key ordering, then the rest of the data.
          symbolized.merge(data.reject { |k, _| symbolized.key?(k) })
        else
          data
        end
      end

      # Serializes to clean Kubernetes YAML.
      # @returns [String] the resource as YAML.
      # @raises [Kube::ValidationError] if the resource is not valid.
      def to_yaml
        if valid!
          deep_stringify_keys(to_h).to_yaml
        end
      end

      def ==(other)
        other.is_a?(Resource) && to_h == other.to_h
      end

      # Supports pattern matching, e.g. `resource => {metadata: {name:}}`.
      # @parameter keys [Array(Symbol), nil] the keys requested by the pattern.
      # @returns [Hash] the same nested Hash as #to_h.
      def deconstruct_keys(keys) = to_h

      private

        def deep_compact(obj)
          case obj
          when Kube::Schema::SubSpec
            deep_compact(obj.to_h)
          when Hash
            obj.each_with_object({}) do |(k, v), result|
              compacted = deep_compact(v)
              unless compacted.nil?
                result[k] = compacted
              end
            end
          when Array
            obj.map { |v| deep_compact(v) }
          else
            obj
          end
        end

        def deep_stringify_keys(obj)
          case obj
          when Hash
            obj.each_with_object({}) do |(k, v), result|
              result[k.to_s] = deep_stringify_keys(v)
            end
          when Array
            obj.map { |v| deep_stringify_keys(v) }
          else
            obj
          end
        end

        def deep_symbolize_keys(obj)
          case obj
          when Hash
            obj.each_with_object({}) do |(k, v), result|
              result[k.to_sym] = deep_symbolize_keys(v)
            end
          when Array
            obj.map { |v| deep_symbolize_keys(v) }
          else
            obj
          end
        end
    end
  end
end


__END__

require "kube/schema"

deployment_class = lambda { Kube::Schema["Deployment"] }

full_deployment = lambda {
  Kube::Schema["Deployment"].new {
    metadata.name = "nginx-deployment"
    metadata.namespace = "shopping-cart"
    metadata.labels = { app: "nginx" }
    spec.replicas = 3
    spec.selector.matchLabels = { app: "nginx" }
    spec.template.metadata.labels = { app: "nginx" }
    spec.template.spec.containers = [
      { name: "nginx", image: "nginx:1.19.5", ports: [{ containerPort: 80 }] }
    ]
  }
}

incomplete_deployment = lambda {
  Kube::Schema["Deployment"].new {
    metadata.namespace = "example"
    metadata.name = "example-deployment"
    spec.replicas = 1
    spec.template.spec.containers = [
      { name: "app", image: "ruby:latest" }
    ]
  }
}

describe "Kube::Schema::Resource" do
  describe ".defaults" do
    it "returns apiVersion and kind for a schema-bearing subclass" do
      Kube::Schema["Deployment"].defaults.should == { "apiVersion" => "apps/v1", "kind" => "Deployment" }
    end

    it "returns correct apiVersion for core resources (no group)" do
      Kube::Schema["Pod"].defaults.should == { "apiVersion" => "v1", "kind" => "Pod" }
    end

    it "returns correct apiVersion for grouped resources" do
      Kube::Schema["NetworkPolicy"].defaults.should == { "apiVersion" => "networking.k8s.io/v1", "kind" => "NetworkPolicy" }
    end
  end

  describe "#initialize" do
    it "accepts a hash" do
      resource = Kube::Schema["Deployment"].new("metadata" => { "name" => "my-deploy" })
      resource.to_h[:kind].should == "Deployment"
      resource.to_h[:metadata][:name].should == "my-deploy"
    end

    it "creates an empty resource when no arguments are given" do
      resource = Kube::Schema["Deployment"].new
      resource.to_h[:apiVersion].should == "apps/v1"
      resource.to_h[:kind].should == "Deployment"
    end

    it "accepts a block for DSL-style initialization" do
      resource = Kube::Schema["Deployment"].new {
        metadata.name = "test"
      }
      resource.to_h[:kind].should == "Deployment"
      resource.to_h[:metadata][:name].should == "test"
    end
  end

  describe "#to_h with a schema-bearing subclass" do
    it "automatically includes apiVersion and kind from defaults" do
      resource = deployment_class.().new {
        metadata.name = "test"
      }
      resource.to_h[:apiVersion].should == "apps/v1"
      resource.to_h[:kind].should == "Deployment"
      resource.to_h[:metadata][:name].should == "test"
    end

    it "cannot override apiVersion or kind -- they are authoritative" do
      resource = deployment_class.().new {
        self.apiVersion = "apps/v1beta1"
        self.kind = "NotADeployment"
      }
      resource.to_h[:apiVersion].should == "apps/v1"
      resource.to_h[:kind].should == "Deployment"
    end
  end

  describe "pattern matching" do
    it "destructures nested keys" do
      resource = Kube::Schema["Deployment"].new { metadata.name = "web" }
      resource => {kind: "Deployment", metadata: {name: String => deploy_name}}

      deploy_name.should == "web"
    end

    it "does not match when a nested value differs" do
      resource = Kube::Schema["Deployment"].new { metadata.name = "web" }
      lambda { resource => {metadata: {name: "other"}} }.should.raise(NoMatchingPatternError)
    end
  end

  describe "#==" do
    it "considers two resources equal when their data matches" do
      Kube::Schema["Pod"].new.should == Kube::Schema["Pod"].new
    end

    it "considers two resources unequal when their data differs" do
      Kube::Schema["Pod"].new.should.not == Kube::Schema["Service"].new
    end

    it "is not equal to non-Resource objects" do
      Kube::Schema["Pod"].new.should.not == { "kind" => "Pod" }
    end
  end

  describe "#valid? with a schema-bearing subclass" do
    it "returns true for valid data (apiVersion/kind come from defaults)" do
      deployment_class.().new.valid?.should.be.true
    end

    it "returns false for data violating the schema" do
      resource = deployment_class.().new {
        spec.replicas = "not_a_number"
      }
      resource.valid?.should.be.false
    end
  end

  describe "#valid! with a schema-bearing subclass" do
    it "returns true for valid data" do
      deployment_class.().new.valid!.should.be.true
    end

    it "raises ValidationError for data violating the schema" do
      resource = deployment_class.().new {
        spec.replicas = "not_a_number"
      }
      lambda { resource.valid! }.should.raise(Kube::ValidationError)
    end

    it "includes error details in the exception" do
      resource = deployment_class.().new {
        spec.replicas = "not_a_number"
      }
      error = lambda { resource.valid! }.should.raise(Kube::ValidationError)
      error.message.should.match(/Schema validation failed/)
    end

    it "shows the exact key path and value for type errors" do
      resource = deployment_class.().new {
        metadata.name = "web"
        spec.replicas = "not_a_number"
      }
      error = lambda { resource.valid! }.should.raise(Kube::ValidationError)
      error.message.should.include 'spec.replicas = "not_a_number" — expected integer, got String'
    end

    it "shows which required keys are missing" do
      resource = deployment_class.().new {
        metadata.name = "example"
        spec.replicas = 1
        spec.template.spec.containers = [{ name: "app", image: "ruby:latest" }]
      }
      error = lambda { resource.valid! }.should.raise(Kube::ValidationError)
      error.message.should.include "spec.selector is required but missing"
    end

    it "includes the resource kind in the error header" do
      resource = deployment_class.().new {
        metadata.name = "web"
        spec.replicas = "bad"
      }
      error = lambda { resource.valid! }.should.raise(Kube::ValidationError)
      error.message.should.include "Schema validation failed for Deployment"
    end

    it "includes the resource name in the error header when available" do
      resource = deployment_class.().new {
        metadata.name = "my-app"
        spec.replicas = "bad"
      }
      error = lambda { resource.valid! }.should.raise(Kube::ValidationError)
      error.message.should.include 'Deployment "my-app"'
    end

    it "omits the resource name when metadata.name is not set" do
      resource = deployment_class.().new {
        spec.replicas = "bad"
      }
      error = lambda { resource.valid! }.should.raise(Kube::ValidationError)
      header = error.message.lines.find { |l| l.include?("Schema validation failed") }
      header.should.include "Schema validation failed for Deployment"
      header.should.not.match(/Deployment\s+"/) # no quoted name after kind
    end

    it "exposes the raw errors array" do
      resource = deployment_class.().new {
        spec.replicas = "not_a_number"
      }
      error = lambda { resource.valid! }.should.raise(Kube::ValidationError)
      error.errors.should.be.kind_of Array
      error.errors.should.not.be.empty
    end
  end

  describe "#to_yaml" do
    it "returns clean Kubernetes YAML" do
      yaml = Kube::Schema["Pod"].new.to_yaml

      yaml.should.include "kind: Pod"
      yaml.should.include "apiVersion: v1"
      yaml.should.not.include "!ruby/object"
    end

    it "uses string keys, not symbol keys" do
      yaml = Kube::Schema["Pod"].new.to_yaml

      yaml.should.not.match(/:\w+:/)
      yaml.should.include "kind: Pod"
    end

    it "produces parseable YAML that round-trips" do
      parsed = YAML.safe_load(Kube::Schema["Pod"].new.to_yaml)

      parsed.should.be.kind_of Hash
      parsed["kind"].should == "Pod"
      parsed["apiVersion"].should == "v1"
    end

    it "raises ValidationError when the resource is invalid" do
      resource = Kube::Schema["Deployment"].new {
        spec.replicas = "not_a_number"
      }
      lambda { resource.to_yaml }.should.raise(Kube::ValidationError)
    end

    it "raises ValidationError for an incomplete Deployment missing selector" do
      resource = incomplete_deployment.()
      lambda { resource.to_yaml }.should.raise(Kube::ValidationError)
    end
  end

  describe "#to_yaml with a full Deployment (no manual apiVersion/kind)" do
    it "produces valid Kubernetes Deployment YAML" do
      parsed = YAML.safe_load(full_deployment.().to_yaml)

      parsed.should.be.kind_of Hash
      parsed["apiVersion"].should == "apps/v1"
      parsed["kind"].should == "Deployment"
      parsed["metadata"]["name"].should == "nginx-deployment"
      parsed["metadata"]["namespace"].should == "shopping-cart"
      parsed["metadata"]["labels"].should == { "app" => "nginx" }
      parsed["spec"]["replicas"].should == 3
      parsed["spec"]["selector"]["matchLabels"].should == { "app" => "nginx" }
      parsed["spec"]["template"]["metadata"]["labels"].should == { "app" => "nginx" }

      containers = parsed["spec"]["template"]["spec"]["containers"]
      containers.should.be.kind_of Array
      containers.length.should == 1
      containers[0]["name"].should == "nginx"
      containers[0]["image"].should == "nginx:1.19.5"
      containers[0]["ports"].should == [{ "containerPort" => 80 }]
    end

    it "does not contain Ruby object serialization artifacts" do
      yaml = full_deployment.().to_yaml

      yaml.should.not.include "!ruby/object"
      yaml.should.not.include "table:"
    end

    it "looks like real kubectl YAML output" do
      yaml = full_deployment.().to_yaml

      yaml.should.include "apiVersion: apps/v1"
      yaml.should.include "kind: Deployment"
      yaml.should.include "name: nginx-deployment"
      yaml.should.include "namespace: shopping-cart"
      yaml.should.include "replicas: 3"
      yaml.should.include "image: nginx:1.19.5"
      yaml.should.include "containerPort: 80"
    end

    it "exactly matches real Kubernetes Deployment YAML" do
      expected_yaml = <<~YAML
        ---
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: nginx-deployment
          namespace: shopping-cart
          labels:
            app: nginx
        spec:
          replicas: 3
          selector:
            matchLabels:
              app: nginx
          template:
            metadata:
              labels:
                app: nginx
            spec:
              containers:
              - name: nginx
                image: nginx:1.19.5
                ports:
                - containerPort: 80
      YAML

      full_deployment.().to_yaml.should == expected_yaml
    end

    it "round-trips through YAML.safe_load" do
      parsed = YAML.safe_load(full_deployment.().to_yaml)
      parsed["apiVersion"].should == "apps/v1"
      parsed["kind"].should == "Deployment"
    end
  end

  describe "Deployment schema validation against real Kubernetes YAML" do
    it "rejects an incomplete Deployment missing selector" do
      incomplete_deployment.().valid?.should.be.false
    end

    it "reports specific validation errors for incomplete Deployment" do
      resource = incomplete_deployment.()
      error = lambda { resource.valid! }.should.raise(Kube::ValidationError)
      error.message.should.include "spec.selector is required but missing"
    end

    it "refuses to serialize an incomplete Deployment to YAML" do
      resource = incomplete_deployment.()
      lambda { resource.to_yaml }.should.raise(Kube::ValidationError)
    end

    it "has apiVersion and kind from defaults even when incomplete" do
      h = incomplete_deployment.().to_h
      h[:apiVersion].should == "apps/v1"
      h[:kind].should == "Deployment"
    end
  end

  describe "pattern matching on a named resource" do
    it "destructures with a nested hash pattern" do
      resource = Kube::Schema["Deployment"].new {
        metadata.name = "some-resource"
        metadata.namespace = "prod"
      }
      resource => {kind: String => kind, metadata: {name: deploy_name, namespace: deploy_namespace}}
      [kind, deploy_name, deploy_namespace].should == ["Deployment", "some-resource", "prod"]
    end

    it "matches in a case/in" do
      resource = Kube::Schema["Deployment"].new {
        metadata.name = "some-resource"
        metadata.namespace = "prod"
      }
      matched = case resource
                in {metadata: {name: "some-resource"}} then true
                else false
                end
      matched.should.be.true
    end
  end

  describe "instantiation via Instance lookup" do
    it "returns a Resource instance from .new" do
      deployment_class.().new.should.be.kind_of Kube::Schema::Resource
    end

    it "supports block-based initialization" do
      resource = deployment_class.().new {
        metadata.name = "web"
        metadata.namespace = "prod"
      }
      resource.to_h[:metadata][:name].should == "web"
      resource.to_h[:metadata][:namespace].should == "prod"
    end

    it "has a schema attached to the class" do
      deployment_class.().schema.should.not.be.nil
    end

    it "has defaults attached to the class" do
      deployment_class.().defaults.should.not.be.nil
      deployment_class.().defaults["apiVersion"].should == "apps/v1"
      deployment_class.().defaults["kind"].should == "Deployment"
    end
  end
end
