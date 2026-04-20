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
