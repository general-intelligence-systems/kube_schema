# frozen_string_literal: true

require "json"
require "json_schemer"

module Kube
  module Schema
    # Represents a single Kubernetes version's OpenAPI schema.
    # Lazily loads the Swagger JSON once per version (shared across instances)
    # and builds resource classes by kind.
    #
    #   instance = Kube::Schema::Instance.new("1.34")
    #   instance["Deployment"]           # => Resource subclass
    #   instance["NetworkPolicy"]        # => Resource subclass
    #   instance.list_resources          # => sorted array of kind strings
    #
    class Instance
      attr_reader :version

      # Class-level cache so multiple Instance objects for the same version
      # share the parsed Swagger schema.
      @schemers = {}

      class << self
        attr_reader :schemers
      end

      def initialize(version)
        @resource_classes = {}

        unless Gem::Version.correct?(version)
          raise UnknownVersionError,
            "\n#{version} is not a valid version string." \
            "\nUse `Kube::Schema.schema_versions` to get a list."
        end

        @version = version
      end

      # Look up a resource by kind (e.g. "Deployment", "NetworkPolicy").
      # Returns a class that inherits from Kube::Schema::Resource.
      #
      # Custom schemas registered via Kube::Schema.register take precedence
      # over built-in definitions, allowing users to override or extend the
      # schema for any kind.
      def [](kind)
        @resource_classes[kind] ||= begin
          # Custom schemas win over built-in definitions.
          custom = find_custom_entry(kind)
          if custom
            build_resource_class(custom[:schema], custom[:defaults])
          else
            entry = find_gvk_entry(kind)

            if entry.nil?
              raise "No resource schema found for #{kind}!" \
                "\nUse #list_resources to see available kinds for v#{version}."
            end

            ref_schema = schemer.ref("#/definitions/#{entry[:definition_key]}")
            build_resource_class(ref_schema, entry[:defaults].freeze)
          end
        end
      end

      # All available resource kinds for this version, including any
      # custom schemas registered via Kube::Schema.register.
      #
      # @return [Array<String>] sorted kind names
      def list_resources
        (gvk_index.keys + Schema.custom_schemas.keys).uniq.sort
      end

      private

        # The JSONSchemer instance for this version's Swagger document.
        # Cached at the class level so it's built once per version.
        #
        # After loading the base Swagger JSON, merges in any extra definition
        # files found in the schemas directory (e.g. crd-definitions.json,
        # loft-definitions.json). These files are flat JSON objects where keys
        # are definition names and values are OpenAPI v2 schema objects.
        def schemer
          self.class.schemers[@version] ||= begin
            path = File.join(SCHEMAS_DIR, "v#{version}.json")

            unless File.exist?(path)
              raise UnknownVersionError,
                "\nNo schema file found at #{path}." \
                "\nUse `Kube::Schema.schema_versions` to get a list."
            end

            schema = JSON.parse(File.read(path))

            # Merge extra definition files (*-definitions.json) into the
            # base schema so CRD and aggregated-API types (e.g. loft,
            # gateway-api) are available alongside built-in k8s types.
            Dir.glob(File.join(SCHEMAS_DIR, "*-definitions.json")).each do |defs_path|
              extra = JSON.parse(File.read(defs_path))
              schema["definitions"] ||= {}
              schema["definitions"].merge!(extra)
            end

            # Kubernetes OpenAPI v2 defines IntOrString as "type": "string"
            # with "format": "int-or-string". This is a limitation of
            # OpenAPI v2 which cannot express union types. Patch the
            # definition so JSONSchemer accepts both integers and strings.
            if (int_or_str = schema.dig("definitions", "io.k8s.apimachinery.pkg.util.intstr.IntOrString"))
              int_or_str["type"] = ["string", "integer"]
            end

            JSONSchemer.schema(schema)
          end
        end

        # Builds a map from kind to full GVK entry:
        #   {
        #     "Deployment" => {
        #       definition_key: "io.k8s.api.apps.v1.Deployment",
        #       group: "apps",
        #       version: "v1",
        #       kind: "Deployment",
        #       defaults: { "apiVersion" => "apps/v1", "kind" => "Deployment" }
        #     },
        #     "Pod" => {
        #       definition_key: "io.k8s.api.core.v1.Pod",
        #       group: "",
        #       version: "v1",
        #       kind: "Pod",
        #       defaults: { "apiVersion" => "v1", "kind" => "Pod" }
        #     },
        #     ...
        #   }
        def gvk_index
          @gvk_index ||= begin
            index = {}

            schemer.value.fetch("definitions", {}).each do |key, definition|
              gvks = definition["x-kubernetes-group-version-kind"]
              next unless gvks

              gvks.each do |gvk|
                group = gvk["group"].to_s
                version = gvk["version"]
                kind = gvk["kind"]
                api_version = group.empty? ? version : "#{group}/#{version}"

                index[kind] = {
                  definition_key: key,
                  group: group,
                  version: version,
                  kind: kind,
                  defaults: {
                    "apiVersion" => api_version,
                    "kind" => kind
                  }
                }
              end
            end

            index
          end
        end

        # Find a GVK entry by kind name (case-insensitive).
        # Returns the full entry hash or nil.
        def find_gvk_entry(kind)
          return gvk_index[kind] if gvk_index.key?(kind)

          gvk_index.each do |k, v|
            return v if k.downcase == kind.downcase
          end

          nil
        end

        # Find a custom schema entry by kind (case-insensitive).
        # Returns the { schema:, defaults: } hash or nil.
        def find_custom_entry(kind)
          registry = Schema.custom_schemas
          return registry[kind] if registry.key?(kind)

          registry.each do |k, v|
            return v if k.downcase == kind.downcase
          end

          nil
        end

        # Build a Resource subclass from a JSONSchemer instance and defaults hash.
        def build_resource_class(schema_instance, defaults)
          Class.new(::Kube::Schema::Resource) do
            @schema = schema_instance
            @defaults = defaults
            @schema_properties = @schema.value["properties"].keys.map(&:to_sym)

            def self.schema
              @schema || superclass.schema
            end

            def self.defaults
              @defaults || superclass.defaults
            end

            def self.schema_properties
              @schema_properties
            end

            schema_instance.value["properties"].keys.then do |properties|
              properties.each do |prop|
                define_method(prop.to_sym) { @data[prop.to_sym] }
              end
            end
          end
        end

        # Called by Kube::Schema.register and reset_custom_schemas! to
        # invalidate cached resource classes so new registrations take effect.
        def clear_resource_cache!
          @resource_classes.clear
        end
    end
  end
end

if __FILE__ == $0
  require "bundler/setup"
  require "rspec/autorun"
  require "kube/schema"

  RSpec.describe Kube::Schema::Instance do
    subject(:instance) { described_class.new("1.34") }

    describe "#initialize" do
      it "stores the version" do
        expect(instance.version).to eq("1.34")
      end

      it "raises UnknownVersionError for a non-version string" do
        expect { described_class.new("not-a-version") }.to raise_error(Kube::UnknownVersionError)
      end
    end

    describe "#[]" do
      it "returns a Class that subclasses Resource" do
        klass = instance["Deployment"]
        expect(klass).to be_a(Class)
        expect(klass).to be < Kube::Schema::Resource
      end

      it "caches resource classes by key" do
        a = instance["Deployment"]
        b = instance["Deployment"]
        expect(a).to be(b)
      end

      it "raises for an unknown resource" do
        expect { instance["ThisDoesNotExist999"] }.to raise_error(RuntimeError, /No resource schema found/)
      end

      it "returns different classes for different resources" do
        deployment = instance["Deployment"]
        service = instance["Service"]
        expect(deployment).not_to eq(service)
      end

      it "attaches a schema to the resource class" do
        klass = instance["Deployment"]
        expect(klass.schema).not_to be_nil
      end

      it "is case-insensitive" do
        a = instance["Deployment"]
        b = instance["deployment"]
        expect(a).to be < Kube::Schema::Resource
        expect(b).to be < Kube::Schema::Resource
      end

      it "produces resources that can be instantiated with the block DSL" do
        resource = instance["Deployment"].new {
          metadata.name = "test"
        }
        expect(resource.to_h[:apiVersion]).to eq("apps/v1")
        expect(resource.to_h[:kind]).to eq("Deployment")
        expect(resource.to_h[:metadata][:name]).to eq("test")
      end

      it "attaches defaults (apiVersion and kind) to the resource class" do
        klass = instance["Deployment"]
        expect(klass.defaults).to eq({ "apiVersion" => "apps/v1", "kind" => "Deployment" })
      end

      it "derives correct apiVersion for core resources (empty group)" do
        klass = instance["Pod"]
        expect(klass.defaults).to eq({ "apiVersion" => "v1", "kind" => "Pod" })
      end

      it "derives correct apiVersion for grouped resources" do
        klass = instance["Ingress"]
        expect(klass.defaults).to eq({ "apiVersion" => "networking.k8s.io/v1", "kind" => "Ingress" })
      end
    end

    describe "#list_resources" do
      it "returns a sorted array of kind strings" do
        kinds = instance.list_resources
        expect(kinds).to be_an(Array)
        expect(kinds).not_to be_empty
        expect(kinds).to include("Deployment", "Service", "Namespace", "Pod")
        expect(kinds).to eq(kinds.sort)
      end
    end

    describe "class-level schemer cache" do
      it "shares the schemer across instances of the same version" do
        a = described_class.new("1.34")
        b = described_class.new("1.34")
        # Both should resolve without error and return equivalent classes
        expect(a["Deployment"]).to be < Kube::Schema::Resource
        expect(b["Deployment"]).to be < Kube::Schema::Resource
      end
    end
  end
end
