# frozen_string_literal: true

module Kube
  module Schema
    class Resource

      def initialize(hash = {}, &block)
        deep_symbolize_keys(self.class.defaults.to_h).then do |defaults|

          # You are NEVER allowed to change `apiVersion` or `kind`
          # Therefore, they are ONLY ever set from the self.defaults
          # property.
          deep_symbolize_keys(hash).then do |symbolized|
            @data = defaults

            # This is extracting "top-level" properties from the input hash
            # such as [apiVersion, spec, metadata, roleRef, ...]
            # We then ignore the rest of the attributes by design.
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

      # Gets overridden by the factory in Kube::Schema::Instance
      def self.schema
        raise "Kube::Schema::Resource should NOT be instanciated directly"
      end

      def self.schema_properties
        raise "Kube::Schema::Resource should NOT be instanciated directly"
      end

      # Gets overridden by the factory in Kube::Schema::Instance.
      # Returns a frozen Hash like { "apiVersion" => "apps/v1", "kind" => "Deployment" }
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

      # Like #valid? but raises Kube::ValidationError with details on failure.
      # The error message includes the resource kind and name for context.
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

      # Returns the resource data as a Hash. Defaults (apiVersion, kind)
      # from the schema are authoritative and cannot be overridden --
      # they are facts derived from the GVK metadata.
      def to_h
        defaults = self.class.defaults
        data = deep_compact(@data)
        data = data.reject { |_, v| v.is_a?(Hash) && v.empty? }

        if defaults
          symbolized = deep_symbolize_keys(defaults)
          # Defaults go first (for key ordering), then user data minus
          # any attempts to override the authoritative keys.
          symbolized.merge(data.reject { |k, _| symbolized.key?(k) })
        else
          data
        end
      end

      # Serializes to clean Kubernetes YAML.
      # Raises Kube::ValidationError if the resource is not valid.
      def to_yaml
        if valid!
          deep_stringify_keys(to_h).to_yaml
        end
      end

      def ==(other)
        other.is_a?(Resource) && to_h == other.to_h
      end

      private

        def deep_compact(obj)
          case obj
          when Hash
            obj.each_with_object({}) do |(k, v), result|
              compacted = deep_compact(v)
              result[k] = compacted unless compacted.nil?
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

if __FILE__ == $0
  require "bundler/setup"
  require "rspec/autorun"
  require "kube/schema"

  RSpec.describe Kube::Schema::Resource do
    describe ".defaults" do
      it "returns apiVersion and kind for a schema-bearing subclass" do
        klass = Kube::Schema["Deployment"]
        expect(klass.defaults).to eq({ "apiVersion" => "apps/v1", "kind" => "Deployment" })
      end

      it "returns correct apiVersion for core resources (no group)" do
        klass = Kube::Schema["Pod"]
        expect(klass.defaults).to eq({ "apiVersion" => "v1", "kind" => "Pod" })
      end

      it "returns correct apiVersion for grouped resources" do
        klass = Kube::Schema["NetworkPolicy"]
        expect(klass.defaults).to eq({ "apiVersion" => "networking.k8s.io/v1", "kind" => "NetworkPolicy" })
      end
    end

    describe "#initialize" do
      it "accepts a hash" do
        klass = Kube::Schema["Deployment"]
        resource = klass.new("metadata" => { "name" => "my-deploy" })
        expect(resource.to_h).to include(kind: "Deployment")
        expect(resource.to_h[:metadata][:name]).to eq("my-deploy")
      end

      it "creates an empty resource when no arguments are given" do
        klass = Kube::Schema["Deployment"]
        resource = klass.new
        expect(resource.to_h).to include(apiVersion: "apps/v1", kind: "Deployment")
      end

      it "accepts a block for DSL-style initialization" do
        klass = Kube::Schema["Deployment"]
        resource = klass.new {
          metadata.name = "test"
        }
        expect(resource.to_h).to include(kind: "Deployment")
        expect(resource.to_h[:metadata][:name]).to eq("test")
      end
    end

    describe "#to_h" do
      context "with a schema-bearing subclass" do
        let(:klass) { Kube::Schema["Deployment"] }

        it "automatically includes apiVersion and kind from defaults" do
          resource = klass.new {
            metadata.name = "test"
          }
          expect(resource.to_h[:apiVersion]).to eq("apps/v1")
          expect(resource.to_h[:kind]).to eq("Deployment")
          expect(resource.to_h[:metadata][:name]).to eq("test")
        end

        it "cannot override apiVersion or kind -- they are authoritative" do
          resource = klass.new {
            self.apiVersion = "apps/v1beta1"
            self.kind = "NotADeployment"
          }
          expect(resource.to_h[:apiVersion]).to eq("apps/v1")
          expect(resource.to_h[:kind]).to eq("Deployment")
        end
      end
    end

    describe "#==" do
      it "considers two resources equal when their data matches" do
        a = Kube::Schema["Pod"].new
        b = Kube::Schema["Pod"].new
        expect(a).to eq(b)
      end

      it "considers two resources unequal when their data differs" do
        a = Kube::Schema["Pod"].new
        b = Kube::Schema["Service"].new
        expect(a).not_to eq(b)
      end

      it "is not equal to non-Resource objects" do
        resource = Kube::Schema["Pod"].new
        expect(resource).not_to eq({ "kind" => "Pod" })
      end
    end

    describe "#valid?" do
      context "with a schema-bearing subclass" do
        let(:klass) { Kube::Schema["Deployment"] }

        it "returns true for valid data (apiVersion/kind come from defaults)" do
          resource = klass.new
          expect(resource.valid?).to be true
        end

        it "returns false for data violating the schema" do
          resource = klass.new {
            spec.replicas = "not_a_number"
          }
          expect(resource.valid?).to be false
        end
      end
    end

    describe "#valid!" do
      context "with a schema-bearing subclass" do
        let(:klass) { Kube::Schema["Deployment"] }

        it "returns true for valid data" do
          resource = klass.new
          expect(resource.valid!).to be true
        end

        it "raises ValidationError for data violating the schema" do
          resource = klass.new {
            spec.replicas = "not_a_number"
          }
          expect { resource.valid! }.to raise_error(Kube::ValidationError)
        end

        it "includes error details in the exception" do
          resource = klass.new {
            spec.replicas = "not_a_number"
          }
          expect { resource.valid! }.to raise_error(Kube::ValidationError, /Schema validation failed/)
        end

        it "shows the exact key path and value for type errors" do
          resource = klass.new {
            metadata.name = "web"
            spec.replicas = "not_a_number"
          }
          expect { resource.valid! }.to raise_error(Kube::ValidationError) do |error|
            expect(error.message).to include('spec.replicas = "not_a_number" — expected integer, got String')
          end
        end

        it "shows which required keys are missing" do
          resource = klass.new {
            metadata.name = "example"
            spec.replicas = 1
            spec.template.spec.containers = [{ name: "app", image: "ruby:latest" }]
          }
          expect { resource.valid! }.to raise_error(Kube::ValidationError) do |error|
            expect(error.message).to include("spec.selector is required but missing")
          end
        end

        it "includes the resource kind in the error header" do
          resource = klass.new {
            metadata.name = "web"
            spec.replicas = "bad"
          }
          expect { resource.valid! }.to raise_error(Kube::ValidationError) do |error|
            expect(error.message).to include("Schema validation failed for Deployment")
          end
        end

        it "includes the resource name in the error header when available" do
          resource = klass.new {
            metadata.name = "my-app"
            spec.replicas = "bad"
          }
          expect { resource.valid! }.to raise_error(Kube::ValidationError) do |error|
            expect(error.message).to include('Deployment "my-app"')
          end
        end

        it "omits the resource name when metadata.name is not set" do
          resource = klass.new {
            spec.replicas = "bad"
          }
          expect { resource.valid! }.to raise_error(Kube::ValidationError) do |error|
            header = error.message.lines.find { |l| l.include?("Schema validation failed") }
            expect(header).to include("Schema validation failed for Deployment")
            expect(header).not_to match(/Deployment\s+"/)  # no quoted name after kind
          end
        end

        it "exposes the raw errors array" do
          resource = klass.new {
            spec.replicas = "not_a_number"
          }
          begin
            resource.valid!
          rescue Kube::ValidationError => e
            expect(e.errors).to be_an(Array)
            expect(e.errors).not_to be_empty
          end
        end
      end
    end

    describe "#to_yaml" do
      it "returns clean Kubernetes YAML" do
        resource = Kube::Schema["Pod"].new
        yaml = resource.to_yaml

        expect(yaml).to include("kind: Pod")
        expect(yaml).to include("apiVersion: v1")
        expect(yaml).not_to include("BlackHoleStruct")
        expect(yaml).not_to include("!ruby/object")
      end

      it "uses string keys, not symbol keys" do
        resource = Kube::Schema["Pod"].new
        yaml = resource.to_yaml

        expect(yaml).not_to match(/:\w+:/)
        expect(yaml).to include("kind: Pod")
      end

      it "produces parseable YAML that round-trips" do
        resource = Kube::Schema["Pod"].new
        parsed = YAML.safe_load(resource.to_yaml)

        expect(parsed).to be_a(Hash)
        expect(parsed["kind"]).to eq("Pod")
        expect(parsed["apiVersion"]).to eq("v1")
      end

      it "raises ValidationError when the resource is invalid" do
        klass = Kube::Schema["Deployment"]
        resource = klass.new {
          spec.replicas = "not_a_number"
        }
        expect { resource.to_yaml }.to raise_error(Kube::ValidationError)
      end

      it "raises ValidationError for an incomplete Deployment missing selector" do
        klass = Kube::Schema["Deployment"]
        resource = klass.new {
          metadata.namespace = "example"
          metadata.name = "example-deployment"
          spec.replicas = 1
          spec.template.spec.containers = [
            { name: "app", image: "ruby:latest" }
          ]
        }
        expect { resource.to_yaml }.to raise_error(Kube::ValidationError)
      end

      context "with a full Deployment (no manual apiVersion/kind)" do
        let(:deployment) do
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
        end

        it "produces valid Kubernetes Deployment YAML" do
          yaml = deployment.to_yaml
          parsed = YAML.safe_load(yaml)

          expect(parsed).to be_a(Hash)
          expect(parsed["apiVersion"]).to eq("apps/v1")
          expect(parsed["kind"]).to eq("Deployment")
          expect(parsed["metadata"]["name"]).to eq("nginx-deployment")
          expect(parsed["metadata"]["namespace"]).to eq("shopping-cart")
          expect(parsed["metadata"]["labels"]).to eq({ "app" => "nginx" })
          expect(parsed["spec"]["replicas"]).to eq(3)
          expect(parsed["spec"]["selector"]["matchLabels"]).to eq({ "app" => "nginx" })
          expect(parsed["spec"]["template"]["metadata"]["labels"]).to eq({ "app" => "nginx" })

          containers = parsed["spec"]["template"]["spec"]["containers"]
          expect(containers).to be_an(Array)
          expect(containers.length).to eq(1)
          expect(containers[0]["name"]).to eq("nginx")
          expect(containers[0]["image"]).to eq("nginx:1.19.5")
          expect(containers[0]["ports"]).to eq([{ "containerPort" => 80 }])
        end

        it "does not contain Ruby object serialization artifacts" do
          yaml = deployment.to_yaml

          expect(yaml).not_to include("!ruby/object")
          expect(yaml).not_to include("BlackHoleStruct")
          expect(yaml).not_to include("table:")
        end

        it "looks like real kubectl YAML output" do
          yaml = deployment.to_yaml

          expect(yaml).to include("apiVersion: apps/v1")
          expect(yaml).to include("kind: Deployment")
          expect(yaml).to include("name: nginx-deployment")
          expect(yaml).to include("namespace: shopping-cart")
          expect(yaml).to include("replicas: 3")
          expect(yaml).to include("image: nginx:1.19.5")
          expect(yaml).to include("containerPort: 80")
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

          expect(deployment.to_yaml).to eq(expected_yaml)
        end

        it "round-trips through YAML.safe_load" do
          parsed = YAML.safe_load(deployment.to_yaml)
          expect(parsed["apiVersion"]).to eq("apps/v1")
          expect(parsed["kind"]).to eq("Deployment")
        end
      end
    end

    describe "Deployment schema validation against real Kubernetes YAML" do
      let(:klass) { Kube::Schema["Deployment"] }

      let(:incomplete_deployment) do
        klass.new {
          metadata.namespace = "example"
          metadata.name = "example-deployment"
          spec.replicas = 1
          spec.template.spec.containers = [
            { name: "app", image: "ruby:latest" }
          ]
        }
      end

      it "rejects an incomplete Deployment missing selector" do
        expect(incomplete_deployment.valid?).to be false
      end

      it "reports specific validation errors for incomplete Deployment" do
        expect { incomplete_deployment.valid! }.to raise_error(Kube::ValidationError) do |error|
          expect(error.message).to include("spec.selector is required but missing")
        end
      end

      it "refuses to serialize an incomplete Deployment to YAML" do
        expect { incomplete_deployment.to_yaml }.to raise_error(Kube::ValidationError)
      end

      it "has apiVersion and kind from defaults even when incomplete" do
        h = incomplete_deployment.to_h
        expect(h[:apiVersion]).to eq("apps/v1")
        expect(h[:kind]).to eq("Deployment")
      end
    end

    describe "instantiation via Instance lookup" do
      let(:klass) { Kube::Schema["Deployment"] }

      it "returns a Resource instance from .new" do
        resource = klass.new
        expect(resource).to be_a(described_class)
      end

      it "supports block-based initialization" do
        resource = klass.new {
          metadata.name = "web"
          metadata.namespace = "prod"
        }
        expect(resource.to_h[:metadata][:name]).to eq("web")
        expect(resource.to_h[:metadata][:namespace]).to eq("prod")
      end

      it "has a schema attached to the class" do
        expect(klass.schema).not_to be_nil
      end

      it "has defaults attached to the class" do
        expect(klass.defaults).not_to be_nil
        expect(klass.defaults["apiVersion"]).to eq("apps/v1")
        expect(klass.defaults["kind"]).to eq("Deployment")
      end
    end
  end
end
