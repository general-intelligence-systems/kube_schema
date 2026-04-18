# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Kube::Schema::Manifest do
  let(:resource_a) { Kube::Schema::Resource.new("kind" => "Deployment", "apiVersion" => "apps/v1") }
  let(:resource_b) { Kube::Schema::Resource.new("kind" => "Service", "apiVersion" => "v1") }
  let(:resource_c) { Kube::Schema::Resource.new("kind" => "Namespace", "apiVersion" => "v1") }

  describe "#initialize" do
    it "creates an empty manifest with no arguments" do
      manifest = described_class.new
      expect(manifest.count).to eq(0)
    end

    it "accepts resources as arguments" do
      manifest = described_class.new(resource_a, resource_b)
      expect(manifest.count).to eq(2)
    end

    it "accepts a filename keyword argument" do
      manifest = described_class.new(filename: "/tmp/test.yaml")
      expect(manifest.filename).to eq("/tmp/test.yaml")
    end

    it "flattens manifests passed as arguments" do
      inner = described_class.new(resource_a, resource_b)
      outer = described_class.new(inner, resource_c)
      expect(outer.count).to eq(3)
    end
  end

  describe "#<<" do
    subject(:manifest) { described_class.new }

    it "appends a Resource" do
      manifest << resource_a
      expect(manifest.count).to eq(1)
      expect(manifest.first).to eq(resource_a)
    end

    it "returns self for chaining" do
      result = manifest << resource_a
      expect(result).to be(manifest)
    end

    it "flattens a Manifest (cannot be nested)" do
      other = described_class.new(resource_a, resource_b)
      manifest << other
      expect(manifest.count).to eq(2)
      expect(manifest.to_a).to contain_exactly(resource_a, resource_b)
    end

    it "flattens an Array of Resources" do
      manifest << [resource_a, resource_b]
      expect(manifest.count).to eq(2)
    end

    it "raises ArgumentError for a Hash" do
      expect { manifest << { "kind" => "Pod" } }.to raise_error(ArgumentError, /Expected a Kube::Schema::Resource/)
    end

    it "raises ArgumentError for a String" do
      expect { manifest << "not a resource" }.to raise_error(ArgumentError)
    end

    it "supports chaining multiple appends" do
      manifest << resource_a << resource_b << resource_c
      expect(manifest.count).to eq(3)
    end
  end

  describe "Enumerable" do
    subject(:manifest) { described_class.new(resource_a, resource_b, resource_c) }

    it "includes Enumerable" do
      expect(described_class).to include(Enumerable)
    end

    it "yields resources in insertion order via #each" do
      resources = []
      manifest.each { |r| resources << r }
      expect(resources).to eq([resource_a, resource_b, resource_c])
    end

    it "supports #map" do
      kinds = manifest.map { |r| r.to_h[:kind] }
      expect(kinds).to eq(["Deployment", "Service", "Namespace"])
    end

    it "supports #select" do
      services = manifest.select { |r| r.to_h[:kind] == "Service" }
      expect(services.length).to eq(1)
    end

    it "supports #first and #last" do
      expect(manifest.first).to eq(resource_a)
      # Enumerable doesn't provide #last by default, but #to_a does
      expect(manifest.to_a.last).to eq(resource_c)
    end
  end

  describe "#size / #length" do
    it "returns the number of resources" do
      manifest = described_class.new(resource_a, resource_b)
      expect(manifest.size).to eq(2)
      expect(manifest.length).to eq(2)
    end

    it "returns 0 for an empty manifest" do
      manifest = described_class.new
      expect(manifest.size).to eq(0)
    end
  end

  describe "#to_a" do
    it "returns a copy of the internal resources array" do
      manifest = described_class.new(resource_a, resource_b)
      arr = manifest.to_a
      expect(arr).to eq([resource_a, resource_b])

      # Verify it's a copy, not the internal array
      arr << resource_c
      expect(manifest.count).to eq(2)
    end
  end

  describe "#to_yaml" do
    it "returns multi-document YAML" do
      manifest = described_class.new(resource_a, resource_b)
      yaml = manifest.to_yaml

      expect(yaml).to include("---")
      expect(yaml).to include("kind: Deployment")
      expect(yaml).to include("kind: Service")
    end

    it "uses string keys (not symbol keys) in output" do
      manifest = described_class.new(resource_a)
      yaml = manifest.to_yaml

      # Should NOT contain Ruby symbol syntax like `:kind:`
      expect(yaml).not_to match(/:\w+:/)
      expect(yaml).to include("kind: Deployment")
      expect(yaml).to include("apiVersion: apps/v1")
    end

    it "returns empty string for an empty manifest" do
      manifest = described_class.new
      expect(manifest.to_yaml).to eq("")
    end

    it "produces parseable YAML that round-trips" do
      manifest = described_class.new(resource_a, resource_b)
      yaml_output = manifest.to_yaml
      docs = if YAML.respond_to?(:safe_load_stream)
               YAML.safe_load_stream(yaml_output)
             else
               YAML.load_stream(yaml_output)
             end
      expect(docs.length).to eq(2)
      expect(docs[0]["kind"]).to eq("Deployment")
      expect(docs[1]["kind"]).to eq("Service")
    end
  end

  describe ".open" do
    let(:tmpdir) { Dir.mktmpdir("manifest_test") }
    let(:yaml_path) { File.join(tmpdir, "resources.yaml") }

    after { FileUtils.rm_rf(tmpdir) }

    it "reads a single-document YAML file" do
      File.write(yaml_path, { "kind" => "Pod", "apiVersion" => "v1" }.to_yaml)

      manifest = described_class.open(yaml_path)
      expect(manifest.count).to eq(1)
      expect(manifest.first.to_h).to include(kind: "Pod")
    end

    it "reads a multi-document YAML file" do
      content = [
        { "kind" => "Deployment", "apiVersion" => "apps/v1" },
        { "kind" => "Service", "apiVersion" => "v1" }
      ].map(&:to_yaml).join("")

      File.write(yaml_path, content)

      manifest = described_class.open(yaml_path)
      expect(manifest.count).to eq(2)
    end

    it "sets the filename" do
      File.write(yaml_path, { "kind" => "Pod" }.to_yaml)

      manifest = described_class.open(yaml_path)
      expect(manifest.filename).to eq(yaml_path)
    end

    it "skips nil documents (empty YAML docs)" do
      File.write(yaml_path, "---\nkind: Pod\n---\n---\nkind: Service\n")

      manifest = described_class.open(yaml_path)
      expect(manifest.count).to eq(2)
    end
  end

  describe "#write" do
    let(:tmpdir) { Dir.mktmpdir("manifest_test") }

    after { FileUtils.rm_rf(tmpdir) }

    it "writes to the given path" do
      path = File.join(tmpdir, "output.yaml")
      manifest = described_class.new(resource_a)

      manifest.write(path)
      expect(File.exist?(path)).to be true

      content = File.read(path)
      expect(content).to include("kind: Deployment")
    end

    it "writes to the stored filename when no path is given" do
      path = File.join(tmpdir, "stored.yaml")
      manifest = described_class.new(resource_a, filename: path)

      manifest.write
      expect(File.exist?(path)).to be true
    end

    it "updates the filename after writing to a new path" do
      path = File.join(tmpdir, "new.yaml")
      manifest = described_class.new(resource_a)

      manifest.write(path)
      expect(manifest.filename).to eq(path)
    end

    it "returns the path written to" do
      path = File.join(tmpdir, "result.yaml")
      manifest = described_class.new(resource_a)

      result = manifest.write(path)
      expect(result).to eq(path)
    end

    it "raises ArgumentError when no path is available" do
      manifest = described_class.new(resource_a)
      expect { manifest.write }.to raise_error(ArgumentError, /No filename set/)
    end

    it "round-trips through write and open" do
      path = File.join(tmpdir, "roundtrip.yaml")
      original = described_class.new(resource_a, resource_b)

      original.write(path)
      loaded = described_class.open(path)

      expect(loaded.count).to eq(original.count)
      expect(loaded.map { |r| r.to_h[:kind] }).to eq(["Deployment", "Service"])
    end
  end
end
