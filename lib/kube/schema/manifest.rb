# frozen_string_literal: true

require "yaml"

module Kube
  module Schema
    # A flat, ordered collection of Kubernetes resources.
    #
    # Manifest is Enumerable over Resource objects. It cannot be nested —
    # appending one Manifest into another extracts and flattens its resources.
    #
    #   manifest = Kube::Schema::Manifest.new
    #   manifest << deployment_resource
    #   manifest << another_manifest   # flattened automatically
    #   puts manifest.to_yaml          # multi-document YAML output
    #
    # File I/O:
    #   manifest = Kube::Schema::Manifest.open("cluster.yaml")
    #   manifest << new_resource
    #   manifest.write
    #
    class Manifest
      include Enumerable

      attr_reader :filename

      # Create a new Manifest, optionally seeded with resources.
      #
      # @param resources [Array<Resource, Manifest>] initial resources to include
      # @param filename  [String, nil] optional filename for file-backed manifests
      def initialize(*resources, filename: nil)
        @resources = []
        @filename  = filename

        resources.each { |r| self << r }
      end

      # Append a resource, manifest, or array of resources.
      #
      # - Resource objects are appended directly.
      # - Manifest objects are flattened — their resources are extracted.
      # - Arrays are iterated and each element is appended.
      #
      # @param item [Resource, Manifest, Array]
      # @return [self]
      def <<(item)
        case item
        when Manifest
          item.each { |r| @resources << r }
        when Array
          item.each { |r| self << r }
        when Resource
          @resources << item
        else
          raise ArgumentError,
            "Expected a Kube::Schema::Resource or Manifest, got #{item.class}. " \
            "Use Kube::Schema.parse(hash) once it is implemented to convert hashes."
        end

        self
      end

      # @yield [Resource] each resource in insertion order
      def each(&block)
        @resources.each(&block)
      end

      # Number of resources in the manifest.
      def size
        @resources.size
      end
      alias_method :length, :size

      # Returns the manifest as multi-document YAML, separated by "---".
      # This is the standard format for Kubernetes manifest files.
      #
      # @return [String]
      def to_yaml
        @resources.map { |r| r.to_yaml }.join("")
      end

      # Returns an array of resource hashes.
      #
      # @return [Array<Hash>]
      def to_a
        @resources.dup
      end

      # -------------------------------------------------------------------
      # File I/O
      # -------------------------------------------------------------------

      # Parse a YAML string containing one or more Kubernetes resource
      # documents and return a Manifest populated with typed Resource objects.
      #
      # Each document's "kind" is resolved via Kube::Schema.parse to
      # produce the correct Resource subclass (e.g. Deployment, Service).
      # Documents without a recognized "kind" fall back to a bare Resource.
      #
      #   yaml = `helm template my-release bitnami/nginx`
      #   manifest = Kube::Schema::Manifest.parse(yaml)
      #   manifest.first.class  #=> Kube::Schema::Resource (Deployment subclass)
      #
      # @param yaml_string [String] multi-document YAML
      # @return [Manifest]
      def self.parse(yaml_string)
        docs = if YAML.respond_to?(:safe_load_stream)
                 YAML.safe_load_stream(yaml_string, permitted_classes: [Symbol])
               else
                 YAML.load_stream(yaml_string)
               end

        resources = docs.compact.map { |doc| parse_doc(doc) }
        new(*resources)
      end

      # Read a YAML file containing one or more Kubernetes resource documents
      # and return a Manifest populated with typed Resource objects.
      #
      #   manifest = Kube::Schema::Manifest.open("deploy.yaml")
      #   manifest.count  #=> 3
      #   manifest.filename #=> "deploy.yaml"
      #
      # @param path [String] path to a YAML file
      # @return [Manifest]
      def self.open(path)
        contents = File.read(path)
        docs = if YAML.respond_to?(:safe_load_stream)
                 YAML.safe_load_stream(contents, permitted_classes: [Symbol])
               else
                 # Ruby < 3.1 fallback
                 YAML.load_stream(contents)
               end

        resources = docs.compact.map { |doc| parse_doc(doc) }
        new(*resources, filename: path)
      end

      # Write the manifest to a file as multi-document YAML.
      #
      # @param path [String, nil] destination path; defaults to the filename
      #   the manifest was opened from.
      # @return [String] the path written to
      # @raise [ArgumentError] if no path is given and no filename is set
      def write(path = nil)
        path ||= @filename
        raise ArgumentError, "No filename set. Pass a path to #write or use Manifest.open." if path.nil?

        File.write(path, to_yaml)
        @filename = path
        path
      end

      # Parse a single YAML document hash into a typed Resource.
      #
      # @param doc [Hash] a parsed YAML document
      # @return [Resource]
      # @raise [RuntimeError] if the kind is not recognized
      def self.parse_doc(doc)
        Kube::Schema.parse(doc)
      end
      private_class_method :parse_doc

      private

        # Deep-stringify keys for clean YAML output.
        # (Hash#to_yaml with symbol keys produces `:key:` which is ugly.)
        def deep_stringify(obj)
          case obj
          when Hash
            obj.each_with_object({}) do |(k, v), result|
              result[k.to_s] = deep_stringify(v)
            end
          when Array
            obj.map { |v| deep_stringify(v) }
          else
            obj
          end
        end
    end
  end
end

if __FILE__ == $0
  require "bundler/setup"
  require "rspec/autorun"
  require "kube/schema"
  require "tmpdir"

  RSpec.describe Kube::Schema::Manifest do
    let(:resource_a) { Kube::Schema["Deployment"].new }
    let(:resource_b) { Kube::Schema["Service"].new }
    let(:resource_c) { Kube::Schema["Namespace"].new }

    describe "#initialize" do
      it "creates an empty manifest with no arguments" do
        manifest = described_class.new
        expect(manifest.count).to eq(0)
      end

      it "accepts resources as arguments" do
        manifest = described_class.new(resource_a, resource_b)
        expect(manifest.count).to eq(2)
      end

      it "accepts a filename keyword argument" do
        manifest = described_class.new(filename: "/tmp/test.yaml")
        expect(manifest.filename).to eq("/tmp/test.yaml")
      end

      it "flattens manifests passed as arguments" do
        inner = described_class.new(resource_a, resource_b)
        outer = described_class.new(inner, resource_c)
        expect(outer.count).to eq(3)
      end
    end

    describe "#<<" do
      subject(:manifest) { described_class.new }

      it "appends a Resource" do
        manifest << resource_a
        expect(manifest.count).to eq(1)
        expect(manifest.first).to eq(resource_a)
      end

      it "returns self for chaining" do
        result = manifest << resource_a
        expect(result).to be(manifest)
      end

      it "flattens a Manifest (cannot be nested)" do
        other = described_class.new(resource_a, resource_b)
        manifest << other
        expect(manifest.count).to eq(2)
        expect(manifest.to_a).to contain_exactly(resource_a, resource_b)
      end

      it "flattens an Array of Resources" do
        manifest << [resource_a, resource_b]
        expect(manifest.count).to eq(2)
      end

      it "raises ArgumentError for a Hash" do
        expect { manifest << { "kind" => "Pod" } }.to raise_error(ArgumentError, /Expected a Kube::Schema::Resource/)
      end

      it "raises ArgumentError for a String" do
        expect { manifest << "not a resource" }.to raise_error(ArgumentError)
      end

      it "supports chaining multiple appends" do
        manifest << resource_a << resource_b << resource_c
        expect(manifest.count).to eq(3)
      end
    end

    describe "Enumerable" do
      subject(:manifest) { described_class.new(resource_a, resource_b, resource_c) }

      it "includes Enumerable" do
        expect(described_class).to include(Enumerable)
      end

      it "yields resources in insertion order via #each" do
        resources = []
        manifest.each { |r| resources << r }
        expect(resources).to eq([resource_a, resource_b, resource_c])
      end

      it "supports #map" do
        kinds = manifest.map { |r| r.to_h[:kind] }
        expect(kinds).to eq(["Deployment", "Service", "Namespace"])
      end

      it "supports #select" do
        services = manifest.select { |r| r.to_h[:kind] == "Service" }
        expect(services.length).to eq(1)
      end

      it "supports #first and #last" do
        expect(manifest.first).to eq(resource_a)
        # Enumerable doesn't provide #last by default, but #to_a does
        expect(manifest.to_a.last).to eq(resource_c)
      end
    end

    describe "#size / #length" do
      it "returns the number of resources" do
        manifest = described_class.new(resource_a, resource_b)
        expect(manifest.size).to eq(2)
        expect(manifest.length).to eq(2)
      end

      it "returns 0 for an empty manifest" do
        manifest = described_class.new
        expect(manifest.size).to eq(0)
      end
    end

    describe "#to_a" do
      it "returns a copy of the internal resources array" do
        manifest = described_class.new(resource_a, resource_b)
        arr = manifest.to_a
        expect(arr).to eq([resource_a, resource_b])

        # Verify it's a copy, not the internal array
        arr << resource_c
        expect(manifest.count).to eq(2)
      end
    end

    describe "#to_yaml" do
      it "returns multi-document YAML" do
        manifest = described_class.new(resource_a, resource_b)
        yaml = manifest.to_yaml

        expect(yaml).to include("---")
        expect(yaml).to include("kind: Deployment")
        expect(yaml).to include("kind: Service")
      end

      it "uses string keys (not symbol keys) in output" do
        manifest = described_class.new(resource_a)
        yaml = manifest.to_yaml

        # Should NOT contain Ruby symbol syntax like `:kind:`
        expect(yaml).not_to match(/:\w+:/)
        expect(yaml).to include("kind: Deployment")
        expect(yaml).to include("apiVersion: apps/v1")
      end

      it "returns empty string for an empty manifest" do
        manifest = described_class.new
        expect(manifest.to_yaml).to eq("")
      end

      it "produces parseable YAML that round-trips" do
        manifest = described_class.new(resource_a, resource_b)
        yaml_output = manifest.to_yaml
        docs = if YAML.respond_to?(:safe_load_stream)
                 YAML.safe_load_stream(yaml_output)
               else
                 YAML.load_stream(yaml_output)
               end
        expect(docs.length).to eq(2)
        expect(docs[0]["kind"]).to eq("Deployment")
        expect(docs[1]["kind"]).to eq("Service")
      end
    end

    describe ".parse" do
      it "parses a single-document YAML string" do
        yaml = { "kind" => "Pod", "apiVersion" => "v1", "metadata" => { "name" => "test" } }.to_yaml
        manifest = described_class.parse(yaml)

        expect(manifest.count).to eq(1)
        expect(manifest.first).to be_a(Kube::Schema::Resource)
        expect(manifest.first.kind).to eq("Pod")
      end

      it "parses a multi-document YAML string" do
        yaml = [
          { "kind" => "Deployment", "apiVersion" => "apps/v1" },
          { "kind" => "Service", "apiVersion" => "v1" }
        ].map(&:to_yaml).join("")

        manifest = described_class.parse(yaml)
        expect(manifest.count).to eq(2)
      end

      it "returns typed Resource subclasses" do
        yaml = { "kind" => "Deployment", "apiVersion" => "apps/v1", "metadata" => { "name" => "web" } }.to_yaml
        manifest = described_class.parse(yaml)

        resource = manifest.first
        expect(resource.class.defaults).to eq({ "apiVersion" => "apps/v1", "kind" => "Deployment" })
        expect(resource.kind).to eq("Deployment")
      end

      it "skips nil documents (empty YAML docs)" do
        yaml = "---\nkind: Pod\napiVersion: v1\n---\n---\nkind: Service\napiVersion: v1\n"
        manifest = described_class.parse(yaml)
        expect(manifest.count).to eq(2)
      end

      it "raises for unknown kinds" do
        yaml = { "kind" => "UnknownCRD", "apiVersion" => "custom.io/v1" }.to_yaml
        expect { described_class.parse(yaml) }.to raise_error(RuntimeError)
      end

      it "does not set a filename" do
        yaml = { "kind" => "Pod", "apiVersion" => "v1" }.to_yaml
        manifest = described_class.parse(yaml)
        expect(manifest.filename).to be_nil
      end

      it "returns an empty manifest for empty YAML" do
        manifest = described_class.parse("---\n")
        expect(manifest.count).to eq(0)
      end
    end

    describe ".open" do
      let(:tmpdir) { Dir.mktmpdir("manifest_test") }
      let(:yaml_path) { File.join(tmpdir, "resources.yaml") }

      after { FileUtils.rm_rf(tmpdir) }

      it "reads a single-document YAML file" do
        File.write(yaml_path, { "kind" => "Pod", "apiVersion" => "v1" }.to_yaml)

        manifest = described_class.open(yaml_path)
        expect(manifest.count).to eq(1)
        expect(manifest.first).to be_a(Kube::Schema::Resource)
      end

      it "reads a multi-document YAML file" do
        content = [
          { "kind" => "Deployment", "apiVersion" => "apps/v1" },
          { "kind" => "Service", "apiVersion" => "v1" }
        ].map(&:to_yaml).join("")

        File.write(yaml_path, content)

        manifest = described_class.open(yaml_path)
        expect(manifest.count).to eq(2)
      end

      it "sets the filename" do
        File.write(yaml_path, { "kind" => "Pod" }.to_yaml)

        manifest = described_class.open(yaml_path)
        expect(manifest.filename).to eq(yaml_path)
      end

      it "skips nil documents (empty YAML docs)" do
        File.write(yaml_path, "---\nkind: Pod\n---\n---\nkind: Service\n")

        manifest = described_class.open(yaml_path)
        expect(manifest.count).to eq(2)
      end
    end

    describe "#write" do
      let(:tmpdir) { Dir.mktmpdir("manifest_test") }

      after { FileUtils.rm_rf(tmpdir) }

      it "writes to the given path" do
        path = File.join(tmpdir, "output.yaml")
        manifest = described_class.new(resource_a)

        manifest.write(path)
        expect(File.exist?(path)).to be true

        content = File.read(path)
        expect(content).to include("kind: Deployment")
      end

      it "writes to the stored filename when no path is given" do
        path = File.join(tmpdir, "stored.yaml")
        manifest = described_class.new(resource_a, filename: path)

        manifest.write
        expect(File.exist?(path)).to be true
      end

      it "updates the filename after writing to a new path" do
        path = File.join(tmpdir, "new.yaml")
        manifest = described_class.new(resource_a)

        manifest.write(path)
        expect(manifest.filename).to eq(path)
      end

      it "returns the path written to" do
        path = File.join(tmpdir, "result.yaml")
        manifest = described_class.new(resource_a)

        result = manifest.write(path)
        expect(result).to eq(path)
      end

      it "raises ArgumentError when no path is available" do
        manifest = described_class.new(resource_a)
        expect { manifest.write }.to raise_error(ArgumentError, /No filename set/)
      end

      it "round-trips through write and open" do
        path = File.join(tmpdir, "roundtrip.yaml")
        original = described_class.new(resource_a, resource_b)

        original.write(path)
        loaded = described_class.open(path)

        expect(loaded.count).to eq(original.count)

        content = File.read(path)
        expect(content).to include("kind: Deployment")
        expect(content).to include("kind: Service")
      end
    end
  end
end
