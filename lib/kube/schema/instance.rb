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
        @sub_spec_classes = {}

        unless Gem::Version.correct?(version)
          raise UnknownVersionError,
            "\n#{version} is not a valid version string." \
            "\nUse `Kube::Schema.schema_versions` to get a list."
        end

        @version = version
      end

      # Look up a resource by kind or full GVK string.
      #
      # Accepts:
      #   instance["Deployment"]                      — kind-only lookup
      #   instance["apps/v1/Deployment"]              — group/version/kind
      #   instance["v1/Pod"]                          — version/kind (core, empty group)
      #   instance["networking.k8s.io/v1/Ingress"]    — fully qualified
      #
      # Returns a class that inherits from Kube::Schema::Resource.
      #
      # Custom schemas registered via Kube::Schema.register take precedence
      # over built-in definitions (kind-only lookups only).
      def [](input)
        @resource_classes[input] ||= begin
          if input.include?("/")
            parts = input.split("/")

            case parts.length
            when 3
              group, version, kind = parts
            when 2
              group = ""
              version, kind = parts
            else
              raise "Invalid GVK format: #{input.inspect}." \
                "\nExpected \"group/version/kind\" or \"version/kind\"."
            end

            # Custom schemas take precedence on full-GVK lookups too.
            custom = find_custom_entry_by_gvk(group, version, kind)
            if custom
              return build_resource_class(custom[:schema], custom[:defaults])
            end

            entry = find_gvk_entry_by_full_gvk(group, version, kind)
          else
            # Kind-only lookup — custom schemas take precedence.
            custom = find_custom_entry(input)
            if custom
              return build_resource_class(custom[:schema], custom[:defaults])
            end

            entry = find_gvk_entry(input)
          end

          if entry.nil?
            raise "No resource schema found for #{input.inspect}!" \
              "\nUse #list_resources to see available kinds for v#{@version}."
          end

          ref_schema = schemer.ref("#/definitions/#{entry[:definition_key]}")
          build_resource_class(ref_schema, entry[:defaults].freeze)
        end
      end

      # All available resource kinds for this version, including any
      # custom schemas registered via Kube::Schema.register.
      #
      # @return [Array<String>] sorted kind names
      def list_resources
        custom_kinds = Schema.custom_schemas.values.map { |v| v[:defaults]["kind"] }
        (gvk_index.keys + custom_kinds).uniq.sort
      end

      # Look up a sub-spec definition by short name (e.g. "Container",
      # "ContainerPort", "Volume", "Probe"). Returns a class that
      # inherits from Kube::Schema::SubSpec.
      #
      # Also accepts a full definition key like
      # "io.k8s.api.core.v1.Container" for disambiguation.
      #
      #   instance.sub_spec("Container")     # => SubSpec subclass
      #   instance.sub_spec("ContainerPort") # => SubSpec subclass
      #
      def sub_spec(name)
        @sub_spec_classes[name] ||= begin
          definition_key = find_definition_key(name)

          if definition_key.nil?
            raise "No definition found for #{name}!" \
              "\nUse #list_definitions to see available definitions for v#{version}."
          end

          ref_schema = schemer.ref("#/definitions/#{definition_key}")
          build_sub_spec_class(ref_schema, name)
        end
      end

      # All available definition short names for this version.
      #
      # @return [Array<String>] sorted, deduplicated short names
      def list_definitions
        schemer.value.fetch("definitions", {}).keys
          .map { |k| k.split(".").last }
          .uniq.sort
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
            index = Hash.new { |h, k| h[k] = [] }

            schemer.value.fetch("definitions", {}).each do |key, definition|
              gvks = definition["x-kubernetes-group-version-kind"]
              next unless gvks

              gvks.each do |gvk|
                group = gvk["group"].to_s
                version = gvk["version"]
                kind = gvk["kind"]
                api_version = group.empty? ? version : "#{group}/#{version}"

                index[kind] << {
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
        # Returns the first matching entry hash or nil.
        def find_gvk_entry(kind)
          entries = gvk_index[kind]
          return entries.first if entries && !entries.empty?

          gvk_index.each do |k, v|
            return v.first if k.downcase == kind.downcase
          end

          nil
        end

        # Find a GVK entry by exact group, version, and kind.
        # Returns the matching entry hash or nil.
        def find_gvk_entry_by_full_gvk(group, version, kind)
          entries = gvk_index[kind]
          return nil if entries.nil? || entries.empty?

          entries.find do |entry|
            entry[:group] == group && entry[:version] == version
          end
        end

        # Find a custom schema entry by kind (case-insensitive). The registry
        # is keyed by full GVK, so match on each entry's recorded kind. When
        # several groups register the same kind, the first registered wins.
        # Returns the { schema:, defaults: } hash or nil.
        def find_custom_entry(kind)
          registry = Schema.custom_schemas
          registry.each_value { |v| return v if v[:defaults]["kind"] == kind }
          registry.each_value { |v| return v if v[:defaults]["kind"].casecmp?(kind) }

          nil
        end

        # Find a custom schema entry by exact group, version, and kind.
        # Returns the { schema:, defaults: } hash or nil.
        def find_custom_entry_by_gvk(group, version, kind)
          api_version = group.empty? ? version : "#{group}/#{version}"
          Schema.custom_schemas["#{api_version}/#{kind}"]
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
              @schema_properties || superclass.schema_properties
            end

            schema_instance.value["properties"].keys.then do |properties|
              properties.each do |prop|
                define_method(prop.to_sym) { @data[prop.to_sym] }
              end
            end
          end
        end

        # Resolve a short name like "Container" to its full definition key
        # "io.k8s.api.core.v1.Container".
        #
        # Strategy:
        #   1. Exact match on full key (for power users)
        #   2. Short-name match on last segment
        #   3. Prefer stable API versions (v1 > v1beta1 > v1alpha1)
        def find_definition_key(name)
          definitions = schemer.value.fetch("definitions", {})

          # Exact full-key match
          return name if definitions.key?(name)

          # Short-name matches (last segment after final ".")
          candidates = definitions.keys.select { |k| k.split(".").last == name }
          return nil if candidates.empty?
          return candidates.first if candidates.size == 1

          # Disambiguation: prefer stable versions, then beta, then alpha
          candidates.min_by { |k|
            version_segment = k.split(".")[-2].to_s
            case version_segment
            when /\Av\d+\z/ then [0, version_segment]
            when /beta/      then [1, version_segment]
            when /alpha/     then [2, version_segment]
            else                  [3, version_segment]
            end
          }
        end

        # Build a SubSpec subclass from a JSONSchemer instance and a
        # human-readable definition name (for error messages).
        def build_sub_spec_class(schema_instance, definition_name)
          Class.new(::Kube::Schema::SubSpec) do
            @schema = schema_instance
            @definition_name = definition_name
            @schema_properties = @schema.value.fetch("properties", {}).keys.map(&:to_sym)

            def self.schema
              @schema || superclass.schema
            end

            def self.definition_name
              @definition_name || superclass.definition_name
            end

            def self.schema_properties
              @schema_properties || superclass.schema_properties
            end

            schema_instance.value.fetch("properties", {}).keys.each do |prop|
              define_method(prop.to_sym) { @data[prop.to_sym] }
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

    describe "#[] with full GVK string" do
      it "resolves apps/v1/Deployment" do
        klass = instance["apps/v1/Deployment"]
        expect(klass).to be < Kube::Schema::Resource
        expect(klass.defaults).to eq({ "apiVersion" => "apps/v1", "kind" => "Deployment" })
      end

      it "resolves v1/Pod (core resource, empty group)" do
        klass = instance["v1/Pod"]
        expect(klass).to be < Kube::Schema::Resource
        expect(klass.defaults).to eq({ "apiVersion" => "v1", "kind" => "Pod" })
      end

      it "resolves networking.k8s.io/v1/Ingress" do
        klass = instance["networking.k8s.io/v1/Ingress"]
        expect(klass).to be < Kube::Schema::Resource
        expect(klass.defaults).to eq({ "apiVersion" => "networking.k8s.io/v1", "kind" => "Ingress" })
      end

      it "resolves kubevirt.io/v1/VirtualMachine" do
        klass = instance["kubevirt.io/v1/VirtualMachine"]
        expect(klass).to be < Kube::Schema::Resource
        expect(klass.defaults).to eq({ "apiVersion" => "kubevirt.io/v1", "kind" => "VirtualMachine" })
      end

      it "raises for invalid GVK format (too many slashes)" do
        expect { instance["a/b/c/d"] }.to raise_error(RuntimeError, /Invalid GVK format/)
      end

      it "raises for non-existent GVK" do
        expect { instance["fake.io/v99/Blah"] }.to raise_error(RuntimeError, /No resource schema found/)
      end

      it "caches GVK lookups" do
        a = instance["apps/v1/Deployment"]
        b = instance["apps/v1/Deployment"]
        expect(a).to be(b)
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

    describe "KubeVirt schemas" do
      it "resolves VirtualMachine" do
        klass = instance["VirtualMachine"]
        expect(klass).to be_a(Class)
        expect(klass).to be < Kube::Schema::Resource
      end

      it "has correct defaults for VirtualMachine" do
        klass = instance["VirtualMachine"]
        expect(klass.defaults).to eq({ "apiVersion" => "kubevirt.io/v1", "kind" => "VirtualMachine" })
      end

      it "includes VirtualMachine in list_resources" do
        expect(instance.list_resources).to include("VirtualMachine")
      end

      it "resolves VirtualMachineInstance" do
        klass = instance["VirtualMachineInstance"]
        expect(klass.defaults).to eq({ "apiVersion" => "kubevirt.io/v1", "kind" => "VirtualMachineInstance" })
      end

      it "resolves KubeVirt" do
        klass = instance["KubeVirt"]
        expect(klass.defaults).to eq({ "apiVersion" => "kubevirt.io/v1", "kind" => "KubeVirt" })
      end

      it "can instantiate a VirtualMachine with the block DSL" do
        resource = instance["VirtualMachine"].new {
          metadata.name = "test-vm"
        }
        expect(resource.to_h[:apiVersion]).to eq("kubevirt.io/v1")
        expect(resource.to_h[:kind]).to eq("VirtualMachine")
        expect(resource.to_h[:metadata][:name]).to eq("test-vm")
      end

      it "validates a VirtualMachine without $ref resolution errors" do
        resource = instance["VirtualMachine"].new {
          metadata.name = "test-vm"
          spec.runStrategy = "Always"
          spec.template.metadata.labels = { "kubevirt.io/vm": "test-vm" }
          spec.template.spec.domain.cpu = { cores: 1 }
          spec.template.spec.domain.devices = {}
          spec.template.spec.domain.memory = { guest: "1Gi" }
          spec.template.spec.domain.resources = { requests: { memory: "1Gi" } }
          spec.template.spec.volumes = [
            { name: "rootdisk", containerDisk: { image: "registry.example.com/vm:latest" } }
          ]
        }
        expect { resource.to_yaml }.not_to raise_error
      end
    end

    describe "CloudnativePG schemas" do
      it "resolves Cluster by kind" do
        klass = instance["Cluster"]
        expect(klass).to be < Kube::Schema::Resource
        expect(klass.defaults).to eq({ "apiVersion" => "postgresql.cnpg.io/v1", "kind" => "Cluster" })
      end

      it "resolves Cluster by full GVK string" do
        klass = instance["postgresql.cnpg.io/v1/Cluster"]
        expect(klass).to be < Kube::Schema::Resource
        expect(klass.defaults).to eq({ "apiVersion" => "postgresql.cnpg.io/v1", "kind" => "Cluster" })
      end

      it "includes Cluster in list_resources" do
        expect(instance.list_resources).to include("Cluster")
      end

      it "resolves Backup" do
        klass = instance["postgresql.cnpg.io/v1/Backup"]
        expect(klass.defaults).to eq({ "apiVersion" => "postgresql.cnpg.io/v1", "kind" => "Backup" })
      end

      it "resolves ScheduledBackup" do
        klass = instance["postgresql.cnpg.io/v1/ScheduledBackup"]
        expect(klass.defaults).to eq({ "apiVersion" => "postgresql.cnpg.io/v1", "kind" => "ScheduledBackup" })
      end

      it "resolves Pooler" do
        klass = instance["postgresql.cnpg.io/v1/Pooler"]
        expect(klass.defaults).to eq({ "apiVersion" => "postgresql.cnpg.io/v1", "kind" => "Pooler" })
      end

      it "can instantiate a Cluster with the block DSL" do
        resource = instance["postgresql.cnpg.io/v1/Cluster"].new {
          metadata.name = "pg-cluster"
          metadata.namespace = "databases"
          spec.instances = 3
          spec.storage.size = "10Gi"
        }
        expect(resource.to_h[:apiVersion]).to eq("postgresql.cnpg.io/v1")
        expect(resource.to_h[:kind]).to eq("Cluster")
        expect(resource.to_h[:metadata][:name]).to eq("pg-cluster")
        expect(resource.to_h[:spec][:instances]).to eq(3)
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
