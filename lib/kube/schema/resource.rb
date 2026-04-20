# frozen_string_literal: true

module Kube
  module Schema
    class Resource

      def initialize(hash = {}, &block)
        deep_symbolize_keys(self.class.defaults.to_h).then do |defaults|

          # You are NEVER allowed to change `apiVersion` or `kind`
          # Therefore, they are ONLY ever set from the self.defaults
          # property.
          deep_symbolize_keys(hash).then do |symbolized|
            @data = defaults

            # This is extracting "top-level" properties from the input hash
            # such as [apiVersion, spec, metadata, roleRef, ...]
            # We then ignore the rest of the attributes by design.
            self.class.schema_properties.each do |property|
              if symbolized.key?(property)
                @data[property] = symbolized.delete(property)
              end
            end
          end
        end

        if block_given?
          @data.instance_exec(&block)
        end
      end

      # Gets overridden by the factory in Kube::Schema::Instance
      def self.schema
        raise "Kube::Schema::Resource should NOT be instanciated directly"
      end

      def self.schema_properties
        raise "Kube::Schema::Resource should NOT be instanciated directly"
      end

      # Gets overridden by the factory in Kube::Schema::Instance.
      # Returns a frozen Hash like { "apiVersion" => "apps/v1", "kind" => "Deployment" }
      def self.defaults
        raise "Kube::Schema::Resource should NOT be instanciated directly"
      end

      def valid?
        if self.class.schema.nil?
          true
        else
          self.class.schema.valid?(deep_stringify_keys(to_h))
        end
      end

      # Like #valid? but raises Kube::ValidationError with details on failure.
      # The error message includes the resource kind and name for context.
      def valid!
        if self.class.schema.nil?
          true
        else
          data = deep_stringify_keys(to_h)
          errors = self.class.schema.validate(data).to_a

          unless errors.empty?
            kind = self.class.defaults&.dig("kind")
            name = data.dig("metadata", "name")
            raise Kube::ValidationError.new(errors, kind: kind, name: name, manifest: data)
          end

          true
        end
      end

      # Returns the resource data as a Hash. Defaults (apiVersion, kind)
      # from the schema are authoritative and cannot be overridden --
      # they are facts derived from the GVK metadata.
      def to_h
        defaults = self.class.defaults
        data = @data.reject { |_, v| v.is_a?(Hash) && v.empty? }

        if defaults
          symbolized = deep_symbolize_keys(defaults)
          # Defaults go first (for key ordering), then user data minus
          # any attempts to override the authoritative keys.
          symbolized.merge(data.reject { |k, _| symbolized.key?(k) })
        else
          data
        end
      end

      # Serializes to clean Kubernetes YAML.
      # Raises Kube::ValidationError if the resource is not valid.
      def to_yaml
        if valid!
          deep_stringify_keys(to_h).to_yaml
        end
      end

      def ==(other)
        other.is_a?(Resource) && to_h == other.to_h
      end

      private

        def deep_stringify_keys(obj)
          case obj
          when Hash
            obj.each_with_object({}) do |(k, v), result|
              result[k.to_s] = deep_stringify_keys(v)
            end
          when Array
            obj.map { |v| deep_stringify_keys(v) }
          else
            obj
          end
        end

        def deep_symbolize_keys(obj)
          case obj
          when Hash
            obj.each_with_object({}) do |(k, v), result|
              result[k.to_sym] = deep_symbolize_keys(v)
            end
          when Array
            obj.map { |v| deep_symbolize_keys(v) }
          else
            obj
          end
        end
    end
  end
end
