# frozen_string_literal: true

require "spec_helper"

RSpec.describe KubeSchema::Resource do
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

    it "requires a hash argument (BlackHoleStruct rejects nil)" do
      expect { described_class.new }.to raise_error(ArgumentError)
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

  describe "instantiation via Instance lookup" do
    let(:klass) { KubeSchema["Deployment"] }

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
  end
end
