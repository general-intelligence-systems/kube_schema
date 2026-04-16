# frozen_string_literal: true

require "spec_helper"

RSpec.describe KubeSchema::SchemaIndex do
  subject(:index) { described_class.new("1.34.4") }

  describe "#find" do
    it "returns a path matching the query" do
      result = index.find("deployment")
      expect(result).to be_a(String)
      expect(result.downcase).to include("deployment")
    end

    it "returns a path with the version prefix for kubernetes resources" do
      result = index.find("apps/deployment")
      expect(result).to start_with("v1.34.4/")
    end

    it "is case-insensitive" do
      lower = index.find("deployment")
      upper = index.find("Deployment")
      expect(lower).to eq(upper)
    end

    it "returns nil when no match is found" do
      result = index.find("definitelynotaresource999")
      expect(result).to be_nil
    end
  end

  describe "#all_paths" do
    it "returns a non-empty array of path strings" do
      paths = index.all_paths
      expect(paths).to be_an(Array)
      expect(paths).not_to be_empty
      expect(paths).to all(be_a(String))
    end

    it "combines kubernetes paths and custom resource paths" do
      k8s_count = index.kubernetes_paths.length
      crd_count = index.custom_resource_paths.length
      expect(index.all_paths.length).to eq(crd_count + k8s_count)
    end
  end

  describe "#kubernetes_paths" do
    it "returns paths for the given version" do
      paths = index.kubernetes_paths
      expect(paths).not_to be_empty
    end

    it "includes the version prefix in each path" do
      expect(index.kubernetes_paths).to all(start_with("v1.34.4/"))
    end

    it "strips .json extensions from paths" do
      expect(index.kubernetes_paths).to all(satisfy { |p| !p.end_with?(".json") })
    end
  end

  describe "#custom_resource_paths" do
    it "returns CRD paths" do
      paths = index.custom_resource_paths
      expect(paths).not_to be_empty
    end

    it "strips .json extensions from paths" do
      expect(index.custom_resource_paths).to all(satisfy { |p| !p.end_with?(".json") })
    end
  end
end
