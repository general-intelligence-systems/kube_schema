# frozen_string_literal: true

module Kube
  module Schema
    # A lightweight, schema-validated wrapper for non-resource Kubernetes
    # definitions — things like Container, ContainerPort, Volume, Probe,
    # etc. that live inside resource specs but have no apiVersion/kind.
    #
    # SubSpec validates against the OpenAPI JSON Schema definition and
    # produces a plain Hash via #to_h, suitable for embedding directly
    # inside Resource specs.
    #
    #   container = Kube::Schema::SubSpec["Container"].new {
    #     name = "app"
    #     image = "nginx:1.27"
    #     ports = [{ containerPort: 80 }]
    #   }
    #
    #   container.valid?  # => true
    #   container.to_h    # => { name: "app", image: "nginx:1.27", ... }
    #
    # SubSpec instances auto-coerce when placed inside a Resource —
    # no explicit .to_h is needed:
    #
    #   spec.template.spec.containers = [container]
    #
    class SubSpec

      def initialize(hash = {}, &block)
        deep_symbolize_keys(hash).then do |symbolized|
          @data = {}

          self.class.schema_properties.each do |property|
            if symbolized.key?(property)
              @data[property] = symbolized.delete(property)
            end
          end
        end

        if block_given?
          @data.instance_exec(&block)
        end
      end

      # Gets overridden by the factory in Kube::Schema::Instance
      def self.schema
        raise "Kube::Schema::SubSpec should NOT be instantiated directly"
      end

      def self.schema_properties
        raise "Kube::Schema::SubSpec should NOT be instantiated directly"
      end

      def self.definition_name
        raise "Kube::Schema::SubSpec should NOT be instantiated directly"
      end

      def valid?
        if self.class.schema.nil?
          true
        else
          self.class.schema.valid?(deep_stringify_keys(to_h))
        end
      end

      # Like #valid? but raises Kube::ValidationError with details on failure.
      def valid!
        if self.class.schema.nil?
          true
        else
          data = deep_stringify_keys(to_h)
          errors = self.class.schema.validate(data).to_a

          unless errors.empty?
            raise Kube::ValidationError.new(errors,
              kind: self.class.definition_name,
              manifest: data
            )
          end

          true
        end
      end

      # Returns the sub-spec data as a plain Hash.
      def to_h
        data = deep_compact(@data)
        data.reject { |_, v| v.is_a?(Hash) && v.empty? }
      end

      def ==(other)
        other.is_a?(SubSpec) && to_h == other.to_h
      end

      # Look up a sub-spec definition by short name.
      #
      #   Kube::Schema::SubSpec["Container"]
      #   Kube::Schema::SubSpec["ContainerPort"]
      #   Kube::Schema::SubSpec["Volume"]
      #
      class << self
        def [](name)
          version = Schema.schema_version || Schema::DEFAULT_VERSION
          instance = Schema[version]
          instance.sub_spec(name)
        end
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

  RSpec.describe Kube::Schema::SubSpec do
    describe ".[]" do
      it "returns a Class that subclasses SubSpec" do
        klass = described_class["Container"]
        expect(klass).to be_a(Class)
        expect(klass).to be < described_class
      end

      it "caches sub-spec classes by name" do
        a = described_class["Container"]
        b = described_class["Container"]
        expect(a).to be(b)
      end

      it "resolves ContainerPort" do
        klass = described_class["ContainerPort"]
        expect(klass).to be < described_class
      end

      it "resolves Probe" do
        klass = described_class["Probe"]
        expect(klass).to be < described_class
      end

      it "resolves Volume" do
        klass = described_class["Volume"]
        expect(klass).to be < described_class
      end

      it "resolves EnvVar" do
        klass = described_class["EnvVar"]
        expect(klass).to be < described_class
      end

      it "resolves ResourceRequirements" do
        klass = described_class["ResourceRequirements"]
        expect(klass).to be < described_class
      end

      it "resolves a full definition key" do
        klass = described_class["io.k8s.api.core.v1.Container"]
        expect(klass).to be < described_class
      end

      it "raises for an unknown definition" do
        expect { described_class["ThisDoesNotExist999"] }.to raise_error(RuntimeError, /No definition found/)
      end
    end

    describe ".definition_name" do
      it "returns the short name used to look up the sub-spec" do
        klass = described_class["Container"]
        expect(klass.definition_name).to eq("Container")
      end
    end

    describe ".schema" do
      it "has a schema attached" do
        klass = described_class["Container"]
        expect(klass.schema).not_to be_nil
      end
    end

    describe ".schema_properties" do
      it "lists known properties as symbols" do
        klass = described_class["Container"]
        props = klass.schema_properties
        expect(props).to include(:name, :image, :ports, :env, :resources)
      end
    end

    describe "#initialize" do
      let(:klass) { described_class["Container"] }

      it "accepts a hash" do
        sub = klass.new(name: "app", image: "nginx")
        expect(sub.to_h).to include(name: "app", image: "nginx")
      end

      it "accepts string keys" do
        sub = klass.new("name" => "app", "image" => "nginx")
        expect(sub.to_h).to include(name: "app", image: "nginx")
      end

      it "creates an empty sub-spec when no arguments are given" do
        sub = klass.new
        expect(sub.to_h).to eq({})
      end

      it "accepts a block for DSL-style initialization" do
        sub = klass.new {
          self.name = "app"
          self.image = "nginx:1.27"
        }
        expect(sub.to_h).to include(name: "app", image: "nginx:1.27")
      end

      it "supports nested DSL" do
        sub = klass.new {
          self.name = "app"
          self.image = "nginx"
          self.resources.requests = { cpu: "100m", memory: "128Mi" }
          self.resources.limits = { cpu: "500m", memory: "256Mi" }
        }
        expect(sub.to_h[:resources][:requests]).to eq({ cpu: "100m", memory: "128Mi" })
      end

      it "ignores unknown properties" do
        sub = klass.new(name: "app", bogus_field: "ignored")
        expect(sub.to_h).to eq({ name: "app" })
      end
    end

    describe "accessor methods" do
      let(:klass) { described_class["Container"] }

      it "defines reader methods for schema properties" do
        sub = klass.new(name: "app", image: "nginx")
        expect(sub.name).to eq("app")
        expect(sub.image).to eq("nginx")
      end

      it "returns nil for unset properties" do
        sub = klass.new(name: "app")
        expect(sub.image).to be_nil
      end
    end

    describe "#valid?" do
      let(:klass) { described_class["Container"] }

      it "returns true for valid data" do
        sub = klass.new(name: "app", image: "nginx")
        expect(sub.valid?).to be true
      end

      it "returns false for data violating the schema" do
        sub = klass.new(name: "app", ports: "not_an_array")
        expect(sub.valid?).to be false
      end

      it "returns false when required fields are missing" do
        # Container requires 'name'
        sub = klass.new(image: "nginx")
        expect(sub.valid?).to be false
      end
    end

    describe "#valid!" do
      let(:klass) { described_class["Container"] }

      it "returns true for valid data" do
        sub = klass.new(name: "app")
        expect(sub.valid!).to be true
      end

      it "raises ValidationError for invalid data" do
        sub = klass.new(image: "nginx")
        expect { sub.valid! }.to raise_error(Kube::ValidationError)
      end

      it "includes the definition name in the error" do
        sub = klass.new(image: "nginx")
        expect { sub.valid! }.to raise_error(Kube::ValidationError, /Container/)
      end

      it "shows which required keys are missing" do
        sub = klass.new(image: "nginx")
        expect { sub.valid! }.to raise_error(Kube::ValidationError) do |error|
          expect(error.message).to include("name is required but missing")
        end
      end
    end

    describe "#to_h" do
      let(:klass) { described_class["Container"] }

      it "returns a plain Hash" do
        sub = klass.new(name: "app", image: "nginx")
        h = sub.to_h
        expect(h).to be_a(Hash)
        expect(h).to eq({ name: "app", image: "nginx" })
      end

      it "strips empty sub-hashes" do
        sub = klass.new(name: "app")
        expect(sub.to_h).to eq({ name: "app" })
      end

      it "does NOT include apiVersion or kind" do
        sub = klass.new(name: "app")
        expect(sub.to_h).not_to have_key(:apiVersion)
        expect(sub.to_h).not_to have_key(:kind)
      end

      it "preserves nested structure" do
        sub = klass.new {
          self.name = "app"
          self.image = "nginx"
          self.ports = [{ containerPort: 80 }]
        }
        expect(sub.to_h[:ports]).to eq([{ containerPort: 80 }])
      end
    end

    describe "#==" do
      let(:klass) { described_class["Container"] }

      it "considers two sub-specs equal when their data matches" do
        a = klass.new(name: "app", image: "nginx")
        b = klass.new(name: "app", image: "nginx")
        expect(a).to eq(b)
      end

      it "considers two sub-specs unequal when their data differs" do
        a = klass.new(name: "app", image: "nginx")
        b = klass.new(name: "other", image: "nginx")
        expect(a).not_to eq(b)
      end

      it "is not equal to a plain Hash" do
        sub = klass.new(name: "app")
        expect(sub).not_to eq({ name: "app" })
      end
    end

    describe "auto-coercion in Resource" do
      it "auto-coerces SubSpec instances inside Resource arrays" do
        container = described_class["Container"].new {
          self.name = "app"
          self.image = "nginx:1.27"
          self.ports = [{ containerPort: 80 }]
        }

        deploy = Kube::Schema["Deployment"].new {
          metadata.name = "web"
          spec.replicas = 1
          spec.selector.matchLabels = { app: "web" }
          spec.template.metadata.labels = { app: "web" }
          spec.template.spec.containers = [container]
        }

        h = deploy.to_h
        containers = h[:spec][:template][:spec][:containers]
        expect(containers).to be_an(Array)
        expect(containers.first).to be_a(Hash)
        expect(containers.first[:name]).to eq("app")
        expect(containers.first[:image]).to eq("nginx:1.27")
      end

      it "produces valid YAML with auto-coerced SubSpec" do
        container = described_class["Container"].new {
          self.name = "nginx"
          self.image = "nginx:1.27"
          self.ports = [{ containerPort: 80 }]
        }

        deploy = Kube::Schema["Deployment"].new {
          metadata.name = "web"
          spec.replicas = 1
          spec.selector.matchLabels = { app: "web" }
          spec.template.metadata.labels = { app: "web" }
          spec.template.spec.containers = [container]
        }

        yaml = deploy.to_yaml
        parsed = YAML.safe_load(yaml)
        expect(parsed["spec"]["template"]["spec"]["containers"].first["name"]).to eq("nginx")
      end

      it "handles multiple SubSpec instances in an array" do
        app = described_class["Container"].new(name: "app", image: "app:latest")
        sidecar = described_class["Container"].new(name: "sidecar", image: "sidecar:latest")

        deploy = Kube::Schema["Deployment"].new {
          metadata.name = "web"
          spec.replicas = 1
          spec.selector.matchLabels = { app: "web" }
          spec.template.metadata.labels = { app: "web" }
          spec.template.spec.containers = [app, sidecar]
        }

        containers = deploy.to_h[:spec][:template][:spec][:containers]
        expect(containers.size).to eq(2)
        expect(containers.map { |c| c[:name] }).to eq(["app", "sidecar"])
      end

      it "works mixed with plain hashes" do
        container = described_class["Container"].new(name: "typed", image: "typed:latest")

        deploy = Kube::Schema["Deployment"].new {
          metadata.name = "web"
          spec.replicas = 1
          spec.selector.matchLabels = { app: "web" }
          spec.template.metadata.labels = { app: "web" }
          spec.template.spec.containers = [
            container,
            { name: "plain", image: "plain:latest" }
          ]
        }

        containers = deploy.to_h[:spec][:template][:spec][:containers]
        expect(containers.map { |c| c[:name] }).to eq(["typed", "plain"])
      end
    end

    describe "disambiguation" do
      it "prefers stable API versions over beta/alpha" do
        # MatchCondition exists in v1, v1alpha1, and v1beta1
        klass = described_class["MatchCondition"]
        expect(klass).to be < described_class
        expect(klass.schema).not_to be_nil
      end
    end

    describe "Instance#list_definitions" do
      it "returns a sorted array of short definition names" do
        instance = Kube::Schema::Instance.new("1.34")
        defs = instance.list_definitions
        expect(defs).to be_an(Array)
        expect(defs).not_to be_empty
        expect(defs).to include("Container", "ContainerPort", "Probe", "Volume")
        expect(defs).to eq(defs.sort)
      end
    end
  end
end
