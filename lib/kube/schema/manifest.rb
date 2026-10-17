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

      # Ruby pattern matching: `manifest => [Kube::Cluster["Deployment"], *]`.
      def deconstruct = to_a

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


__END__

require "kube/schema"
require "tmpdir"
require "fileutils"

manifest_class = Kube::Schema::Manifest
resource_a = Kube::Schema["Deployment"].new
resource_b = Kube::Schema["Service"].new
resource_c = Kube::Schema["Namespace"].new

describe "Kube::Schema::Manifest" do
  describe "#initialize" do
    it "creates an empty manifest with no arguments" do
      manifest_class.new.count.should == 0
    end

    it "accepts resources as arguments" do
      manifest_class.new(resource_a, resource_b).count.should == 2
    end

    it "accepts a filename keyword argument" do
      manifest_class.new(filename: "/tmp/test.yaml").filename.should == "/tmp/test.yaml"
    end

    it "flattens manifests passed as arguments" do
      inner = manifest_class.new(resource_a, resource_b)
      manifest_class.new(inner, resource_c).count.should == 3
    end
  end

  describe "#<<" do
    it "appends a Resource" do
      manifest = manifest_class.new
      manifest << resource_a
      manifest.count.should == 1
      manifest.first.should == resource_a
    end

    it "returns self for chaining" do
      manifest = manifest_class.new
      (manifest << resource_a).should.be.identical_to manifest
    end

    it "flattens a Manifest (cannot be nested)" do
      manifest = manifest_class.new
      manifest << manifest_class.new(resource_a, resource_b)
      manifest.count.should == 2
      manifest.to_a.should == [resource_a, resource_b]
    end

    it "flattens an Array of Resources" do
      manifest = manifest_class.new
      manifest << [resource_a, resource_b]
      manifest.count.should == 2
    end

    it "raises ArgumentError for a Hash" do
      manifest = manifest_class.new
      error = lambda { manifest << { "kind" => "Pod" } }.should.raise(ArgumentError)
      error.message.should.match(/Expected a Kube::Schema::Resource/)
    end

    it "raises ArgumentError for a String" do
      manifest = manifest_class.new
      lambda { manifest << "not a resource" }.should.raise(ArgumentError)
    end

    it "supports chaining multiple appends" do
      manifest = manifest_class.new
      manifest << resource_a << resource_b << resource_c
      manifest.count.should == 3
    end
  end

  describe "Enumerable" do
    it "includes Enumerable" do
      manifest_class.should.include Enumerable
    end

    it "yields resources in insertion order via #each" do
      resources = []
      manifest_class.new(resource_a, resource_b, resource_c).each { |r| resources << r }
      resources.should == [resource_a, resource_b, resource_c]
    end

    it "supports #map" do
      manifest = manifest_class.new(resource_a, resource_b, resource_c)
      manifest.map { |r| r.to_h[:kind] }.should == ["Deployment", "Service", "Namespace"]
    end

    it "supports #select" do
      manifest = manifest_class.new(resource_a, resource_b, resource_c)
      manifest.select { |r| r.to_h[:kind] == "Service" }.length.should == 1
    end

    it "supports #first and #last" do
      manifest = manifest_class.new(resource_a, resource_b, resource_c)
      manifest.first.should == resource_a
      # Enumerable doesn't provide #last by default, but #to_a does
      manifest.to_a.last.should == resource_c
    end
  end

  describe "#size / #length" do
    it "returns the number of resources" do
      manifest = manifest_class.new(resource_a, resource_b)
      manifest.size.should == 2
      manifest.length.should == 2
    end

    it "returns 0 for an empty manifest" do
      manifest_class.new.size.should == 0
    end
  end

  describe "pattern matching" do
    it "destructures into an array of resources" do
      manifest = manifest_class.new(resource_a, resource_b)
      manifest => [Kube::Schema::Resource => head, *rest]

      head.should == resource_a
      rest.should == [resource_b]
    end

    it "enforces arity" do
      manifest = manifest_class.new(resource_a, resource_b)
      lambda { manifest => [Kube::Schema::Resource] }.should.raise(NoMatchingPatternError)
    end
  end

  describe "#to_a" do
    it "returns a copy of the internal resources array" do
      manifest = manifest_class.new(resource_a, resource_b)
      arr = manifest.to_a
      arr.should == [resource_a, resource_b]

      # Verify it's a copy, not the internal array
      arr << resource_c
      manifest.count.should == 2
    end
  end

  describe "#to_yaml" do
    it "returns multi-document YAML" do
      yaml = manifest_class.new(resource_a, resource_b).to_yaml

      yaml.should.include "---"
      yaml.should.include "kind: Deployment"
      yaml.should.include "kind: Service"
    end

    it "uses string keys (not symbol keys) in output" do
      yaml = manifest_class.new(resource_a).to_yaml

      # Should NOT contain Ruby symbol syntax like `:kind:`
      yaml.should.not.match(/:\w+:/)
      yaml.should.include "kind: Deployment"
      yaml.should.include "apiVersion: apps/v1"
    end

    it "returns empty string for an empty manifest" do
      manifest_class.new.to_yaml.should == ""
    end

    it "produces parseable YAML that round-trips" do
      yaml_output = manifest_class.new(resource_a, resource_b).to_yaml
      docs = if YAML.respond_to?(:safe_load_stream)
               YAML.safe_load_stream(yaml_output)
             else
               YAML.load_stream(yaml_output)
             end
      docs.length.should == 2
      docs[0]["kind"].should == "Deployment"
      docs[1]["kind"].should == "Service"
    end
  end

  describe ".parse" do
    it "parses a single-document YAML string" do
      yaml = { "kind" => "Pod", "apiVersion" => "v1", "metadata" => { "name" => "test" } }.to_yaml
      manifest = manifest_class.parse(yaml)

      manifest.count.should == 1
      manifest.first.should.be.kind_of Kube::Schema::Resource
      manifest.first.kind.should == "Pod"
    end

    it "parses a multi-document YAML string" do
      yaml = [
        { "kind" => "Deployment", "apiVersion" => "apps/v1" },
        { "kind" => "Service", "apiVersion" => "v1" }
      ].map(&:to_yaml).join("")

      manifest_class.parse(yaml).count.should == 2
    end

    it "returns typed Resource subclasses" do
      yaml = { "kind" => "Deployment", "apiVersion" => "apps/v1", "metadata" => { "name" => "web" } }.to_yaml
      resource = manifest_class.parse(yaml).first

      resource.class.defaults.should == { "apiVersion" => "apps/v1", "kind" => "Deployment" }
      resource.kind.should == "Deployment"
    end

    it "skips nil documents (empty YAML docs)" do
      yaml = "---\nkind: Pod\napiVersion: v1\n---\n---\nkind: Service\napiVersion: v1\n"
      manifest_class.parse(yaml).count.should == 2
    end

    it "raises for unknown kinds" do
      yaml = { "kind" => "UnknownCRD", "apiVersion" => "custom.io/v1" }.to_yaml
      lambda { manifest_class.parse(yaml) }.should.raise(RuntimeError)
    end

    it "does not set a filename" do
      yaml = { "kind" => "Pod", "apiVersion" => "v1" }.to_yaml
      manifest_class.parse(yaml).filename.should.be.nil
    end

    it "returns an empty manifest for empty YAML" do
      manifest_class.parse("---\n").count.should == 0
    end
  end

  describe ".open" do
    before { @tmpdir = Dir.mktmpdir("manifest_test") }
    after  { FileUtils.rm_rf(@tmpdir) }

    it "reads a single-document YAML file" do
      path = File.join(@tmpdir, "resources.yaml")
      File.write(path, { "kind" => "Pod", "apiVersion" => "v1" }.to_yaml)

      manifest = manifest_class.open(path)
      manifest.count.should == 1
      manifest.first.should.be.kind_of Kube::Schema::Resource
    end

    it "reads a multi-document YAML file" do
      path = File.join(@tmpdir, "resources.yaml")
      File.write(path, [
        { "kind" => "Deployment", "apiVersion" => "apps/v1" },
        { "kind" => "Service", "apiVersion" => "v1" }
      ].map(&:to_yaml).join(""))

      manifest_class.open(path).count.should == 2
    end

    it "sets the filename" do
      path = File.join(@tmpdir, "resources.yaml")
      File.write(path, { "kind" => "Pod" }.to_yaml)

      manifest_class.open(path).filename.should == path
    end

    it "skips nil documents (empty YAML docs)" do
      path = File.join(@tmpdir, "resources.yaml")
      File.write(path, "---\nkind: Pod\n---\n---\nkind: Service\n")

      manifest_class.open(path).count.should == 2
    end
  end

  describe "#write" do
    before { @tmpdir = Dir.mktmpdir("manifest_test") }
    after  { FileUtils.rm_rf(@tmpdir) }

    it "writes to the given path" do
      path = File.join(@tmpdir, "output.yaml")
      manifest_class.new(resource_a).write(path)

      File.exist?(path).should.be.true
      File.read(path).should.include "kind: Deployment"
    end

    it "writes to the stored filename when no path is given" do
      path = File.join(@tmpdir, "stored.yaml")
      manifest_class.new(resource_a, filename: path).write

      File.exist?(path).should.be.true
    end

    it "updates the filename after writing to a new path" do
      path = File.join(@tmpdir, "new.yaml")
      manifest = manifest_class.new(resource_a)

      manifest.write(path)
      manifest.filename.should == path
    end

    it "returns the path written to" do
      path = File.join(@tmpdir, "result.yaml")
      manifest_class.new(resource_a).write(path).should == path
    end

    it "raises ArgumentError when no path is available" do
      manifest = manifest_class.new(resource_a)
      error = lambda { manifest.write }.should.raise(ArgumentError)
      error.message.should.match(/No filename set/)
    end

    it "round-trips through write and open" do
      path = File.join(@tmpdir, "roundtrip.yaml")
      original = manifest_class.new(resource_a, resource_b)

      original.write(path)
      manifest_class.open(path).count.should == original.count

      content = File.read(path)
      content.should.include "kind: Deployment"
      content.should.include "kind: Service"
    end
  end
end
