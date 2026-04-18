# frozen_string_literal: true

require_relative '../kube/errors'
require_relative 'schema/version'
require_relative 'schema/resource'
require_relative 'schema/instance'
require_relative 'schema/manifest'

module Kube
  def self.schema
    Schema
  end

  module Schema

    @schema_version = nil
    @instances = {}

    GEM_ROOT = File.expand_path("../..", __dir__).freeze
    SCHEMAS_DIR = File.join(GEM_ROOT, "schemas").freeze
    DEFAULT_VERSION = "1.34"

    class << self
      # Set a default Kubernetes version for bare lookups like Kube::Schema["Deployment"].
      # When nil, the DEFAULT_VERSION is used.
      attr_accessor :schema_version

      # Kube::Schema["1.34"]           => cached Instance (supports ["Deployment"] chaining)
      # Kube::Schema["Deployment"]     => Resource via the default version
      def [](key)
        if key.start_with?("v") && Gem::Version.correct?(key.sub("v", ""))
          raise Kube::IncorrectVersionFormat,
            "\nDon't preface the version with a \"v\"." \
            "\nUse Kube::Schema[\"#{key.sub("v", "")}\"] instead."
        end

        if Gem::Version.correct?(key)
          if has_version?(key)
            @instances[key] ||= Instance.new(key)
          else
            raise Kube::UnknownVersionError.new(
              "\n#{key} is an unknown version..." +
              "\nAvailable: #{schema_versions.join(", ")}"
            )
          end
        else
          Instance.new(schema_version || DEFAULT_VERSION)[key]
        end
      end

      # Build a Resource from a hash.
      #   Kube::Schema.parse(Kube::Schema["Deployment"].to_h) == Kube::Schema["Deployment"]
      def parse(hash)
        raise NotImplementedError
      end

      # Available Kubernetes versions, read from the local schemas directory.
      #
      # @return [Array<String>] sorted version strings like ["1.19", "1.20", ...]
      def schema_versions
        @schema_versions ||=
          Dir.glob(File.join(SCHEMAS_DIR, "v*.json")).map do |file_path|
            File.basename(file_path, ".json").sub(/\Av/, "")
          end.sort_by { Gem::Version.new(_1) }
      end

      # The latest Kubernetes version available in the schemas directory.
      def latest_version
        schema_versions.last
      end

      def has_version?(version)
        schema_versions.include?(version)
      end
    end
  end
end
