# frozen_string_literal: true

require_relative 'kube_schema/version'
require_relative 'kube_schema/resource'
require_relative 'kube_schema/instance'
require_relative 'kube_schema/schema_cache'

module KubeSchema
  class UnknownVersionError < StandardError; end

  @schema_version = nil
  @instances = {}

  GEM_ROOT = File.expand_path("..", __dir__).freeze
  SCHEMA_INDEX = File.join(GEM_ROOT, "data").freeze
  DEFAULT_VERSION = "1.35.3" # 2025-04-16

  class << self
    # Set a default Kubernetes version for bare lookups like KubeSchema["Deployment"].
    # When nil, the latest version found in the schemas directory is used.
    attr_accessor :schema_version

    # KubeSchema["1.33.6"]       => cached Instance (supports ["Deployment"] chaining)
    # KubeSchema["Deployment"]   => Resource via the default version
    # KubeSchema["apps/v1/Deployment"] => Resource via the default version
    def [](key)
      is_a_version = -> (key) { Gem::Version.correct?(key) }

      if is_a_version.(key)
        if has_version?(key)
          @instances[key] ||= Instance.new(key)
        else
          raise UnknownVersionError.new(
            "\n#{key} is an unknown version..." +
            "\nUse `KubeSchema.schema_versions` to get a list."
          )
        end
      else
        (schema_version || DEFAULT_VERSION)[key]
      end
    end

    # Build a Resource from a hash.
    #   KubeSchema.parse(KubeSchema["Deployment"].to_h) == KubeSchema["Deployment"]
    def parse(hash)
      raise NotImplementedError
    end

    def schema_versions
      @schema_versions ||=
        Dir.glob(SCHEMA_INDEX + "/v*.txt").map do |file_path|
          file_path.split("/").last.gsub(".txt", "")[1..-1]
        end.sort_by { Gem::Version.new(_1) }
    end

    # The latest Kubernetes version available in the schemas directory,
    # determined by sorting the filenames with Gem::Version.
    def latest_version
      schema_versions.last
    end

    private

      def has_version?(version)
        schema_versions.include?(version)
      end
  end
end
