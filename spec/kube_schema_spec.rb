# frozen_string_literal: true

require "spec_helper"

RSpec.describe KubeSchema do
  describe "::VERSION" do
    it "is defined" do
      expect(KubeSchema::VERSION).not_to be_nil
    end

    it "is a valid semver string" do
      expect(KubeSchema::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
    end
  end

  describe "::DEFAULT_VERSION" do
    it "is a version present in schema_versions" do
      expect(KubeSchema.schema_versions).to include(KubeSchema::DEFAULT_VERSION)
    end
  end

  describe ".schema_versions" do
    it "returns an array of version strings" do
      versions = KubeSchema.schema_versions
      expect(versions).to be_an(Array)
      expect(versions).not_to be_empty
      expect(versions).to all(match(/\A\d+\.\d+/))
    end

    it "is sorted by Gem::Version" do
      versions = KubeSchema.schema_versions
      sorted = versions.sort_by { |v| Gem::Version.new(v) }
      expect(versions).to eq(sorted)
    end

    it "does not include a leading 'v' prefix" do
      expect(KubeSchema.schema_versions).to all(satisfy { |v| !v.start_with?("v") })
    end
  end

  describe ".latest_version" do
    it "returns the last element of schema_versions" do
      expect(KubeSchema.latest_version).to eq(KubeSchema.schema_versions.last)
    end
  end

  describe ".[]" do
    context "with a version string" do
      it "returns an Instance for a known version" do
        instance = KubeSchema["1.33.6"]
        expect(instance).to be_a(KubeSchema::Instance)
        expect(instance.version).to eq("1.33.6")
      end

      it "caches Instance objects by version" do
        a = KubeSchema["1.33.6"]
        b = KubeSchema["1.33.6"]
        expect(a).to be(b)
      end

      it "raises UnknownVersionError for an invalid version" do
        expect { KubeSchema["0.0.1"] }.to raise_error(KubeSchema::UnknownVersionError)
      end


    end

    context "with a resource name" do
      it "returns a Class that subclasses Resource" do
        klass = KubeSchema["Deployment"]
        expect(klass).to be_a(Class)
        expect(klass).to be < KubeSchema::Resource
      end

      it "returns different class objects on repeated calls (not cached at module level)" do
        a = KubeSchema["Deployment"]
        b = KubeSchema["Deployment"]
        # Each call creates a new Instance(DEFAULT_VERSION) so the resource classes are not shared
        expect(a).not_to be(b)
      end
    end

    context "with a partial path query" do
      it "returns a Class that subclasses Resource" do
        # Index paths use format like "flowcontrol.apiserver.k8s.io/watchevent_v1"
        klass = KubeSchema["flowcontrol.apiserver.k8s.io/watchevent"]
        expect(klass).to be_a(Class)
        expect(klass).to be < KubeSchema::Resource
      end
    end

    context "with a 'v'-prefixed version string" do
      it "raises IncorrectVersionFormat" do
        expect { KubeSchema["v1.33.6"] }.to raise_error(
          KubeSchema::IncorrectVersionFormat,
          /Don't preface the version with a "v"/
        )
      end

      it "suggests the correct format in the error message" do
        expect { KubeSchema["v1.33.6"] }.to raise_error(
          KubeSchema::IncorrectVersionFormat,
          /Use KubeSchema\["1\.33\.6"\] instead/
        )
      end
    end
  end

  describe ".parse" do
    it "raises NotImplementedError" do
      expect { KubeSchema.parse({}) }.to raise_error(NotImplementedError)
    end
  end

  describe ".has_version?" do
    it "returns true for a known version" do
      expect(KubeSchema.has_version?(KubeSchema::DEFAULT_VERSION)).to be true
    end

    it "returns false for an unknown version" do
      expect(KubeSchema.has_version?("0.0.1")).to be false
    end
  end
end
