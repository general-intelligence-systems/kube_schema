# frozen_string_literal: true

require "spec_helper"

RSpec.describe Kube::Schema::Resource do
  let(:mock_schema) do
    {
      "type" => "object",
      "properties" => {
        "apiVersion" => { "type" => "string", "enum" => ["apps/v1"] },
        "kind" => { "type" => "string", "enum" => ["Deployment"] },
        "replicas" => { "type" => "integer" }
      }
    }
  end

  let(:mock_schema_json) { JSON.generate(mock_schema) }

  before do
    allow(Kube::Schema::SchemaCache).to receive(:read).and_return(mock_schema_json)
  end

  describe ".schema" do
    it "returns nil on the base class" do
      expect(described_class.schema).to be_nil
    end
  end

  describe "#initialize" do
    it "accepts a hash" do
      resource = described_class.new("name" => "my-deploy", "kind" => "Deployment")
      # BlackHoleStruct symbolizes keys
      expect(resource.to_h).to include(name: "my-deploy", kind: "Deployment")
    end

    it "creates an empty resource when no arguments are given" do
      resource = described_class.new
      expect(resource.to_h).to eq({})
    end

    it "accepts a block for DSL-style initialization" do
      resource = described_class.new({}) do
        self.type = "custom"
      end
      expect(resource.to_h).to include(type: "custom")
    end
  end

  describe "#to_h" do
    it "returns a hash representation" do
      resource = described_class.new("a" => 1)
      expect(resource.to_h).to be_a(Hash)
    end
  end

  describe "#==" do
    it "considers two resources equal when their data matches" do
      a = described_class.new("kind" => "Pod")
      b = described_class.new("kind" => "Pod")
      expect(a).to eq(b)
    end

    it "considers two resources unequal when their data differs" do
      a = described_class.new("kind" => "Pod")
      b = described_class.new("kind" => "Service")
      expect(a).not_to eq(b)
    end

    it "is not equal to non-Resource objects" do
      resource = described_class.new("kind" => "Pod")
      expect(resource).not_to eq({ "kind" => "Pod" })
    end
  end

  describe "#valid?" do
    it "returns true on the base class (no schema)" do
      resource = described_class.new("anything" => "goes")
      expect(resource.valid?).to be true
    end

    context "with a schema-bearing subclass" do
      let(:klass) { Kube::Schema["Deployment"] }

      it "returns true for data matching the schema" do
        resource = klass.new("apiVersion" => "apps/v1", "kind" => "Deployment")
        expect(resource.valid?).to be true
      end

      it "returns false for data violating the schema" do
        resource = klass.new("replicas" => "not-a-number")
        expect(resource.valid?).to be false
      end
    end
  end

  describe "schema defaults" do
    let(:schema_with_defaults) do
      {
        "type" => "object",
        "properties" => {
          "replicas" => { "type" => "integer", "default" => 1 },
          "paused" => { "type" => "boolean", "default" => false },
          "name" => { "type" => "string" }
        }
      }
    end

    let(:klass) do
      allow(Kube::Schema::SchemaCache).to receive(:read).and_return(JSON.generate(schema_with_defaults))
      Kube::Schema["Deployment"]
    end

    it "inserts default values into the data on initialization" do
      resource = klass.new({})
      expect(resource.to_h).to include(replicas: 1, paused: false)
    end

    it "does not override explicitly provided values" do
      resource = klass.new("replicas" => 3, "paused" => true)
      expect(resource.to_h).to include(replicas: 3, paused: true)
    end

    it "merges defaults with provided values" do
      resource = klass.new("name" => "my-deploy")
      expect(resource.to_h).to include(name: "my-deploy", replicas: 1, paused: false)
    end
  end

  describe "instantiation via Instance lookup" do
    let(:klass) { Kube::Schema["Deployment"] }

    it "returns a Resource instance from .new with a hash" do
      resource = klass.new({})
      expect(resource).to be_a(described_class)
    end

    it "supports block-based initialization" do
      resource = klass.new({}) do
        self.type = "custom"
      end
      expect(resource.to_h).to include(type: "custom")
    end

    it "has a schema attached to the class" do
      expect(klass.schema).to be_a(Hash)
      expect(klass.schema).to have_key("properties")
    end
  end
end
