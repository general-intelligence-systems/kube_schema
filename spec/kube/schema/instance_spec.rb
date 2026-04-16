# frozen_string_literal: true

require "spec_helper"

RSpec.describe Kube::Schema::Instance do
  subject(:instance) { described_class.new("1.34.4") }

  let(:mock_schema_json) { '{"type":"object","properties":{"apiVersion":{"type":"string"},"kind":{"type":"string"}}}' }

  before do
    allow(Kube::Schema::SchemaCache).to receive(:read).and_return(mock_schema_json)
  end

  describe "#initialize" do
    it "stores the version" do
      expect(instance.version).to eq("1.34.4")
    end

    it "raises UnknownVersionError for a non-version string" do
      expect { described_class.new("not-a-version") }.to raise_error(Kube::Schema::UnknownVersionError)
    end
  end

  describe "#[]" do
    it "returns a Class that subclasses Resource" do
      klass = instance["Deployment"]
      expect(klass).to be_a(Class)
      expect(klass).to be < Kube::Schema::Resource
    end

    it "caches resource classes by key" do
      a = instance["Deployment"]
      b = instance["Deployment"]
      expect(a).to be(b)
    end

    it "raises for an unknown resource" do
      expect { instance["ThisDoesNotExist999"] }.to raise_error(RuntimeError, /No resource schema found/)
    end

    it "can look up by partial path matching the index format" do
      # Index paths are like "v1.34.4/apps/deployment_v1", so "apps/deployment" matches
      klass = instance["apps/deployment"]
      expect(klass).to be_a(Class)
      expect(klass).to be < Kube::Schema::Resource
    end

    it "returns different classes for different resources" do
      deployment = instance["Deployment"]
      service = instance["Service"]
      expect(deployment).not_to eq(service)
    end

    it "loads the schema from SchemaCache" do
      instance["Deployment"]
      expect(Kube::Schema::SchemaCache).to have_received(:read)
    end

    it "attaches the parsed schema to the resource class" do
      klass = instance["Deployment"]
      expect(klass.schema).to be_a(Hash)
      expect(klass.schema).to have_key("properties")
    end
  end
end
