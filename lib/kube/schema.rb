# frozen_string_literal: true

require_relative 'monkey_patches'
require_relative 'errors'
require_relative 'schema/version'
require_relative 'schema/resource'
require_relative 'schema/sub_spec'
require_relative 'schema/lazy'
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
          entry: Lazy::Spill.write(key, parsed),
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
        Lazy::Spill.clear
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

      # All API groups known to the default schema version, including any
      # custom schemas registered via .register. The core group is "".
      #
      #   Kube::Schema.api_groups # => ["", "apps", "argoproj.io", "batch", ...]
      #
      # @return [Array<String>] sorted, deduplicated group names
      def api_groups
        self[schema_version || DEFAULT_VERSION].api_groups
      end

      def has_version?(version)
        schema_versions.include?(version)
      end
    end
  end
end



__END__

require "kube/schema"

describe "Kube::Schema" do
  describe "::VERSION" do
    it "is defined" do
      Kube::Schema::VERSION.should.not.be.nil
    end

    it "is a valid semver string" do
      Kube::Schema::VERSION.should.match(/\A\d+\.\d+\.\d+\z/)
    end
  end

  describe "::DEFAULT_VERSION" do
    it "is a version present in schema_versions" do
      Kube::Schema.schema_versions.should.include Kube::Schema::DEFAULT_VERSION
    end
  end

  describe ".schema_versions" do
    it "returns an array of version strings" do
      versions = Kube::Schema.schema_versions
      versions.should.be.kind_of Array
      versions.should.not.be.empty
      versions.should.satisfy("every version looks like a minor release") { |vs| vs.all? { |v| v =~ /\A\d+\.\d+/ } }
    end

    it "is sorted by Gem::Version" do
      versions = Kube::Schema.schema_versions
      versions.should == versions.sort_by { |v| Gem::Version.new(v) }
    end

    it "does not include a leading 'v' prefix" do
      Kube::Schema.schema_versions.should.satisfy("no 'v' prefix") { |vs| vs.none? { |v| v.start_with?("v") } }
    end
  end

  describe ".latest_version" do
    it "returns the last element of schema_versions" do
      Kube::Schema.latest_version.should == Kube::Schema.schema_versions.last
    end
  end

  describe ".[]" do
    describe "with a version string" do
      it "returns an Instance for a known version" do
        instance = Kube::Schema["1.34"]
        instance.should.be.kind_of Kube::Schema::Instance
        instance.version.should == "1.34"
      end

      it "caches Instance objects by version" do
        Kube::Schema["1.34"].should.be.identical_to Kube::Schema["1.34"]
      end

      it "raises UnknownVersionError for an invalid version" do
        lambda { Kube::Schema["0.0.1"] }.should.raise(Kube::UnknownVersionError)
      end
    end

    describe "with a resource name" do
      it "returns a Class that subclasses Resource" do
        klass = Kube::Schema["Deployment"]
        klass.should.be.kind_of Class
        klass.should.be < Kube::Schema::Resource
      end
    end

    describe "with a 'v'-prefixed version string" do
      it "raises IncorrectVersionFormat" do
        error = lambda { Kube::Schema["v1.34"] }.should.raise(Kube::IncorrectVersionFormat)
        error.message.should.match(/Don't preface the version with a "v"/)
      end

      it "suggests the correct format in the error message" do
        error = lambda { Kube::Schema["v1.34"] }.should.raise(Kube::IncorrectVersionFormat)
        error.message.should.match(/Use Kube::Schema\["1\.34"\] instead/)
      end
    end
  end

  describe ".parse" do
    it "returns a typed Resource for a known kind" do
      resource = Kube::Schema.parse("kind" => "Deployment", "apiVersion" => "apps/v1")
      resource.should.be.kind_of Kube::Schema::Resource
      resource.kind.should == "Deployment"
      resource.apiVersion.should == "apps/v1"
    end

    it "works with symbol keys" do
      resource = Kube::Schema.parse(kind: "Pod", apiVersion: "v1", metadata: { name: "web" })
      resource.should.be.kind_of Kube::Schema::Resource
      resource.kind.should == "Pod"
      resource.metadata.name.should == "web"
    end

    it "returns a class backed by the correct schema" do
      resource = Kube::Schema.parse("kind" => "Service", "apiVersion" => "v1")
      resource.class.schema.should.not.be.nil
      resource.class.defaults.should == { "apiVersion" => "v1", "kind" => "Service" }
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
      parsed.kind.should == "Deployment"
      parsed.metadata.name.should == "web"
    end

    it "raises ArgumentError for a non-Hash" do
      error = lambda { Kube::Schema.parse("not a hash") }.should.raise(ArgumentError)
      error.message.should.match(/Expected a Hash/)
    end

    it "raises ArgumentError when kind is missing" do
      error = lambda { Kube::Schema.parse("apiVersion" => "v1") }.should.raise(ArgumentError)
      error.message.should.match(/kind/)
    end

    it "raises RuntimeError for an unknown kind" do
      lambda { Kube::Schema.parse("kind" => "BogusKind", "apiVersion" => "v1") }.should.raise(RuntimeError)
    end
  end

  describe ".has_version?" do
    it "returns true for a known version" do
      Kube::Schema.has_version?(Kube::Schema::DEFAULT_VERSION).should.be.true
    end

    it "returns false for an unknown version" do
      Kube::Schema.has_version?("0.0.1").should.be.false
    end
  end

  describe ".api_groups" do
    it "delegates to the default version's instance" do
      Kube::Schema.api_groups.should == Kube::Schema[Kube::Schema::DEFAULT_VERSION].api_groups
    end

    it "includes core and built-in groups" do
      Kube::Schema.api_groups.should.include ""
      Kube::Schema.api_groups.should.include "apps"
      Kube::Schema.api_groups.should.include "batch"
    end
  end
end
