# frozen_string_literal: true

require_relative "kube_schema/version"
require_relative "kube_schema/resource"
require_relative "kube_schema/instance"

module KubeSchema
  @schema_version = nil
  @instances = {}

  class << self
    # Set a default Kubernetes version for bare lookups like KubeSchema["Deployment"].
    # When nil, the latest version found in the schemas directory is used.
    attr_accessor :schema_version

    # KubeSchema["1.33.6"]       => cached Instance (supports ["Deployment"] chaining)
    # KubeSchema["Deployment"]   => Resource via the default version
    # KubeSchema["apps/v1/Deployment"] => Resource via the default version
    def [](key)
      if version_file_exists?(key)
        normalized = key.to_s.start_with?("v") ? key.to_s : "v#{key}"
        @instances[normalized] ||= Instance.new(key)
      else
        default_schema[key]
      end
    end

    # Build a Resource from a hash.
    #   KubeSchema.parse(KubeSchema["Deployment"].to_h) == KubeSchema["Deployment"]
    def parse(hash)
      Resource.new(hash)
    end

    # Sorted list of resource strings for the default version.
    def list_resources
      default_schema.list_resources
    end

    # Path to the schemas directory shipped with the gem.
    def schemas_dir
      File.join(File.expand_path("../..", __FILE__), "schemas")
    end

    # The latest Kubernetes version available in the schemas directory,
    # determined by sorting the filenames with Gem::Version.
    def latest_version
      Dir.glob(File.join(schemas_dir, "v*.json"))
         .map { |f| File.basename(f, ".json") }
         .select { |v| v.match?(/\Av\d+\.\d+\.\d+\z/) } # stable releases only
         .sort_by { |v| Gem::Version.new(v.delete_prefix("v")) }
         .last
    end

    private

    def default_schema
      ver = schema_version || latest_version
      @instances[ver] ||= Instance.new(ver)
    end

    def version_file_exists?(key)
      normalized = key.to_s.start_with?("v") ? key.to_s : "v#{key}"
      File.exist?(File.join(schemas_dir, "#{normalized}.json"))
    end
  end
end
