# frozen_string_literal: true

require_relative 'monkey_patches'
require_relative 'errors'
require_relative 'schema/version'
require_relative 'schema/resource'
require_relative 'schema/sub_spec'
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

        # Key by full GVK ("group/version/Kind") so a registered CRD resolves
        # on fully-qualified lookups (e.g. the api_version/kind path that
        # Resource#rebuild reconstructs), not just kind-only lookups. Keying by
        # bare kind also collided when two CRDs shared a kind across groups.
        key = api_version ? "#{api_version}/#{kind}" : kind
        @custom_schemas[key] = {
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


if __FILE__ == $0
  require "bundler/setup"
  require "rspec/autorun"

  RSpec.describe Kube::Schema do
    describe "::VERSION" do
      it "is defined" do
        expect(Kube::Schema::VERSION).not_to be_nil
      end

      it "is a valid semver string" do
        expect(Kube::Schema::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
      end
    end

    describe "::DEFAULT_VERSION" do
      it "is a version present in schema_versions" do
        expect(Kube::Schema.schema_versions).to include(Kube::Schema::DEFAULT_VERSION)
      end
    end

    describe ".schema_versions" do
      it "returns an array of version strings" do
        versions = Kube::Schema.schema_versions
        expect(versions).to be_an(Array)
        expect(versions).not_to be_empty
        expect(versions).to all(match(/\A\d+\.\d+/))
      end

      it "is sorted by Gem::Version" do
        versions = Kube::Schema.schema_versions
        sorted = versions.sort_by { |v| Gem::Version.new(v) }
        expect(versions).to eq(sorted)
      end

      it "does not include a leading 'v' prefix" do
        expect(Kube::Schema.schema_versions).to all(satisfy { |v| !v.start_with?("v") })
      end
    end

    describe ".latest_version" do
      it "returns the last element of schema_versions" do
        expect(Kube::Schema.latest_version).to eq(Kube::Schema.schema_versions.last)
      end
    end

    describe ".[]" do
      context "with a version string" do
        it "returns an Instance for a known version" do
          instance = Kube::Schema["1.34"]
          expect(instance).to be_a(Kube::Schema::Instance)
          expect(instance.version).to eq("1.34")
        end

        it "caches Instance objects by version" do
          a = Kube::Schema["1.34"]
          b = Kube::Schema["1.34"]
          expect(a).to be(b)
        end

        it "raises UnknownVersionError for an invalid version" do
          expect { Kube::Schema["0.0.1"] }.to raise_error(Kube::UnknownVersionError)
        end
      end

      context "with a resource name" do
        it "returns a Class that subclasses Resource" do
          klass = Kube::Schema["Deployment"]
          expect(klass).to be_a(Class)
          expect(klass).to be < Kube::Schema::Resource
        end
      end

      context "with a 'v'-prefixed version string" do
        it "raises IncorrectVersionFormat" do
          expect { Kube::Schema["v1.34"] }.to raise_error(
            Kube::IncorrectVersionFormat,
            /Don't preface the version with a "v"/
          )
        end

        it "suggests the correct format in the error message" do
          expect { Kube::Schema["v1.34"] }.to raise_error(
            Kube::IncorrectVersionFormat,
            /Use Kube::Schema\["1\.34"\] instead/
          )
        end
      end
    end

    describe ".parse" do
      it "returns a typed Resource for a known kind" do
        resource = Kube::Schema.parse("kind" => "Deployment", "apiVersion" => "apps/v1")
        expect(resource).to be_a(Kube::Schema::Resource)
        expect(resource.kind).to eq("Deployment")
        expect(resource.apiVersion).to eq("apps/v1")
      end

      it "works with symbol keys" do
        resource = Kube::Schema.parse(kind: "Pod", apiVersion: "v1", metadata: { name: "web" })
        expect(resource).to be_a(Kube::Schema::Resource)
        expect(resource.kind).to eq("Pod")
        expect(resource.metadata.name).to eq("web")
      end

      it "returns a class backed by the correct schema" do
        resource = Kube::Schema.parse("kind" => "Service", "apiVersion" => "v1")
        expect(resource.class.schema).not_to be_nil
        expect(resource.class.defaults).to eq({ "apiVersion" => "v1", "kind" => "Service" })
      end

      it "round-trips through to_h" do
        original = Kube::Schema["Deployment"].new {
          metadata.name = "web"
          spec.replicas = 3
          spec.selector.matchLabels = { app: "web" }
          spec.template.metadata.labels = { app: "web" }
          spec.template.spec.containers = [{ name: "web", image: "nginx" }]
        }
        parsed = Kube::Schema.parse(original.to_h)
        expect(parsed.kind).to eq("Deployment")
        expect(parsed.metadata.name).to eq("web")
      end

      it "raises ArgumentError for a non-Hash" do
        expect { Kube::Schema.parse("not a hash") }.to raise_error(ArgumentError, /Expected a Hash/)
      end

      it "raises ArgumentError when kind is missing" do
        expect { Kube::Schema.parse("apiVersion" => "v1") }.to raise_error(ArgumentError, /kind/)
      end

      it "raises RuntimeError for an unknown kind" do
        expect { Kube::Schema.parse("kind" => "BogusKind", "apiVersion" => "v1") }.to raise_error(RuntimeError)
      end
    end

    describe ".has_version?" do
      it "returns true for a known version" do
        expect(Kube::Schema.has_version?(Kube::Schema::DEFAULT_VERSION)).to be true
      end

      it "returns false for an unknown version" do
        expect(Kube::Schema.has_version?("0.0.1")).to be false
      end
    end
  end
end
