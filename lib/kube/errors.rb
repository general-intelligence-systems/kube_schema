# frozen_string_literal: true

require "yaml"

module Kube
  # Base error for all Kube gems. Catch this to handle any Kube error.
  class Error < StandardError; end

  # Raised when a schema version is unknown.
  class UnknownVersionError < Error; end

  # Raised when a version string is formatted incorrectly (e.g. "v1.33.6").
  class IncorrectVersionFormat < Error; end

  # Raised by Resource#valid! when data fails schema validation.
  #
  # Produces detailed, human-readable error messages that identify the exact
  # key path and offending value, followed by the resource YAML with error
  # lines highlighted in red and missing keys injected inline.
  #
  #   Schema validation failed for Deployment "web":
  #     - spec.selector is required but missing
  #     - spec.replicas = "not_a_number" — expected integer, got String
  #
  #   ---
  #   apiVersion: apps/v1
  #   kind: Deployment
  #   spec:
  #     selector:        # MISSING — required
  #     replicas: "nah"  # expected integer, got String
  #
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

    # Ruby 3.2+ calls detailed_message for uncaught exceptions.
    # We override it so the message ends at column 0, preventing
    # Ruby from indenting the backtrace to match YAML indentation.
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
        header += " for #{@kind}" if @kind
        header += " #{@name.inspect}" if @name
        header
      end

      def error_lines
        @errors.flat_map { |e| format_error(e) }
      end

      # Plain-text message for programmatic access (e.g. rescue => e; e.message)
      def build_message
        msg = "#{header_line}\n#{error_lines.join("\n")}"
        if @manifest
          msg += "\n\n#{annotate_manifest(@manifest, @errors)}"
        end
        msg
      end

      # ── Error line formatting ────────────────────────────────────────

      # Format a single JSONSchemer error hash into one or more human-readable lines.
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

      # Format a `required` error, expanding each missing key onto its own line.
      def format_required(error, path)
        missing = error.dig("details", "missing_keys") || []
        if missing.empty?
          return "❌ #{path}: #{error["error"] || "required"}"
        end

        missing.map do |key|
          "❌ #{join_path(path, key)} is required but missing"
        end
      end

      # Short inline description for annotating YAML lines.
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

      # Render the manifest as YAML with error lines in red and
      # missing required keys injected as red comment lines.
      def annotate_manifest(manifest, errors)
        # Build two maps from the error list:
        #   error_at["/spec/replicas"]  => "expected integer, got String"
        #   missing_at["/spec"]         => ["selector", "template"]
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
        path_stack    = []  # [[segment, indent_level], ...]
        array_indices = {}  # indent_level -> current 0-based index
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
        return "root" if pointer.nil? || pointer.empty?
        pointer.delete_prefix("/").gsub("/", ".")
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

if __FILE__ == $0
  require "bundler/setup"
  require "rspec/autorun"
  require "kube/schema"

  RSpec.describe Kube::ValidationError do
    # Helper to build a minimal JSONSchemer-style error hash.
    def error_hash(overrides = {})
      {
        "data" => nil,
        "data_pointer" => "",
        "schema" => {},
        "schema_pointer" => "",
        "root_schema" => {},
        "type" => "unknown",
        "error" => "something went wrong"
      }.merge(overrides)
    end

    describe "#message" do
      context "header" do
        it "includes kind and name when both are provided" do
          err = described_class.new(
            [error_hash],
            kind: "Deployment",
            name: "web"
          )
          expect(err.message).to include('Schema validation failed for Deployment "web"')
        end

        it "includes kind without name" do
          err = described_class.new(
            [error_hash],
            kind: "Service"
          )
          expect(err.message).to include("Schema validation failed for Service")
        end

        it "shows a generic header when no kind or name" do
          err = described_class.new([error_hash])
          expect(err.message).to include("Schema validation failed")
        end
      end

      context "type errors" do
        %w[string integer number boolean array object null].each do |type|
          it "formats #{type} type mismatch with the actual value" do
            err = described_class.new([
              error_hash(
                "data_pointer" => "/spec/replicas",
                "type" => type,
                "data" => "bad_value"
              )
            ])
            expect(err.message).to include("spec.replicas = \"bad_value\" — expected #{type}, got String")
          end
        end

        it "shows integer value for string type error" do
          err = described_class.new([
            error_hash(
              "data_pointer" => "/spec/template/image",
              "type" => "string",
              "data" => 2343
            )
          ])
          expect(err.message).to include("spec.template.image = 2343 — expected string, got Integer")
        end
      end

      context "required errors" do
        it "expands each missing key onto its own line" do
          err = described_class.new([
            error_hash(
              "data_pointer" => "/spec",
              "type" => "required",
              "details" => { "missing_keys" => %w[selector template] }
            )
          ])
          expect(err.message).to include("spec.selector is required but missing")
          expect(err.message).to include("spec.template is required but missing")
        end

        it "handles required at root level" do
          err = described_class.new([
            error_hash(
              "data_pointer" => "",
              "type" => "required",
              "details" => { "missing_keys" => ["spec"] }
            )
          ])
          expect(err.message).to include("spec is required but missing")
        end

        it "falls back gracefully if missing_keys is absent" do
          err = described_class.new([
            error_hash(
              "data_pointer" => "/spec",
              "type" => "required",
              "details" => {}
            )
          ])
          # Should not raise, should produce some message
          expect(err.message).to include("spec")
        end
      end

      context "numeric constraint errors" do
        it "formats minimum violations" do
          err = described_class.new([
            error_hash(
              "data_pointer" => "/spec/replicas",
              "type" => "minimum",
              "data" => -1,
              "schema" => { "minimum" => 0 }
            )
          ])
          expect(err.message).to include("spec.replicas = -1 — must be >= 0")
        end

        it "formats maximum violations" do
          err = described_class.new([
            error_hash(
              "data_pointer" => "/spec/replicas",
              "type" => "maximum",
              "data" => 999,
              "schema" => { "maximum" => 100 }
            )
          ])
          expect(err.message).to include("spec.replicas = 999 — must be <= 100")
        end

        it "formats exclusiveMinimum violations" do
          err = described_class.new([
            error_hash(
              "data_pointer" => "/spec/value",
              "type" => "exclusiveMinimum",
              "data" => 0,
              "schema" => { "exclusiveMinimum" => 0 }
            )
          ])
          expect(err.message).to include("spec.value = 0 — must be > 0")
        end

        it "formats exclusiveMaximum violations" do
          err = described_class.new([
            error_hash(
              "data_pointer" => "/spec/value",
              "type" => "exclusiveMaximum",
              "data" => 100,
              "schema" => { "exclusiveMaximum" => 100 }
            )
          ])
          expect(err.message).to include("spec.value = 100 — must be < 100")
        end

        it "formats multipleOf violations" do
          err = described_class.new([
            error_hash(
              "data_pointer" => "/spec/count",
              "type" => "multipleOf",
              "data" => 7,
              "schema" => { "multipleOf" => 3 }
            )
          ])
          expect(err.message).to include("spec.count = 7 — must be a multiple of 3")
        end
      end

      context "string constraint errors" do
        it "formats pattern violations" do
          err = described_class.new([
            error_hash(
              "data_pointer" => "/metadata/name",
              "type" => "pattern",
              "data" => "INVALID",
              "schema" => { "pattern" => "^[a-z0-9-]+$" }
            )
          ])
          expect(err.message).to include('metadata.name = "INVALID" — does not match pattern: ^[a-z0-9-]+$')
        end

        it "formats minLength violations" do
          err = described_class.new([
            error_hash(
              "data_pointer" => "/metadata/name",
              "type" => "minLength",
              "data" => "",
              "schema" => { "minLength" => 1 }
            )
          ])
          expect(err.message).to include('metadata.name = "" — length must be >= 1')
        end

        it "formats maxLength violations" do
          err = described_class.new([
            error_hash(
              "data_pointer" => "/metadata/name",
              "type" => "maxLength",
              "data" => "a" * 300,
              "schema" => { "maxLength" => 253 }
            )
          ])
          expect(err.message).to include("metadata.name =")
          expect(err.message).to include("— length must be <= 253")
        end
      end

      context "enum errors" do
        it "shows allowed values" do
          err = described_class.new([
            error_hash(
              "data_pointer" => "/spec/type",
              "type" => "enum",
              "data" => "InvalidType",
              "schema" => { "enum" => %w[ClusterIP NodePort LoadBalancer] }
            )
          ])
          expect(err.message).to include('"InvalidType" — must be one of:')
          expect(err.message).to include("ClusterIP")
        end
      end

      context "format errors" do
        it "shows the expected format" do
          err = described_class.new([
            error_hash(
              "data_pointer" => "/spec/startTime",
              "type" => "format",
              "data" => "not-a-date",
              "schema" => { "format" => "date-time" }
            )
          ])
          expect(err.message).to include('spec.startTime = "not-a-date" — invalid date-time format')
        end
      end

      context "array constraint errors" do
        it "formats minItems violations" do
          err = described_class.new([
            error_hash(
              "data_pointer" => "/spec/containers",
              "type" => "minItems",
              "data" => [],
              "schema" => { "minItems" => 1 }
            )
          ])
          expect(err.message).to include("spec.containers — array must have >= 1 items, got 0")
        end

        it "formats uniqueItems violations" do
          err = described_class.new([
            error_hash(
              "data_pointer" => "/spec/ports",
              "type" => "uniqueItems",
              "data" => [80, 80]
            )
          ])
          expect(err.message).to include("spec.ports — array items must be unique")
        end
      end

      context "unknown error types" do
        it "falls back to JSONSchemer's error message" do
          err = described_class.new([
            error_hash(
              "data_pointer" => "/spec/something",
              "type" => "oneOf",
              "error" => "value at `/spec/something` does not match exactly one schema"
            )
          ])
          expect(err.message).to include("spec.something: value at `/spec/something` does not match exactly one schema")
        end

        it "falls back to the type name when no error message exists" do
          err = described_class.new([
            error_hash(
              "data_pointer" => "/spec/x",
              "type" => "customKeyword",
              "error" => nil
            )
          ])
          expect(err.message).to include("spec.x: customKeyword")
        end
      end

      context "value truncation" do
        it "truncates long values" do
          long_value = "a" * 200
          err = described_class.new([
            error_hash(
              "data_pointer" => "/spec/data",
              "type" => "integer",
              "data" => long_value
            )
          ])
          expect(err.message).to include("...")
          expect(err.message.length).to be < 500
        end
      end

      context "dot-notation path conversion" do
        it "converts JSON pointers to dot notation" do
          err = described_class.new([
            error_hash(
              "data_pointer" => "/spec/template/spec/containers/0/image",
              "type" => "string",
              "data" => 123
            )
          ])
          expect(err.message).to include("spec.template.spec.containers.0.image = 123")
        end

        it "uses 'root' for empty pointer" do
          err = described_class.new([
            error_hash(
              "data_pointer" => "",
              "type" => "object",
              "data" => "not_an_object"
            )
          ])
          expect(err.message).to include("root = ")
        end
      end
    end

    describe "#errors" do
      it "exposes the raw JSONSchemer error hashes" do
        raw = [error_hash("type" => "string")]
        err = described_class.new(raw)
        expect(err.errors).to equal(raw)
      end
    end

    describe "annotated manifest output" do
      it "includes the resource YAML when manifest is provided" do
        manifest = {
          "apiVersion" => "apps/v1",
          "kind" => "Deployment",
          "metadata" => { "name" => "web", "namespace" => "prod" },
          "spec" => { "replicas" => "bad" }
        }
        err = described_class.new(
          [error_hash("data_pointer" => "/spec/replicas", "type" => "integer", "data" => "bad")],
          kind: "Deployment",
          name: "web",
          manifest: manifest
        )
        expect(err.message).to include("apiVersion: apps/v1")
        expect(err.message).to include("kind: Deployment")
        expect(err.message).to include("name: web")
        expect(err.message).to include("namespace: prod")
        expect(err.message).to include("replicas: bad")
      end

      it "highlights error lines in red (ANSI)" do
        manifest = {
          "apiVersion" => "apps/v1",
          "kind" => "Deployment",
          "spec" => { "replicas" => "bad" }
        }
        err = described_class.new(
          [error_hash("data_pointer" => "/spec/replicas", "type" => "integer", "data" => "bad")],
          manifest: manifest
        )
        # The replicas line should be wrapped in red ANSI
        expect(err.message).to include("\033[31m")
        expect(err.message).to match(/\033\[31m\s*replicas: bad\033\[0m/)
      end

      it "appends a yellow inline comment on error lines" do
        manifest = {
          "apiVersion" => "v1",
          "kind" => "Pod",
          "spec" => { "replicas" => "bad" }
        }
        err = described_class.new(
          [error_hash("data_pointer" => "/spec/replicas", "type" => "integer", "data" => "bad")],
          manifest: manifest
        )
        expect(err.message).to match(/\033\[33m# expected integer, got String\033\[0m/)
      end

      it "injects missing required keys as red lines" do
        manifest = {
          "apiVersion" => "apps/v1",
          "kind" => "Deployment",
          "spec" => { "replicas" => 3 }
        }
        err = described_class.new(
          [error_hash(
            "data_pointer" => "/spec",
            "type" => "required",
            "details" => { "missing_keys" => ["selector"] }
          )],
          manifest: manifest
        )
        expect(err.message).to match(/\033\[31m\s*selector:\033\[0m/)
        expect(err.message).to include("MISSING")
      end

      it "does not color lines that have no errors" do
        manifest = {
          "apiVersion" => "apps/v1",
          "kind" => "Deployment",
          "metadata" => { "name" => "web" },
          "spec" => { "replicas" => "bad" }
        }
        err = described_class.new(
          [error_hash("data_pointer" => "/spec/replicas", "type" => "integer", "data" => "bad")],
          manifest: manifest
        )
        # The "name: web" line should NOT have red ANSI
        err.message.each_line do |line|
          next unless line.include?("name: web")
          expect(line).not_to include("\033[31m")
        end
      end

      it "handles array items with correct pointer mapping" do
        manifest = {
          "apiVersion" => "v1",
          "kind" => "Pod",
          "spec" => {
            "containers" => [
              { "name" => "app", "image" => 2343 }
            ]
          }
        }
        err = described_class.new(
          [error_hash(
            "data_pointer" => "/spec/containers/0/image",
            "type" => "string",
            "data" => 2343
          )],
          manifest: manifest
        )
        expect(err.message).to match(/\033\[31m\s*image: 2343\033\[0m/)
      end

      it "omits the manifest section when manifest is nil" do
        err = described_class.new(
          [error_hash("data_pointer" => "/spec/x", "type" => "string", "data" => 1)]
        )
        expect(err.message).not_to include("---")
      end
    end
  end
end
