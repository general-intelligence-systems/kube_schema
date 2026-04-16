# frozen_string_literal: true

require_relative '../kube/errors'
require_relative 'schema/version'
require_relative 'schema/resource'
require_relative 'schema/instance'
require_relative 'schema/schema_cache'
require_relative 'schema/schema_index'

module Kube
  def self.schema
    Schema
  end

  module Schema

    @schema_version = nil
    @instances = {}

    GEM_ROOT = File.expand_path("../..", __dir__).freeze
    SCHEMA_INDEX = File.join(GEM_ROOT, "data").freeze
    DEFAULT_VERSION = "1.34.4" # 2025-04-16

    class << self
      # Set a default Kubernetes version for bare lookups like Kube::Schema["Deployment"].
      # When nil, the latest version found in the schemas directory is used.
      attr_accessor :schema_version

      # Kube::Schema["1.33.6"]       => cached Instance (supports ["Deployment"] chaining)
      # Kube::Schema["Deployment"]   => Resource via the default version
      # Kube::Schema["apps/v1/Deployment"] => Resource via the default version
      def [](key)
        is_a_version = -> (key) { Gem::Version.correct?(key) }

        if key.start_with?("v") && Gem::Version.correct?(key.sub("v", ""))
          raise Kube::IncorrectVersionFormat,
            "\nDon't preface the version with a \"v\"." \
            "\nUse Kube::Schema[\"#{key.sub("v", "")}\"] instead."
        end

        if is_a_version.(key)
          if has_version?(key)
            @instances[key] ||= Instance.new(key)
          else
            raise Kube::UnknownVersionError.new(
              "\n#{key} is an unknown version..." +
              "\nUse `Kube::Schema.schema_versions` to get a list."
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

      def has_version?(version)
        schema_versions.include?(version)
      end
    end
  end
end
