# frozen_string_literal: true

require "spec_helper"

RSpec.describe Kube::Schema::Instance do
  subject(:instance) { described_class.new("1.34") }

  describe "#initialize" do
    it "stores the version" do
      expect(instance.version).to eq("1.34")
    end

    it "raises UnknownVersionError for a non-version string" do
      expect { described_class.new("not-a-version") }.to raise_error(Kube::UnknownVersionError)
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

    it "returns different classes for different resources" do
      deployment = instance["Deployment"]
      service = instance["Service"]
      expect(deployment).not_to eq(service)
    end

    it "attaches a schema to the resource class" do
      klass = instance["Deployment"]
      expect(klass.schema).not_to be_nil
    end

    it "is case-insensitive" do
      a = instance["Deployment"]
      b = instance["deployment"]
      expect(a).to be < Kube::Schema::Resource
      expect(b).to be < Kube::Schema::Resource
    end

    it "produces resources that can be instantiated with the block DSL" do
      resource = instance["Deployment"].new {
        metadata.name = "test"
      }
      expect(resource.to_h[:apiVersion]).to eq("apps/v1")
      expect(resource.to_h[:kind]).to eq("Deployment")
      expect(resource.to_h[:metadata][:name]).to eq("test")
    end

    it "attaches defaults (apiVersion and kind) to the resource class" do
      klass = instance["Deployment"]
      expect(klass.defaults).to eq({ "apiVersion" => "apps/v1", "kind" => "Deployment" })
    end

    it "derives correct apiVersion for core resources (empty group)" do
      klass = instance["Pod"]
      expect(klass.defaults).to eq({ "apiVersion" => "v1", "kind" => "Pod" })
    end

    it "derives correct apiVersion for grouped resources" do
      klass = instance["Ingress"]
      expect(klass.defaults).to eq({ "apiVersion" => "networking.k8s.io/v1", "kind" => "Ingress" })
    end
  end

  describe "#list_resources" do
    it "returns a sorted array of kind strings" do
      kinds = instance.list_resources
      expect(kinds).to be_an(Array)
      expect(kinds).not_to be_empty
      expect(kinds).to include("Deployment", "Service", "Namespace", "Pod")
      expect(kinds).to eq(kinds.sort)
    end
  end

  describe "class-level schemer cache" do
    it "shares the schemer across instances of the same version" do
      a = described_class.new("1.34")
      b = described_class.new("1.34")
      # Both should resolve without error and return equivalent classes
      expect(a["Deployment"]).to be < Kube::Schema::Resource
      expect(b["Deployment"]).to be < Kube::Schema::Resource
    end
  end
end
