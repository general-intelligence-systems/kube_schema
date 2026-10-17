# frozen_string_literal: true

require "json"
require "json_schemer"

module Kube
  module Schema
    # One Kubernetes version's OpenAPI schema.
    #
    # @example
    #   instance = Kube::Schema::Instance.new("1.34")
    #   instance["Deployment"]           # => Resource subclass
    #   instance["NetworkPolicy"]        # => Resource subclass
    #   instance.list_resources          # => sorted array of kind strings
    class Instance
      attr_reader :version

      @catalogs = {}

      class << self
        attr_reader :catalogs
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
      # @example
      #   instance["Deployment"]                      # kind-only lookup
      #   instance["apps/v1/Deployment"]               # group/version/kind
      #   instance["v1/Pod"]                           # version/kind, empty group
      #   instance["networking.k8s.io/v1/Ingress"]     # fully qualified
      #
      # @parameter input [String] a kind, or a "group/version/kind" string.
      # @returns [Class] a class that inherits from Kube::Schema::Resource.
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
              entry = nil
            else
              entry = find_gvk_entry_by_full_gvk(group, version, kind)
            end
          else
            # Kind-only lookup — custom schemas take precedence.
            custom = find_custom_entry(input)
            if custom
              entry = nil
            else
              entry = find_gvk_entry(input)
            end
          end

          if custom
            build_resource_class(Lazy::Source.spilled(catalog, custom[:entry]), custom[:defaults])
          else
            if entry.nil?
              raise "No resource schema found for #{input.inspect}!" \
                "\nUse #list_resources to see available kinds for v#{@version}."
            end

            ref_schema = Lazy::Source.indexed(catalog, entry[:definition_key])
            build_resource_class(ref_schema, entry[:defaults].freeze)
          end
        end
      end

      # All resource kinds for this version, plus custom ones.
      # @returns [Array(String)] sorted kind names.
      def list_resources
        custom_kinds = Schema.custom_schemas.values.map { |v| v[:defaults]["kind"] }
        (gvk_index.keys + custom_kinds).uniq.sort
      end

      # All API groups for this version, plus custom ones.
      #
      # @example
      #   instance.api_groups # => ["", "apps", "argoproj.io", "batch", ...]
      #
      # @returns [Array(String)] sorted, deduplicated group names.
      def api_groups
        custom_groups = Schema.custom_schemas.keys.filter_map do |key|
          parts = key.split("/")
          if parts.size == 3
            parts.first
          end
        end
        (gvk_index.values.flatten.map { |entry| entry[:group] } + custom_groups).uniq.sort
      end

      # Look up a sub-spec definition by short or full name.
      #
      # @example
      #   instance.sub_spec("Container")     # => SubSpec subclass
      #   instance.sub_spec("ContainerPort") # => SubSpec subclass
      #   instance.sub_spec("io.k8s.api.core.v1.Container") # disambiguated
      #
      # @parameter name [String] a short name or a full definition key.
      # @returns [Class] a class that inherits from Kube::Schema::SubSpec.
      def sub_spec(name)
        @sub_spec_classes[name] ||= begin
          definition_key = find_definition_key(name)

          if definition_key.nil?
            raise "No definition found for #{name}!" \
              "\nUse #list_definitions to see available definitions for v#{version}."
          end

          ref_schema = Lazy::Source.indexed(catalog, definition_key)
          build_sub_spec_class(ref_schema, name)
        end
      end

      # All definition short names for this version.
      # @returns [Array(String)] sorted, deduplicated short names.
      def list_definitions
        catalog.keys
          .map { |k| k.split(".").last }
          .uniq.sort
      end

      private

        def catalog
          self.class.catalogs[@version] ||= begin
            path = File.join(SCHEMAS_DIR, "v#{version}.json")

            unless File.exist?(path)
              raise UnknownVersionError,
                "\nNo schema file found at #{path}." \
                "\nUse `Kube::Schema.schema_versions` to get a list."
            end

            extra = Dir.glob(File.join(SCHEMAS_DIR, "*-definitions.json")).sort

            Lazy::Index.build([path] + extra)
          end
        end

        # Builds a map from kind to full GVK entry.
        # @returns [Hash] kind => Array of entry hashes, keyed by GVK.
        #
        # @example
        #   {
        #     "Deployment" => [{
        #       definition_key: "io.k8s.api.apps.v1.Deployment",
        #       group: "apps",
        #       version: "v1",
        #       kind: "Deployment",
        #       defaults: { "apiVersion" => "apps/v1", "kind" => "Deployment" }
        #     }]
        #   }
        def gvk_index
          @gvk_index ||= begin
            index = Hash.new { |h, k| h[k] = [] }

            catalog.entries.each do |key, entry|
              gvks = entry.gvks
              unless gvks
                next
              end

              gvks.each do |gvk|
                group = gvk["group"].to_s
                version = gvk["version"]
                kind = gvk["kind"]
                if group.empty?
                  api_version = version
                else
                  api_version = "#{group}/#{version}"
                end

                index[kind] << {
                  definition_key: key,
                  group:          group,
                  version:        version,
                  kind:           kind,
                  defaults:       {
                    "apiVersion" => api_version,
                    "kind"       => kind,
                  },
                }
              end
            end

            index
          end
        end

        # Find a GVK entry by kind name, case-insensitively.
        # @parameter kind [String] the kind name to look up.
        # @returns [Hash, nil] the first matching entry, if any.
        def find_gvk_entry(kind)
          entries = gvk_index[kind]
          if entries && !entries.empty?
            entries.first
          else
            match = gvk_index.find { |k, _v| k.downcase == kind.downcase }
            match && match[1].first
          end
        end

        # Find a GVK entry by exact group, version, and kind.
        # @parameter group [String] the API group, empty for core.
        # @parameter version [String] the API version, e.g. "v1".
        # @parameter kind [String] the kind name.
        # @returns [Hash, nil] the matching entry, if any.
        def find_gvk_entry_by_full_gvk(group, version, kind)
          entries = gvk_index[kind]
          if entries.nil? || entries.empty?
            nil
          else
            entries.find do |entry|
              entry[:group] == group && entry[:version] == version
            end
          end
        end

        # Find a custom schema entry by kind, case-insensitively.
        # @parameter kind [String] the kind name to look up.
        # @returns [Hash, nil] the first-registered { entry:, defaults: } hash.
        def find_custom_entry(kind)
          registry = Schema.custom_schemas
          exact = registry.values.find { |v| v[:defaults]["kind"] == kind }
          if exact
            exact
          else
            registry.values.find { |v| v[:defaults]["kind"].casecmp?(kind) }
          end
        end

        # Find a custom schema entry by group, version, and kind.
        # @parameter group [String] the API group, empty for core.
        # @parameter version [String] the API version, e.g. "v1".
        # @parameter kind [String] the kind name.
        # @returns [Hash, nil] the { entry:, defaults: } hash, if any.
        def find_custom_entry_by_gvk(group, version, kind)
          if group.empty?
            api_version = version
          else
            api_version = "#{group}/#{version}"
          end
          Schema.custom_schemas["#{api_version}/#{kind}"]
        end

        # Build a Resource subclass from a schema and defaults.
        # @parameter schema_instance [JSONSchemer::Schema] the resource's schema.
        # @parameter defaults [Hash] the frozen apiVersion/kind defaults.
        # @returns [Class] a Resource subclass bound to the schema.
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

        # Resolve a short name to its full definition key.
        #
        # @example
        #   find_definition_key("Container") # => "io.k8s.api.core.v1.Container"
        #
        # @parameter name [String] a short name or a full definition key.
        # @returns [String, nil] a full key, preferring stable API versions.
        def find_definition_key(name)
          definitions = catalog.entries

          # Exact full-key match
          if definitions.key?(name)
            name
          else
            candidates = definitions.keys.select { |k| k.split(".").last == name }
            if candidates.empty?
              nil
            else
              if candidates.size == 1
                candidates.first
              else
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
            end
          end
        end

        # Build a SubSpec subclass from a schema and definition name.
        # @parameter schema_instance [JSONSchemer::Schema] the definition's schema.
        # @parameter definition_name [String] the name shown in error messages.
        # @returns [Class] a SubSpec subclass bound to the schema.
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

        # Invalidates cached resource classes after a schema registration.
        # @returns [void] clears the resource class cache.
        def clear_resource_cache!
          @resource_classes.clear
        end
    end
  end
end


__END__

require "kube/schema"

instance_class = Kube::Schema::Instance
instance = instance_class.new("1.34")

describe "Kube::Schema::Instance" do
  describe "#initialize" do
    it "stores the version" do
      instance.version.should == "1.34"
    end

    it "raises UnknownVersionError for a non-version string" do
      lambda { instance_class.new("not-a-version") }.should.raise(Kube::UnknownVersionError)
    end
  end

  describe "#[]" do
    it "returns a Class that subclasses Resource" do
      klass = instance["Deployment"]
      klass.should.be.kind_of Class
      klass.should.be < Kube::Schema::Resource
    end

    it "caches resource classes by key" do
      instance["Deployment"].should.be.identical_to instance["Deployment"]
    end

    it "raises for an unknown resource" do
      error = lambda { instance["ThisDoesNotExist999"] }.should.raise(RuntimeError)
      error.message.should.match(/No resource schema found/)
    end

    it "returns different classes for different resources" do
      instance["Deployment"].should.not == instance["Service"]
    end

    it "attaches a schema to the resource class" do
      instance["Deployment"].schema.should.not.be.nil
    end

    it "is case-insensitive" do
      instance["Deployment"].should.be < Kube::Schema::Resource
      instance["deployment"].should.be < Kube::Schema::Resource
    end

    it "produces resources that can be instantiated with the block DSL" do
      resource = instance["Deployment"].new {
        metadata.name = "test"
      }
      resource.to_h[:apiVersion].should == "apps/v1"
      resource.to_h[:kind].should == "Deployment"
      resource.to_h[:metadata][:name].should == "test"
    end

    it "attaches defaults (apiVersion and kind) to the resource class" do
      instance["Deployment"].defaults.should == { "apiVersion" => "apps/v1", "kind" => "Deployment" }
    end

    it "derives correct apiVersion for core resources (empty group)" do
      instance["Pod"].defaults.should == { "apiVersion" => "v1", "kind" => "Pod" }
    end

    it "derives correct apiVersion for grouped resources" do
      instance["Ingress"].defaults.should == { "apiVersion" => "networking.k8s.io/v1", "kind" => "Ingress" }
    end
  end

  describe "#[] with full GVK string" do
    it "resolves apps/v1/Deployment" do
      klass = instance["apps/v1/Deployment"]
      klass.should.be < Kube::Schema::Resource
      klass.defaults.should == { "apiVersion" => "apps/v1", "kind" => "Deployment" }
    end

    it "resolves v1/Pod (core resource, empty group)" do
      klass = instance["v1/Pod"]
      klass.should.be < Kube::Schema::Resource
      klass.defaults.should == { "apiVersion" => "v1", "kind" => "Pod" }
    end

    it "resolves networking.k8s.io/v1/Ingress" do
      klass = instance["networking.k8s.io/v1/Ingress"]
      klass.should.be < Kube::Schema::Resource
      klass.defaults.should == { "apiVersion" => "networking.k8s.io/v1", "kind" => "Ingress" }
    end

    it "resolves kubevirt.io/v1/VirtualMachine" do
      klass = instance["kubevirt.io/v1/VirtualMachine"]
      klass.should.be < Kube::Schema::Resource
      klass.defaults.should == { "apiVersion" => "kubevirt.io/v1", "kind" => "VirtualMachine" }
    end

    it "raises for invalid GVK format (too many slashes)" do
      error = lambda { instance["a/b/c/d"] }.should.raise(RuntimeError)
      error.message.should.match(/Invalid GVK format/)
    end

    it "raises for non-existent GVK" do
      error = lambda { instance["fake.io/v99/Blah"] }.should.raise(RuntimeError)
      error.message.should.match(/No resource schema found/)
    end

    it "caches GVK lookups" do
      instance["apps/v1/Deployment"].should.be.identical_to instance["apps/v1/Deployment"]
    end
  end

  describe "#list_resources" do
    it "returns a sorted array of kind strings" do
      kinds = instance.list_resources
      kinds.should.be.kind_of Array
      kinds.should.not.be.empty
      ["Deployment", "Service", "Namespace", "Pod"].each { |kind| kinds.should.include kind }
      kinds.should == kinds.sort
    end
  end

  describe "#api_groups" do
    it "returns a sorted array of group names including the core group" do
      groups = instance.api_groups
      groups.should.be.kind_of Array
      groups.should == groups.sort
      groups.should.include ""
    end

    it "includes built-in groups, including ones without dots" do
      ["apps", "batch", "rbac.authorization.k8s.io"].each { |group| instance.api_groups.should.include group }
    end

    it "includes groups from the merged CRD definition bundles" do
      ["kubevirt.io", "argoproj.io"].each { |group| instance.api_groups.should.include group }
    end

    it "includes groups from registered custom schemas" do
      Kube::Schema.register("TenantVmClaim",
        schema: { "type" => "object" },
        api_version: "tradeportal.ai/v1")
      instance.api_groups.should.include "tradeportal.ai"
    ensure
      Kube::Schema.reset_custom_schemas!
    end
  end

  describe "KubeVirt schemas" do
    it "resolves VirtualMachine" do
      klass = instance["VirtualMachine"]
      klass.should.be.kind_of Class
      klass.should.be < Kube::Schema::Resource
    end

    it "has correct defaults for VirtualMachine" do
      instance["VirtualMachine"].defaults.should == { "apiVersion" => "kubevirt.io/v1", "kind" => "VirtualMachine" }
    end

    it "includes VirtualMachine in list_resources" do
      instance.list_resources.should.include "VirtualMachine"
    end

    it "resolves VirtualMachineInstance" do
      instance["VirtualMachineInstance"].defaults.should == { "apiVersion" => "kubevirt.io/v1", "kind" => "VirtualMachineInstance" }
    end

    it "resolves KubeVirt" do
      instance["KubeVirt"].defaults.should == { "apiVersion" => "kubevirt.io/v1", "kind" => "KubeVirt" }
    end

    it "can instantiate a VirtualMachine with the block DSL" do
      resource = instance["VirtualMachine"].new {
        metadata.name = "test-vm"
      }
      resource.to_h[:apiVersion].should == "kubevirt.io/v1"
      resource.to_h[:kind].should == "VirtualMachine"
      resource.to_h[:metadata][:name].should == "test-vm"
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
      lambda { resource.to_yaml }.should.not.raise(StandardError)
    end
  end

  describe "CloudnativePG schemas" do
    it "resolves Cluster by kind" do
      klass = instance["Cluster"]
      klass.should.be < Kube::Schema::Resource
      klass.defaults.should == { "apiVersion" => "postgresql.cnpg.io/v1", "kind" => "Cluster" }
    end

    it "resolves Cluster by full GVK string" do
      klass = instance["postgresql.cnpg.io/v1/Cluster"]
      klass.should.be < Kube::Schema::Resource
      klass.defaults.should == { "apiVersion" => "postgresql.cnpg.io/v1", "kind" => "Cluster" }
    end

    it "includes Cluster in list_resources" do
      instance.list_resources.should.include "Cluster"
    end

    it "resolves Backup" do
      instance["postgresql.cnpg.io/v1/Backup"].defaults.should == { "apiVersion" => "postgresql.cnpg.io/v1", "kind" => "Backup" }
    end

    it "resolves ScheduledBackup" do
      instance["postgresql.cnpg.io/v1/ScheduledBackup"].defaults.should == { "apiVersion" => "postgresql.cnpg.io/v1", "kind" => "ScheduledBackup" }
    end

    it "resolves Pooler" do
      instance["postgresql.cnpg.io/v1/Pooler"].defaults.should == { "apiVersion" => "postgresql.cnpg.io/v1", "kind" => "Pooler" }
    end

    it "can instantiate a Cluster with the block DSL" do
      resource = instance["postgresql.cnpg.io/v1/Cluster"].new {
        metadata.name = "pg-cluster"
        metadata.namespace = "databases"
        spec.instances = 3
        spec.storage.size = "10Gi"
      }
      resource.to_h[:apiVersion].should == "postgresql.cnpg.io/v1"
      resource.to_h[:kind].should == "Cluster"
      resource.to_h[:metadata][:name].should == "pg-cluster"
      resource.to_h[:spec][:instances].should == 3
    end
  end

  describe "class-level catalog cache" do
    it "shares the catalog across instances of the same version" do
      a = instance_class.new("1.34")
      b = instance_class.new("1.34")

      a["Deployment"].should.be < Kube::Schema::Resource
      b["Deployment"].should.be < Kube::Schema::Resource
      instance_class.catalogs["1.34"].should.be.kind_of Kube::Schema::Lazy::Index
    end
  end
end
