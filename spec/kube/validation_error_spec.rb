# frozen_string_literal: true

require "spec_helper"

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
