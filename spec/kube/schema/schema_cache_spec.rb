# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Kube::Schema::SchemaCache do
  let(:tmpdir) { Dir.mktmpdir("kube_schema_cache_test") }

  before do
    @original_cache_dir = described_class.cache_dir
    described_class.cache_dir = tmpdir
  end

  after do
    described_class.cache_dir = @original_cache_dir
    FileUtils.rm_rf(tmpdir)
  end

  describe ".cache_dir" do
    it "returns the configured cache directory" do
      expect(described_class.cache_dir).to eq(tmpdir)
    end
  end

  describe ".local_path" do
    it "returns a path under cache_dir with .json extension" do
      path = described_class.local_path("v1.34.4/deployment")
      expect(path).to eq(File.join(tmpdir, "v1.34.4/deployment.json"))
    end
  end

  describe ".cached?" do
    it "returns false when a schema is not cached" do
      expect(described_class.cached?("v1.34.4/deployment")).to be false
    end

    it "returns true when a schema file exists locally" do
      local = described_class.local_path("v1.34.4/deployment")
      FileUtils.mkdir_p(File.dirname(local))
      File.write(local, '{"type":"object"}')

      expect(described_class.cached?("v1.34.4/deployment")).to be true
    end
  end

  describe ".evict" do
    it "removes a cached schema file" do
      local = described_class.local_path("v1.34.4/deployment")
      FileUtils.mkdir_p(File.dirname(local))
      File.write(local, '{"type":"object"}')

      described_class.evict("v1.34.4/deployment")
      expect(File.exist?(local)).to be false
    end

    it "does not raise when evicting a non-existent file" do
      expect { described_class.evict("nonexistent/path") }.not_to raise_error
    end
  end

  describe ".clear!" do
    it "removes the entire cache directory" do
      local = described_class.local_path("v1.34.4/deployment")
      FileUtils.mkdir_p(File.dirname(local))
      File.write(local, '{"type":"object"}')

      described_class.clear!
      expect(Dir.exist?(tmpdir)).to be false
    end
  end

  describe ".fetch" do
    it "returns a local file path when already cached" do
      local = described_class.local_path("v1.34.4/deployment")
      FileUtils.mkdir_p(File.dirname(local))
      File.write(local, '{"type":"object"}')

      result = described_class.fetch("v1.34.4/deployment")
      expect(result).to eq(local)
    end

    it "downloads and returns the local file path when not cached" do
      response = instance_double(Net::HTTPSuccess, body: '{"type":"object"}')
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(Net::HTTP).to receive(:get_response).and_return(response)

      result = described_class.fetch("v1.34.4/apps/deployment_v1")
      expect(result).to be_a(String)
      expect(result).to eq(described_class.local_path("v1.34.4/apps/deployment_v1"))
      expect(File.exist?(result)).to be true
    end

    it "raises DownloadError on HTTP failure" do
      response = instance_double(Net::HTTPNotFound, code: "404")
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow(Net::HTTP).to receive(:get_response).and_return(response)

      expect { described_class.fetch("v1.34.4/nonexistent") }.to raise_error(
        Kube::Schema::SchemaCache::DownloadError, /HTTP 404/
      )
    end
  end

  describe ".read" do
    it "returns file contents when cached" do
      local = described_class.local_path("v1.34.4/deployment")
      FileUtils.mkdir_p(File.dirname(local))
      File.write(local, '{"type":"object"}')

      content = described_class.read("v1.34.4/deployment")
      expect(content).to eq('{"type":"object"}')
    end

    it "downloads and returns file contents when not cached" do
      response = instance_double(Net::HTTPSuccess, body: '{"type":"object","properties":{}}')
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(Net::HTTP).to receive(:get_response).and_return(response)

      content = described_class.read("v1.34.4/apps/deployment_v1")
      expect(content).to eq('{"type":"object","properties":{}}')
    end
  end
end
