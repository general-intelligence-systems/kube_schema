# frozen_string_literal: true

require "json"

module KubeSchema
  # Represents a single Kubernetes version's OpenAPI schema.
  # Lazily loads the JSON and builds an index of group/version/kind strings
  # mapped back to definition keys.
  #
  #   instance = KubeSchema::Instance.new("v1.33.6")
  #   instance["Deployment"]
  #   instance["apps/v1/Deployment"]
  #   instance.list_resources  #=> sorted array of "group/version/kind" strings
  #
  class Instance
    attr_reader :version

    def initialize(version)
      @version = normalize_version(version)
      @data = nil
      @gvk_index = nil          # { "apps/v1/Deployment" => "io.k8s.api.apps.v1.Deployment", ... }
      @resource_classes = {}     # { "io.k8s.api.apps.v1.Deployment" => Class, ... }
    end

    # Look up a resource by full "group/version/kind" or by bare "Kind".
    # Returns a class that inherits from KubeSchema::Resource, or nil.
    def [](key)
      load!
      defn_key = resolve(key)
      return nil unless defn_key

      @resource_classes[defn_key] ||= begin
        schema_hash = @data["definitions"][defn_key]
        Class.new(Resource) do
          @schema = schema_hash

          def self.schema
            @schema || superclass.schema
          end
        end
      end
    end

    # Returns the full parsed JSON hash from the schema file.
    def to_h
      load!
      @data
    end

    # Sorted list of all "group/version/kind" resource strings in this schema.
    def list_resources
      load!
      @gvk_index.keys.sort
    end

    private

    def normalize_version(ver)
      ver = ver.to_s
      ver.start_with?("v") ? ver : "v#{ver}"
    end

    def schema_path
      File.join(KubeSchema.schemas_dir, "#{@version}.json")
    end

    def load!
      return if @data

      raise ArgumentError, "Schema file not found: #{schema_path}" unless File.exist?(schema_path)

      @data = JSON.parse(File.read(schema_path))
      build_index!
    end

    def build_index!
      @gvk_index = {}
      (@data["definitions"] || {}).each do |defn_key, defn|
        (defn["x-kubernetes-group-version-kind"] || []).each do |gvk|
          group   = gvk.fetch("group", "")
          ver     = gvk.fetch("version", "")
          kind    = gvk.fetch("kind", "")
          gvk_str = "#{group}/#{ver}/#{kind}"
          @gvk_index[gvk_str] = defn_key
        end
      end
    end

    # Exact match on "group/version/kind" if the key contains a slash,
    # otherwise first-match on the kind segment.
    def resolve(key)
      if key.include?("/")
        @gvk_index[key]
      else
        @gvk_index.each do |gvk_str, defn_key|
          return defn_key if gvk_str.split("/").last == key
        end
        nil
      end
    end
  end
end
