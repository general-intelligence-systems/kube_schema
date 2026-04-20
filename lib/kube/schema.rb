# frozen_string_literal: true

require_relative 'monkey_patches'
require_relative 'errors'
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
    @custom_schemas = {}

    GEM_ROOT = File.expand_path("../..", __dir__).freeze
    SCHEMAS_DIR = File.join(GEM_ROOT, "schemas").freeze
    DEFAULT_VERSION = "1.34"

    class << self
      # Set a default Kubernetes version for bare lookups like Kube::Schema["Deployment"].
      # When nil, the DEFAULT_VERSION is used.
      attr_accessor :schema_version

      # Custom schemas registered via Kube::Schema.register.
      # Keys are kind strings, values are { schema:, defaults: } hashes.
      attr_reader :custom_schemas

      # Register a standalone JSON Schema for a custom resource kind.
      #
      # This lets users add CRD schemas from any source — for example,
      # the datreeio/CRDs-catalog, operator repos, or their own CRDs.
      # Registered kinds take precedence over built-in definitions.
      #
      # @param kind [String] The Kubernetes Kind (e.g. "Certificate")
      # @param schema [Hash, String, Pathname] JSON Schema as a Hash,
      #   a JSON string, or a file path to a .json file
      # @param api_version [String] The apiVersion (e.g. "cert-manager.io/v1")
      #
      # @example Register from a local file
      #   Kube::Schema.register("Certificate",
      #     schema: "schemas/cert-manager.io/certificate_v1.json",
      #     api_version: "cert-manager.io/v1"
      #   )
      #
      # @example Register from Chart#crds
      #   chart.crds.each do |crd|
      #     s = crd.to_json_schema
      #     Kube::Schema.register(s[:kind], schema: s[:schema], api_version: s[:api_version])
      #   end
      #
      def register(kind, schema:, api_version:)
        require "json"
        require "json_schemer"

        parsed = case schema
          when Hash
            schema
          when String, Pathname
            path = schema.to_s
            if File.exist?(path)
              JSON.parse(File.read(path))
            else
              JSON.parse(path)
            end
          else
            raise ArgumentError,
              "schema must be a Hash, a JSON string, or a file path — got #{schema.class}"
          end

        @custom_schemas[kind] = {
          schema: JSONSchemer.schema(parsed),
          defaults: { "apiVersion" => api_version, "kind" => kind }.freeze
        }

        # Invalidate cached resource classes on all instances so the
        # new registration takes effect immediately.
        @instances.each_value { |inst| inst.send(:clear_resource_cache!) }

        kind
      end

      # Remove all custom schema registrations.
      # Useful for test teardown or resetting state.
      def reset_custom_schemas!
        @custom_schemas.clear
        @instances.each_value { |inst| inst.send(:clear_resource_cache!) }
      end

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
          version = schema_version || DEFAULT_VERSION
          @instances[version] ||= Instance.new(version)
          @instances[version][key]
        end
      end

      # Build a typed Resource from a raw hash.
      #
      # Looks up the "kind" key in the hash and resolves it to the
      # correct Resource subclass via the schema registry. The hash
      # may use string or symbol keys.
      #
      #   Kube::Schema.parse("kind" => "Deployment", "apiVersion" => "apps/v1")
      #   Kube::Schema.parse(kind: "Pod", apiVersion: "v1", metadata: { name: "web" })
      #
      # @param hash [Hash] a Kubernetes resource hash with at least a "kind" key
      # @return [Resource] a schema-validated Resource instance
      # @raise [ArgumentError] if the hash is nil, not a Hash, or missing "kind"
      def parse(hash)
        raise ArgumentError, "Expected a Hash, got #{hash.class}" unless hash.is_a?(Hash)

        kind = hash["kind"] || hash[:kind]
        raise ArgumentError, "Hash must contain a \"kind\" key" if kind.nil?

        resource_class = self[kind]
        resource_class.new(hash)
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

# Patch BlackHoleStruct to handle arrays consistently.
#
# The upstream gem does not recurse into arrays — hashes inside arrays
# are not converted to BlackHoleStruct on construction, and are not
# converted back to plain Hash on #to_h.  This causes key-type
# inconsistencies after a Resource round-trip (symbol keys become
# string keys inside arrays).
#
# These two patches fix both directions:
#   initialize — converts hashes inside arrays to BlackHoleStruct
#   to_h       — converts BlackHoleStruct/arrays back to plain objects
class BlackHoleStruct
  def initialize(hash = {})
    raise ArgumentError, "Argument should be a Hash" unless hash.is_a?(Hash)

    @table = {}
    hash.each do |key, value|
      @table[key.to_sym] = deep_wrap(value)
    end
  end

  def to_h
    hash = {}
    @table.each do |key, value|
      hash[key] = deep_unwrap(value)
    end
    hash
  end

  private

  def deep_wrap(value)
    case value
    when Hash  then self.class.new(value)
    when Array then value.map { |v| deep_wrap(v) }
    else       value
    end
  end

  def deep_unwrap(value)
    case value
    when self.class then value.to_h
    when Array      then value.map { |v| deep_unwrap(v) }
    else            value
    end
  end
end
