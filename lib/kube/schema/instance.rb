# frozen_string_literal: true

require "json"

module Kube
  module Schema
    # Represents a single Kubernetes version's OpenAPI schema.
    # Lazily loads the JSON and builds an index of group/version/kind strings
    # mapped back to definition keys.
    #
    #   instance = Kube::Schema::Instance.new("v1.33.6")
    #   instance["Deployment"]
    #   instance["apps/v1/Deployment"]
    #   instance.list_resources  #=> sorted array of "group/version/kind" strings
    #
    class Instance
      attr_reader :version

      def initialize(version)
        @resource_classes = {}

        is_a_version = -> (v) { Gem::Version.correct?(v) }

        if is_a_version.(version)
          @version = version
        else
          raise UnknownVersionError.new(
            "\n#{version} is an unknown version..." +
            "\nUse `Kube::Schema.schema_versions` to get a list."
          )
        end
      end

      # Look up a resource by full "group/version/kind" or by bare "Kind".
      # Returns a class that inherits from Kube::Schema::Resource, or nil.
      def [](key)
        Kube::Schema::SchemaIndex.new(version).find(key.downcase).then do |path|
          if path.nil?
            raise "No resource schema found for #{key}!!!!!!!"
          else
            @resource_classes[key] ||= begin
              schema_hash = JSON.parse(Kube::Schema::SchemaCache.read(path))

              Class.new(::Kube::Schema::Resource) do
                @schema = schema_hash

                def self.schema
                  @schema || superclass.schema
                end
              end
            end
          end
        end
      end
    end
  end
end
