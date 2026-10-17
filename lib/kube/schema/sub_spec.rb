# frozen_string_literal: true

module Kube
  module Schema
    # A schema-validated wrapper for non-resource Kubernetes definitions.
    #
    # @example
    #   container = Kube::Schema::SubSpec["Container"].new {
    #     name = "app"
    #     image = "nginx:1.27"
    #     ports = [{ containerPort: 80 }]
    #   }
    #   container.valid?  # => true
    #   container.to_h    # => { name: "app", image: "nginx:1.27", ... }
    #
    # @example Auto-coerces inside a Resource, no #to_h needed
    #   spec.template.spec.containers = [container]
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

      # Overridden by the factory in Kube::Schema::Instance.
      # @returns [JSONSchemer::Schema, nil] the schema, once overridden.
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

      # Like #valid? but raises on failure.
      # @returns [Boolean] true if the sub-spec is valid.
      # @raises [Kube::ValidationError] with details on failure.
      def valid!
        if self.class.schema.nil?
          true
        else
          data = deep_stringify_keys(to_h)
          errors = self.class.schema.validate(data).to_a

          unless errors.empty?
            raise Kube::ValidationError.new(
              errors,
              kind:     self.class.definition_name,
              manifest: data,
            )
          end

          true
        end
      end

      # Returns the sub-spec data as a plain Hash.
      # @returns [Hash] the sub-spec data, symbol-keyed.
      def to_h
        data = deep_compact(@data)
        data.reject { |_, v| v.is_a?(Hash) && v.empty? }
      end

      def ==(other)
        other.is_a?(SubSpec) && to_h == other.to_h
      end

      # Look up a sub-spec definition by short name.
      #
      # @example
      #   Kube::Schema::SubSpec["Container"]
      #   Kube::Schema::SubSpec["ContainerPort"]
      #   Kube::Schema::SubSpec["Volume"]
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

sub_spec = Kube::Schema::SubSpec
container = lambda { sub_spec["Container"] }

describe "Kube::Schema::SubSpec" do
  describe ".[]" do
    it "returns a Class that subclasses SubSpec" do
      klass = sub_spec["Container"]
      klass.should.be.kind_of Class
      klass.should.be < sub_spec
    end

    it "caches sub-spec classes by name" do
      sub_spec["Container"].should.be.identical_to sub_spec["Container"]
    end

    it "resolves ContainerPort" do
      sub_spec["ContainerPort"].should.be < sub_spec
    end

    it "resolves Probe" do
      sub_spec["Probe"].should.be < sub_spec
    end

    it "resolves Volume" do
      sub_spec["Volume"].should.be < sub_spec
    end

    it "resolves EnvVar" do
      sub_spec["EnvVar"].should.be < sub_spec
    end

    it "resolves ResourceRequirements" do
      sub_spec["ResourceRequirements"].should.be < sub_spec
    end

    it "resolves a full definition key" do
      sub_spec["io.k8s.api.core.v1.Container"].should.be < sub_spec
    end

    it "raises for an unknown definition" do
      error = lambda { sub_spec["ThisDoesNotExist999"] }.should.raise(RuntimeError)
      error.message.should.match(/No definition found/)
    end
  end

  describe ".definition_name" do
    it "returns the short name used to look up the sub-spec" do
      container.().definition_name.should == "Container"
    end
  end

  describe ".schema" do
    it "has a schema attached" do
      container.().schema.should.not.be.nil
    end
  end

  describe ".schema_properties" do
    it "lists known properties as symbols" do
      props = container.().schema_properties
      [:name, :image, :ports, :env, :resources].each { |prop| props.should.include prop }
    end
  end

  describe "#initialize" do
    it "accepts a hash" do
      sub = container.().new(name: "app", image: "nginx")
      sub.to_h[:name].should == "app"
      sub.to_h[:image].should == "nginx"
    end

    it "accepts string keys" do
      sub = container.().new("name" => "app", "image" => "nginx")
      sub.to_h[:name].should == "app"
      sub.to_h[:image].should == "nginx"
    end

    it "creates an empty sub-spec when no arguments are given" do
      container.().new.to_h.should == {}
    end

    it "accepts a block for DSL-style initialization" do
      sub = container.().new {
        self.name = "app"
        self.image = "nginx:1.27"
      }
      sub.to_h[:name].should == "app"
      sub.to_h[:image].should == "nginx:1.27"
    end

    it "supports nested DSL" do
      sub = container.().new {
        self.name = "app"
        self.image = "nginx"
        self.resources.requests = { cpu: "100m", memory: "128Mi" }
        self.resources.limits = { cpu: "500m", memory: "256Mi" }
      }
      sub.to_h[:resources][:requests].should == { cpu: "100m", memory: "128Mi" }
    end

    it "ignores unknown properties" do
      container.().new(name: "app", bogus_field: "ignored").to_h.should == { name: "app" }
    end
  end

  describe "accessor methods" do
    it "defines reader methods for schema properties" do
      sub = container.().new(name: "app", image: "nginx")
      sub.name.should == "app"
      sub.image.should == "nginx"
    end

    it "returns nil for unset properties" do
      container.().new(name: "app").image.should.be.nil
    end
  end

  describe "#valid?" do
    it "returns true for valid data" do
      container.().new(name: "app", image: "nginx").valid?.should.be.true
    end

    it "returns false for data violating the schema" do
      container.().new(name: "app", ports: "not_an_array").valid?.should.be.false
    end

    it "returns false when required fields are missing" do
      # Container requires 'name'
      container.().new(image: "nginx").valid?.should.be.false
    end
  end

  describe "#valid!" do
    it "returns true for valid data" do
      container.().new(name: "app").valid!.should.be.true
    end

    it "raises ValidationError for invalid data" do
      sub = container.().new(image: "nginx")
      lambda { sub.valid! }.should.raise(Kube::ValidationError)
    end

    it "includes the definition name in the error" do
      sub = container.().new(image: "nginx")
      error = lambda { sub.valid! }.should.raise(Kube::ValidationError)
      error.message.should.match(/Container/)
    end

    it "shows which required keys are missing" do
      sub = container.().new(image: "nginx")
      error = lambda { sub.valid! }.should.raise(Kube::ValidationError)
      error.message.should.include "name is required but missing"
    end
  end

  describe "#to_h" do
    it "returns a plain Hash" do
      h = container.().new(name: "app", image: "nginx").to_h
      h.should.be.kind_of Hash
      h.should == { name: "app", image: "nginx" }
    end

    it "strips empty sub-hashes" do
      container.().new(name: "app").to_h.should == { name: "app" }
    end

    it "does NOT include apiVersion or kind" do
      h = container.().new(name: "app").to_h
      h.should.not.include :apiVersion
      h.should.not.include :kind
    end

    it "preserves nested structure" do
      sub = container.().new {
        self.name = "app"
        self.image = "nginx"
        self.ports = [{ containerPort: 80 }]
      }
      sub.to_h[:ports].should == [{ containerPort: 80 }]
    end
  end

  describe "#==" do
    it "considers two sub-specs equal when their data matches" do
      a = container.().new(name: "app", image: "nginx")
      b = container.().new(name: "app", image: "nginx")
      a.should == b
    end

    it "considers two sub-specs unequal when their data differs" do
      a = container.().new(name: "app", image: "nginx")
      b = container.().new(name: "other", image: "nginx")
      a.should.not == b
    end

    it "is not equal to a plain Hash" do
      container.().new(name: "app").should.not == { name: "app" }
    end
  end

  describe "auto-coercion in Resource" do
    it "auto-coerces SubSpec instances inside Resource arrays" do
      app = container.().new {
        self.name = "app"
        self.image = "nginx:1.27"
        self.ports = [{ containerPort: 80 }]
      }

      deploy = Kube::Schema["Deployment"].new {
        metadata.name = "web"
        spec.replicas = 1
        spec.selector.matchLabels = { app: "web" }
        spec.template.metadata.labels = { app: "web" }
        spec.template.spec.containers = [app]
      }

      containers = deploy.to_h[:spec][:template][:spec][:containers]
      containers.should.be.kind_of Array
      containers.first.should.be.kind_of Hash
      containers.first[:name].should == "app"
      containers.first[:image].should == "nginx:1.27"
    end

    it "produces valid YAML with auto-coerced SubSpec" do
      nginx = container.().new {
        self.name = "nginx"
        self.image = "nginx:1.27"
        self.ports = [{ containerPort: 80 }]
      }

      deploy = Kube::Schema["Deployment"].new {
        metadata.name = "web"
        spec.replicas = 1
        spec.selector.matchLabels = { app: "web" }
        spec.template.metadata.labels = { app: "web" }
        spec.template.spec.containers = [nginx]
      }

      parsed = YAML.safe_load(deploy.to_yaml)
      parsed["spec"]["template"]["spec"]["containers"].first["name"].should == "nginx"
    end

    it "handles multiple SubSpec instances in an array" do
      app = container.().new(name: "app", image: "app:latest")
      sidecar = container.().new(name: "sidecar", image: "sidecar:latest")

      deploy = Kube::Schema["Deployment"].new {
        metadata.name = "web"
        spec.replicas = 1
        spec.selector.matchLabels = { app: "web" }
        spec.template.metadata.labels = { app: "web" }
        spec.template.spec.containers = [app, sidecar]
      }

      containers = deploy.to_h[:spec][:template][:spec][:containers]
      containers.size.should == 2
      containers.map { |c| c[:name] }.should == ["app", "sidecar"]
    end

    it "works mixed with plain hashes" do
      typed = container.().new(name: "typed", image: "typed:latest")

      deploy = Kube::Schema["Deployment"].new {
        metadata.name = "web"
        spec.replicas = 1
        spec.selector.matchLabels = { app: "web" }
        spec.template.metadata.labels = { app: "web" }
        spec.template.spec.containers = [
          typed,
          { name: "plain", image: "plain:latest" }
        ]
      }

      containers = deploy.to_h[:spec][:template][:spec][:containers]
      containers.map { |c| c[:name] }.should == ["typed", "plain"]
    end
  end

  describe "disambiguation" do
    it "prefers stable API versions over beta/alpha" do
      # MatchCondition exists in v1, v1alpha1, and v1beta1
      klass = sub_spec["MatchCondition"]
      klass.should.be < sub_spec
      klass.schema.should.not.be.nil
    end
  end

  describe "Instance#list_definitions" do
    it "returns a sorted array of short definition names" do
      defs = Kube::Schema::Instance.new("1.34").list_definitions
      defs.should.be.kind_of Array
      defs.should.not.be.empty
      ["Container", "ContainerPort", "Probe", "Volume"].each { |name| defs.should.include name }
      defs.should == defs.sort
    end
  end
end
