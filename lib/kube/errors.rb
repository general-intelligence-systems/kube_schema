# frozen_string_literal: true

require "yaml"

module Kube
  module Errors
    # Base error for all Kube gems.
    class Error < StandardError; end

    # Raised when a schema version is unknown.
    class UnknownVersionError < Error; end

    # Raised when a version string is formatted incorrectly (e.g. "v1.33.6").
    class IncorrectVersionFormat < Error; end

    class MissingSchemaError < Error; end

    # Raised by Resource#valid! when schema validation fails.
    #
    # @example
    #   Schema validation failed for Deployment "web":
    #     - spec.selector is required but missing
    #     - spec.replicas = "not_a_number" — expected integer, got String
    #   ---
    #   apiVersion: apps/v1
    #   kind: Deployment
    #   spec:
    #     selector:        # MISSING — required
    #     replicas: "nah"  # expected integer, got String
    class ValidationError < Error
      attr_reader :errors

      RED    = "\033[31m"
      YELLOW = "\033[33m"
      RESET  = "\033[0m"

      BOLD      = "\033[1m"
      UNDERLINE = "\033[4m"

      # @param errors   [Array<Hash>] raw JSONSchemer error hashes
      # @param kind     [String, nil] Kubernetes resource kind (e.g. "Deployment")
      # @param name     [String, nil] resource metadata.name (e.g. "web")
      # @param manifest [Hash, nil]   the full resource data that failed validation
      def initialize(errors, kind: nil, name: nil, manifest: nil)
        @errors   = errors
        @kind     = kind
        @name     = name
        @manifest = manifest
        super(build_message)
      end

      # Keeps the backtrace from indenting past column 0.
      # @returns [String] the message, unwrapped for the backtrace.
      def detailed_message(highlight: false, **)
        out = "\n#{BOLD}#{UNDERLINE}#{RED}#{header_line}#{RESET}\n\n"
        out += error_lines.join("\n")
        if @manifest
          out += "\n\n#{annotate_manifest(@manifest, @errors)}"
        end
        out += "\n\n"
        out
      end

      private

        def header_line
          header = "Schema validation failed"
          if @kind
            header += " for #{@kind}"
          end
          if @name
            header += " #{@name.inspect}"
          end
          header
        end

        def error_lines
          @errors.flat_map { |e| format_error(e) }
        end

        # Plain-text message for rescue => e; e.message.
        # @returns [String] the header and formatted error lines.
        def build_message
          msg = "#{header_line}\n#{error_lines.join("\n")}"
          if @manifest
            msg += "\n\n#{annotate_manifest(@manifest, @errors)}"
          end
          msg
        end

        # ── Error line formatting ────────────────────────────────────────

        # Format one JSONSchemer error into readable lines.
        # @parameter error [Hash] a raw JSONSchemer error hash.
        # @returns [String, Array(String)] one or more readable lines.
        def format_error(error)
          path = pointer_to_dot(error["data_pointer"])
          type = error["type"]
          data = error["data"]

          case type
          when "required"
            format_required(error, path)
          when "string", "integer", "number", "boolean", "array", "object", "null"
            "❌ #{path} = #{truncate(data.inspect)} — expected #{type}, got #{data.class}"
          when "minimum"
            limit = error.dig("schema", "minimum")
            "❌ #{path} = #{truncate(data.inspect)} — must be >= #{limit}"
          when "maximum"
            limit = error.dig("schema", "maximum")
            "❌ #{path} = #{truncate(data.inspect)} — must be <= #{limit}"
          when "exclusiveMinimum"
            limit = error.dig("schema", "exclusiveMinimum")
            "❌ #{path} = #{truncate(data.inspect)} — must be > #{limit}"
          when "exclusiveMaximum"
            limit = error.dig("schema", "exclusiveMaximum")
            "❌ #{path} = #{truncate(data.inspect)} — must be < #{limit}"
          when "minLength"
            limit = error.dig("schema", "minLength")
            "❌ #{path} = #{truncate(data.inspect)} — length must be >= #{limit}"
          when "maxLength"
            limit = error.dig("schema", "maxLength")
            "❌ #{path} = #{truncate(data.inspect)} — length must be <= #{limit}"
          when "minItems"
            limit = error.dig("schema", "minItems")
            "❌ #{path} — array must have >= #{limit} items, got #{data.is_a?(Array) ? data.length : data.inspect}"
          when "maxItems"
            limit = error.dig("schema", "maxItems")
            "❌ #{path} — array must have <= #{limit} items, got #{data.is_a?(Array) ? data.length : data.inspect}"
          when "enum"
            allowed = error.dig("schema", "enum")
            "❌ #{path} = #{truncate(data.inspect)} — must be one of: #{truncate(allowed.inspect)}"
          when "const"
            expected = error.dig("schema", "const")
            "❌ #{path} = #{truncate(data.inspect)} — must be #{truncate(expected.inspect)}"
          when "pattern"
            pattern = error.dig("schema", "pattern")
            "❌ #{path} = #{truncate(data.inspect)} — does not match pattern: #{pattern}"
          when "format"
            fmt = error.dig("schema", "format")
            "❌ #{path} = #{truncate(data.inspect)} — invalid #{fmt} format"
          when "multipleOf"
            factor = error.dig("schema", "multipleOf")
            "❌ #{path} = #{truncate(data.inspect)} — must be a multiple of #{factor}"
          when "uniqueItems"
            "❌ #{path} — array items must be unique"
          when "additionalProperties"
            "❌ #{path}: #{error["error"] || "has additional properties that are not allowed"}"
          else
            msg = error["error"] || type
            "❌ #{path}: #{msg}"
          end
        end

        # Format a required error, one line per missing key.
        # @parameter error [Hash] the required-type JSONSchemer error.
        # @parameter path [String] the dot-notation path to the error.
        # @returns [String, Array(String)] one line per missing key.
        def format_required(error, path)
          missing = error.dig("details", "missing_keys") || []
          if missing.empty?
            "❌ #{path}: #{error["error"] || "required"}"
          else
            missing.map do |key|
              "❌ #{join_path(path, key)} is required but missing"
            end
          end
        end

        # Short inline description for annotating YAML lines.
        # @parameter error [Hash] a raw JSONSchemer error hash.
        # @returns [String] a short description of the violation.
        def format_error_short(error)
          type = error["type"]
          data = error["data"]

          case type
          when "string", "integer", "number", "boolean", "array", "object", "null"
            "expected #{type}, got #{data.class}"
          when "minimum"
            "must be >= #{error.dig("schema", "minimum")}"
          when "maximum"
            "must be <= #{error.dig("schema", "maximum")}"
          when "exclusiveMinimum"
            "must be > #{error.dig("schema", "exclusiveMinimum")}"
          when "exclusiveMaximum"
            "must be < #{error.dig("schema", "exclusiveMaximum")}"
          when "minLength"
            "length must be >= #{error.dig("schema", "minLength")}"
          when "maxLength"
            "length must be <= #{error.dig("schema", "maxLength")}"
          when "minItems"
            "array must have >= #{error.dig("schema", "minItems")} items"
          when "maxItems"
            "array must have <= #{error.dig("schema", "maxItems")} items"
          when "enum"
            "must be one of: #{truncate(error.dig("schema", "enum").inspect, max: 40)}"
          when "pattern"
            "does not match pattern: #{error.dig("schema", "pattern")}"
          when "format"
            "invalid #{error.dig("schema", "format")} format"
          when "multipleOf"
            "must be a multiple of #{error.dig("schema", "multipleOf")}"
          when "uniqueItems"
            "array items must be unique"
          else
            error["error"] || type
          end
        end

        # ── Annotated YAML rendering ────────────────────────────────────

        # Render the manifest as annotated, colorized YAML.
        # @parameter manifest [Hash] the resource data that failed validation.
        # @parameter errors [Array(Hash)] the raw JSONSchemer error hashes.
        # @returns [String] the YAML with errors highlighted inline.
        def annotate_manifest(manifest, errors)
          # Maps each error to its formatted message.
          # @example
          #   error_at["/spec/replicas"] => "expected integer, got String"
          #   missing_at["/spec"] => ["selector", "template"]
          error_at   = {}
          missing_at = {}

          errors.each do |e|
            ptr = e["data_pointer"]
            if e["type"] == "required"
              keys = e.dig("details", "missing_keys") || []
              (missing_at[ptr] ||= []).concat(keys)
            else
              error_at[ptr] = format_error_short(e)
            end
          end

          yaml_lines = manifest.to_yaml.lines
          path_stack    = []  # Each entry is [segment, indent_level].
          array_indices = {}  # Current 0-based index per indent level.
          result        = []

          yaml_lines.each do |line|
            raw = line.chomp

            if raw.match?(/\A---\s*$/)
              result << raw
              next
            end

            indent        = line[/\A\s*/].length
            is_array_item = raw.match?(/\A\s*-\s/)

            if is_array_item
              # Array items sit at the same indent as their parent key.
              # Pop anything strictly deeper, but keep the parent.
              path_stack.pop while path_stack.any? && path_stack.last[1] > indent
              array_indices.delete_if { |level, _| level > indent }

              idx = array_indices[indent] || 0
              array_indices[indent] = idx + 1

              # Push the index one level deeper than the "- " prefix
              path_stack.push([idx.to_s, indent + 1])

              # Inline key on the array item: "- name: app"
              if (m = raw.match(/\A\s*-\s+(\w[\w.-]*):/))
                path_stack.push([m[1], indent + 2])
              end
            else
              # Regular key — pop entries at >= this indent
              path_stack.pop while path_stack.any? && path_stack.last[1] >= indent
              array_indices.delete_if { |level, _| level >= indent }

              if (m = raw.match(/\A\s*(\w[\w.-]*):/))
                path_stack.push([m[1], indent])
              end
            end

            pointer = "/" + path_stack.map(&:first).join("/")

            if error_at.key?(pointer)
              result << "#{RED}#{raw}#{RESET}  #{YELLOW}# #{error_at[pointer]}#{RESET}"
            else
              result << raw
            end

            # Inject missing required keys as red lines right after their parent
            if missing_at.key?(pointer)
              child_indent = indent + 2
              missing_at[pointer].each do |mk|
                result << "#{RED}#{" " * child_indent}#{mk}:#{RESET} #{YELLOW}# MISSING — required#{RESET}"
              end
            end
          end

          result.join("\n")
        end

        # ── Helpers ──────────────────────────────────────────────────────

        def pointer_to_dot(pointer)
          if pointer.nil? || pointer.empty?
            "root"
          else
            pointer.delete_prefix("/").gsub("/", ".")
          end
        end

        def join_path(base, key)
          base == "root" ? key.to_s : "#{base}.#{key}"
        end

        def truncate(str, max: 60)
          str.length > max ? "#{str[0...max]}..." : str
        end
    end

    # Raised when a schema download fails.
    class DownloadError < Error
      attr_reader :url, :status_code

      def initialize(message = nil, url: nil, status_code: nil)
        @url         = url
        @status_code = status_code
        super(message || "Failed to download schema: #{@url} (HTTP #{@status_code})")
      end
    end
  end

  # Flat aliases for backward compatibility with pre-nesting code.
  # Local/ConstantMatchesPath requires nesting under Kube::Errors now.
  Error                   = Errors::Error
  UnknownVersionError     = Errors::UnknownVersionError
  IncorrectVersionFormat  = Errors::IncorrectVersionFormat
  MissingSchemaError      = Errors::MissingSchemaError
  ValidationError         = Errors::ValidationError
  DownloadError           = Errors::DownloadError
end


__END__

require "kube/schema"

validation_error = Kube::ValidationError

# Helper to build a minimal JSONSchemer-style error hash.
error_hash = lambda { |overrides = {}|
  {
    "data" => nil,
    "data_pointer" => "",
    "schema" => {},
    "schema_pointer" => "",
    "root_schema" => {},
    "type" => "unknown",
    "error" => "something went wrong"
  }.merge(overrides)
}

describe "Kube::ValidationError" do
  describe "#message header" do
    it "includes kind and name when both are provided" do
      err = validation_error.new([error_hash.()], kind: "Deployment", name: "web")
      err.message.should.include 'Schema validation failed for Deployment "web"'
    end

    it "includes kind without name" do
      err = validation_error.new([error_hash.()], kind: "Service")
      err.message.should.include "Schema validation failed for Service"
    end

    it "shows a generic header when no kind or name" do
      validation_error.new([error_hash.()]).message.should.include "Schema validation failed"
    end
  end

  describe "#message type errors" do
    %w[string integer number boolean array object null].each do |type|
      it "formats #{type} type mismatch with the actual value" do
        err = validation_error.new([
          error_hash.(
            "data_pointer" => "/spec/replicas",
            "type" => type,
            "data" => "bad_value"
          )
        ])
        err.message.should.include "spec.replicas = \"bad_value\" — expected #{type}, got String"
      end
    end

    it "shows integer value for string type error" do
      err = validation_error.new([
        error_hash.(
          "data_pointer" => "/spec/template/image",
          "type" => "string",
          "data" => 2343
        )
      ])
      err.message.should.include "spec.template.image = 2343 — expected string, got Integer"
    end
  end

  describe "#message required errors" do
    it "expands each missing key onto its own line" do
      err = validation_error.new([
        error_hash.(
          "data_pointer" => "/spec",
          "type" => "required",
          "details" => { "missing_keys" => %w[selector template] }
        )
      ])
      err.message.should.include "spec.selector is required but missing"
      err.message.should.include "spec.template is required but missing"
    end

    it "handles required at root level" do
      err = validation_error.new([
        error_hash.(
          "data_pointer" => "",
          "type" => "required",
          "details" => { "missing_keys" => ["spec"] }
        )
      ])
      err.message.should.include "spec is required but missing"
    end

    it "falls back gracefully if missing_keys is absent" do
      err = validation_error.new([
        error_hash.(
          "data_pointer" => "/spec",
          "type" => "required",
          "details" => {}
        )
      ])
      # Should not raise, should produce some message
      err.message.should.include "spec"
    end
  end

  describe "#message numeric constraint errors" do
    it "formats minimum violations" do
      err = validation_error.new([
        error_hash.(
          "data_pointer" => "/spec/replicas",
          "type" => "minimum",
          "data" => -1,
          "schema" => { "minimum" => 0 }
        )
      ])
      err.message.should.include "spec.replicas = -1 — must be >= 0"
    end

    it "formats maximum violations" do
      err = validation_error.new([
        error_hash.(
          "data_pointer" => "/spec/replicas",
          "type" => "maximum",
          "data" => 999,
          "schema" => { "maximum" => 100 }
        )
      ])
      err.message.should.include "spec.replicas = 999 — must be <= 100"
    end

    it "formats exclusiveMinimum violations" do
      err = validation_error.new([
        error_hash.(
          "data_pointer" => "/spec/value",
          "type" => "exclusiveMinimum",
          "data" => 0,
          "schema" => { "exclusiveMinimum" => 0 }
        )
      ])
      err.message.should.include "spec.value = 0 — must be > 0"
    end

    it "formats exclusiveMaximum violations" do
      err = validation_error.new([
        error_hash.(
          "data_pointer" => "/spec/value",
          "type" => "exclusiveMaximum",
          "data" => 100,
          "schema" => { "exclusiveMaximum" => 100 }
        )
      ])
      err.message.should.include "spec.value = 100 — must be < 100"
    end

    it "formats multipleOf violations" do
      err = validation_error.new([
        error_hash.(
          "data_pointer" => "/spec/count",
          "type" => "multipleOf",
          "data" => 7,
          "schema" => { "multipleOf" => 3 }
        )
      ])
      err.message.should.include "spec.count = 7 — must be a multiple of 3"
    end
  end

  describe "#message string constraint errors" do
    it "formats pattern violations" do
      err = validation_error.new([
        error_hash.(
          "data_pointer" => "/metadata/name",
          "type" => "pattern",
          "data" => "INVALID",
          "schema" => { "pattern" => "^[a-z0-9-]+$" }
        )
      ])
      err.message.should.include 'metadata.name = "INVALID" — does not match pattern: ^[a-z0-9-]+$'
    end

    it "formats minLength violations" do
      err = validation_error.new([
        error_hash.(
          "data_pointer" => "/metadata/name",
          "type" => "minLength",
          "data" => "",
          "schema" => { "minLength" => 1 }
        )
      ])
      err.message.should.include 'metadata.name = "" — length must be >= 1'
    end

    it "formats maxLength violations" do
      err = validation_error.new([
        error_hash.(
          "data_pointer" => "/metadata/name",
          "type" => "maxLength",
          "data" => "a" * 300,
          "schema" => { "maxLength" => 253 }
        )
      ])
      err.message.should.include "metadata.name ="
      err.message.should.include "— length must be <= 253"
    end
  end

  describe "#message enum errors" do
    it "shows allowed values" do
      err = validation_error.new([
        error_hash.(
          "data_pointer" => "/spec/type",
          "type" => "enum",
          "data" => "InvalidType",
          "schema" => { "enum" => %w[ClusterIP NodePort LoadBalancer] }
        )
      ])
      err.message.should.include '"InvalidType" — must be one of:'
      err.message.should.include "ClusterIP"
    end
  end

  describe "#message format errors" do
    it "shows the expected format" do
      err = validation_error.new([
        error_hash.(
          "data_pointer" => "/spec/startTime",
          "type" => "format",
          "data" => "not-a-date",
          "schema" => { "format" => "date-time" }
        )
      ])
      err.message.should.include 'spec.startTime = "not-a-date" — invalid date-time format'
    end
  end

  describe "#message array constraint errors" do
    it "formats minItems violations" do
      err = validation_error.new([
        error_hash.(
          "data_pointer" => "/spec/containers",
          "type" => "minItems",
          "data" => [],
          "schema" => { "minItems" => 1 }
        )
      ])
      err.message.should.include "spec.containers — array must have >= 1 items, got 0"
    end

    it "formats uniqueItems violations" do
      err = validation_error.new([
        error_hash.(
          "data_pointer" => "/spec/ports",
          "type" => "uniqueItems",
          "data" => [80, 80]
        )
      ])
      err.message.should.include "spec.ports — array items must be unique"
    end
  end

  describe "#message unknown error types" do
    it "falls back to JSONSchemer's error message" do
      err = validation_error.new([
        error_hash.(
          "data_pointer" => "/spec/something",
          "type" => "oneOf",
          "error" => "value at `/spec/something` does not match exactly one schema"
        )
      ])
      err.message.should.include "spec.something: value at `/spec/something` does not match exactly one schema"
    end

    it "falls back to the type name when no error message exists" do
      err = validation_error.new([
        error_hash.(
          "data_pointer" => "/spec/x",
          "type" => "customKeyword",
          "error" => nil
        )
      ])
      err.message.should.include "spec.x: customKeyword"
    end
  end

  describe "#message value truncation" do
    it "truncates long values" do
      err = validation_error.new([
        error_hash.(
          "data_pointer" => "/spec/data",
          "type" => "integer",
          "data" => "a" * 200
        )
      ])
      err.message.should.include "..."
      err.message.length.should.be < 500
    end
  end

  describe "#message dot-notation path conversion" do
    it "converts JSON pointers to dot notation" do
      err = validation_error.new([
        error_hash.(
          "data_pointer" => "/spec/template/spec/containers/0/image",
          "type" => "string",
          "data" => 123
        )
      ])
      err.message.should.include "spec.template.spec.containers.0.image = 123"
    end

    it "uses 'root' for empty pointer" do
      err = validation_error.new([
        error_hash.(
          "data_pointer" => "",
          "type" => "object",
          "data" => "not_an_object"
        )
      ])
      err.message.should.include "root = "
    end
  end

  describe "#errors" do
    it "exposes the raw JSONSchemer error hashes" do
      raw = [error_hash.("type" => "string")]
      validation_error.new(raw).errors.should.be.identical_to raw
    end
  end

  describe "annotated manifest output" do
    it "includes the resource YAML when manifest is provided" do
      err = validation_error.new(
        [error_hash.("data_pointer" => "/spec/replicas", "type" => "integer", "data" => "bad")],
        kind: "Deployment",
        name: "web",
        manifest: {
          "apiVersion" => "apps/v1",
          "kind" => "Deployment",
          "metadata" => { "name" => "web", "namespace" => "prod" },
          "spec" => { "replicas" => "bad" }
        }
      )
      err.message.should.include "apiVersion: apps/v1"
      err.message.should.include "kind: Deployment"
      err.message.should.include "name: web"
      err.message.should.include "namespace: prod"
      err.message.should.include "replicas: bad"
    end

    it "highlights error lines in red (ANSI)" do
      err = validation_error.new(
        [error_hash.("data_pointer" => "/spec/replicas", "type" => "integer", "data" => "bad")],
        manifest: {
          "apiVersion" => "apps/v1",
          "kind" => "Deployment",
          "spec" => { "replicas" => "bad" }
        }
      )
      # The replicas line should be wrapped in red ANSI
      err.message.should.include "\033[31m"
      err.message.should.match(/\033\[31m\s*replicas: bad\033\[0m/)
    end

    it "appends a yellow inline comment on error lines" do
      err = validation_error.new(
        [error_hash.("data_pointer" => "/spec/replicas", "type" => "integer", "data" => "bad")],
        manifest: {
          "apiVersion" => "v1",
          "kind" => "Pod",
          "spec" => { "replicas" => "bad" }
        }
      )
      err.message.should.match(/\033\[33m# expected integer, got String\033\[0m/)
    end

    it "injects missing required keys as red lines" do
      err = validation_error.new(
        [error_hash.(
          "data_pointer" => "/spec",
          "type" => "required",
          "details" => { "missing_keys" => ["selector"] }
        )],
        manifest: {
          "apiVersion" => "apps/v1",
          "kind" => "Deployment",
          "spec" => { "replicas" => 3 }
        }
      )
      err.message.should.match(/\033\[31m\s*selector:\033\[0m/)
      err.message.should.include "MISSING"
    end

    it "does not color lines that have no errors" do
      err = validation_error.new(
        [error_hash.("data_pointer" => "/spec/replicas", "type" => "integer", "data" => "bad")],
        manifest: {
          "apiVersion" => "apps/v1",
          "kind" => "Deployment",
          "metadata" => { "name" => "web" },
          "spec" => { "replicas" => "bad" }
        }
      )
      # The "name: web" line should NOT have red ANSI
      lines = err.message.each_line.select { |line| line.include?("name: web") }
      lines.should.not.be.empty
      lines.each { |line| line.should.not.include "\033[31m" }
    end

    it "handles array items with correct pointer mapping" do
      err = validation_error.new(
        [error_hash.(
          "data_pointer" => "/spec/containers/0/image",
          "type" => "string",
          "data" => 2343
        )],
        manifest: {
          "apiVersion" => "v1",
          "kind" => "Pod",
          "spec" => {
            "containers" => [
              { "name" => "app", "image" => 2343 }
            ]
          }
        }
      )
      err.message.should.match(/\033\[31m\s*image: 2343\033\[0m/)
    end

    it "omits the manifest section when manifest is nil" do
      err = validation_error.new(
        [error_hash.("data_pointer" => "/spec/x", "type" => "string", "data" => 1)]
      )
      err.message.should.not.include "---"
    end
  end
end
