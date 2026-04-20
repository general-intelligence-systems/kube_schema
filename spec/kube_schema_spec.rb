# frozen_string_literal: true

require "spec_helper"

RSpec.describe Kube::Schema do
  describe "::VERSION" do
    it "is defined" do
      expect(Kube::Schema::VERSION).not_to be_nil
    end

    it "is a valid semver string" do
      expect(Kube::Schema::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
    end
  end

  describe "::DEFAULT_VERSION" do
    it "is a version present in schema_versions" do
      expect(Kube::Schema.schema_versions).to include(Kube::Schema::DEFAULT_VERSION)
    end
  end

  describe ".schema_versions" do
    it "returns an array of version strings" do
      versions = Kube::Schema.schema_versions
      expect(versions).to be_an(Array)
      expect(versions).not_to be_empty
      expect(versions).to all(match(/\A\d+\.\d+/))
    end

    it "is sorted by Gem::Version" do
      versions = Kube::Schema.schema_versions
      sorted = versions.sort_by { |v| Gem::Version.new(v) }
      expect(versions).to eq(sorted)
    end

    it "does not include a leading 'v' prefix" do
      expect(Kube::Schema.schema_versions).to all(satisfy { |v| !v.start_with?("v") })
    end
  end

  describe ".latest_version" do
    it "returns the last element of schema_versions" do
      expect(Kube::Schema.latest_version).to eq(Kube::Schema.schema_versions.last)
    end
  end

  describe ".[]" do
    context "with a version string" do
      it "returns an Instance for a known version" do
        instance = Kube::Schema["1.34"]
        expect(instance).to be_a(Kube::Schema::Instance)
        expect(instance.version).to eq("1.34")
      end

      it "caches Instance objects by version" do
        a = Kube::Schema["1.34"]
        b = Kube::Schema["1.34"]
        expect(a).to be(b)
      end

      it "raises UnknownVersionError for an invalid version" do
        expect { Kube::Schema["0.0.1"] }.to raise_error(Kube::UnknownVersionError)
      end
    end

    context "with a resource name" do
      it "returns a Class that subclasses Resource" do
        klass = Kube::Schema["Deployment"]
        expect(klass).to be_a(Class)
        expect(klass).to be < Kube::Schema::Resource
      end
    end

    context "with a 'v'-prefixed version string" do
      it "raises IncorrectVersionFormat" do
        expect { Kube::Schema["v1.34"] }.to raise_error(
          Kube::IncorrectVersionFormat,
          /Don't preface the version with a "v"/
        )
      end

      it "suggests the correct format in the error message" do
        expect { Kube::Schema["v1.34"] }.to raise_error(
          Kube::IncorrectVersionFormat,
          /Use Kube::Schema\["1\.34"\] instead/
        )
      end
    end
  end

  describe ".parse" do
    it "returns a typed Resource for a known kind" do
      resource = Kube::Schema.parse("kind" => "Deployment", "apiVersion" => "apps/v1")
      expect(resource).to be_a(Kube::Schema::Resource)
      expect(resource.kind).to eq("Deployment")
      expect(resource.apiVersion).to eq("apps/v1")
    end

    it "works with symbol keys" do
      resource = Kube::Schema.parse(kind: "Pod", apiVersion: "v1", metadata: { name: "web" })
      expect(resource).to be_a(Kube::Schema::Resource)
      expect(resource.kind).to eq("Pod")
      expect(resource.metadata.name).to eq("web")
    end

    it "returns a class backed by the correct schema" do
      resource = Kube::Schema.parse("kind" => "Service", "apiVersion" => "v1")
      expect(resource.class.schema).not_to be_nil
      expect(resource.class.defaults).to eq({ "apiVersion" => "v1", "kind" => "Service" })
    end

    it "round-trips through to_h" do
      original = Kube::Schema["Deployment"].new {
        metadata.name = "web"
        spec.replicas = 3
        spec.selector.matchLabels = { app: "web" }
        spec.template.metadata.labels = { app: "web" }
        spec.template.spec.containers = [{ name: "web", image: "nginx" }]
      }
      parsed = Kube::Schema.parse(original.to_h)
      expect(parsed.kind).to eq("Deployment")
      expect(parsed.metadata.name).to eq("web")
    end

    it "raises ArgumentError for a non-Hash" do
      expect { Kube::Schema.parse("not a hash") }.to raise_error(ArgumentError, /Expected a Hash/)
    end

    it "raises ArgumentError when kind is missing" do
      expect { Kube::Schema.parse("apiVersion" => "v1") }.to raise_error(ArgumentError, /kind/)
    end

    it "raises RuntimeError for an unknown kind" do
      expect { Kube::Schema.parse("kind" => "BogusKind", "apiVersion" => "v1") }.to raise_error(RuntimeError)
    end
  end

  describe ".has_version?" do
    it "returns true for a known version" do
      expect(Kube::Schema.has_version?(Kube::Schema::DEFAULT_VERSION)).to be true
    end

    it "returns false for an unknown version" do
      expect(Kube::Schema.has_version?("0.0.1")).to be false
    end
  end
end
