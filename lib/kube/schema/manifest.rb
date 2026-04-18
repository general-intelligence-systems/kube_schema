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

      # Read a YAML file containing one or more Kubernetes resource documents
      # and return a Manifest populated with Resource objects.
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

        resources = docs.compact.map { |doc| Resource.new(doc) }
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
