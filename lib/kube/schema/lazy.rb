# frozen_string_literal: true

require "json"
require "json_schemer"
require "tempfile"
require "weakref"

module Kube
  module Schema
    module Lazy
      REF_SCHEME = "kube"
      REF_PREFIX = "#/definitions/"
      INT_OR_STRING = "io.k8s.apimachinery.pkg.util.intstr.IntOrString"

      module Scanner
        module_function

        def string_end(data, start)
          i = start + 1

          while (i = data.index('"', i))
            backslashes = 0
            j = i - 1

            while data[j] == "\\"
              backslashes += 1
              j -= 1
            end

            if backslashes.even?
              break i
            end

            i += 1
          end || raise("unterminated string at #{start}")
        end

        def object_end(data, start)
          depth = 0
          i = start

          while (i = data.index(/["{}]/, i))
            case data[i]
            when '"'
              i = string_end(data, i) + 1
            when "{"
              depth += 1
              i += 1
            when "}"
              depth -= 1
              i += 1

              if depth.zero?
                break i
              end
            end
          end || raise("unterminated object at #{start}")
        end

        def scan(path)
          data = File.binread(path)
          anchor = data.index('"definitions"')
          pos = data.index("{", anchor ? anchor + 13 : 0) + 1
          entries = {}

          while (pos = data.index(/[^\s,]/, pos))
            if data[pos] == "}"
              break
            end

            unless data[pos] == '"'
              raise "expected a definition key at #{pos} of #{path}"
            end

            key_end = string_end(data, pos)
            key = data[(pos + 1)...key_end]
            pos = data.index(/[^\s:]/, key_end + 1)
            value_start = pos
            pos = object_end(data, pos)

            entries[key] = [path, value_start, pos - value_start]
          end

          entries
        end
      end

      Entry = Struct.new(
        :path,
        :offset,
        :length,
        :gvks,
        :properties,
        :spilled,
      )

      module Spill
        module_function

        def files = @files ||= {}

        def write(key, hash)
          json = JSON.generate(hash)
          file = Tempfile.new(["kube-schema-", ".json"])
          file.binmode
          file.write(json)
          file.flush
          files[key] = file

          Entry.new(
            file.path,
            0,
            json.bytesize,
            hash["x-kubernetes-group-version-kind"],
            hash.fetch("properties", {}).keys,
            true,
          )
        end

        def clear
          files.each_value(&:close!)
          files.clear
        end
      end

      class Index
        def self.build(paths)
          entries = {}

          paths.each do |path|
            Scanner.scan(path).each do |key, (file, offset, length)|
              definition = JSON.parse(File.binread(file, length, offset))

              entries[key] = Entry.new(
                file,
                offset,
                length,
                definition["x-kubernetes-group-version-kind"],
                definition.fetch("properties", {}).keys,
              )
            end
          end

          new(entries)
        end

        def initialize(entries)
          @entries = entries
        end

        attr_reader :entries

        def keys = @entries.keys
        def key?(key) = @entries.key?(key)
        def [](key) = @entries[key]
        def size = @entries.size
      end

      class Source
        def self.indexed(index, key)
          new(index, index[key] || raise("No definition #{key.inspect} in the index!"), key)
        end

        def self.spilled(index, entry) = new(index, entry)

        def initialize(index, entry, key = nil)
          @index = index
          @entry = entry
          @key = key
        end

        attr_reader :key, :entry

        def value = Lazy.load(@entry, @key)

        def valid?(data) = schema.valid?(data)
        def validate(data) = schema.validate(data)
        def ref(pointer) = schema.ref(pointer)

        def schema
          if @compiled&.weakref_alive?
            live = @compiled.__getobj__
          else
            live = nil
          end

          live || begin
            compiled = JSONSchemer.schema(Lazy.rewrite(value), ref_resolver: Lazy.resolver(@index))
            @compiled = WeakRef.new(compiled)
            compiled
          end
        end
      end

      module_function

      def patch(key, definition)
        if key == INT_OR_STRING
          definition["type"] = ["string", "integer"]
        end

        definition
      end

      def rewrite(node)
        case node
        when Hash
          node.each_with_object({}) do |(key, value), out|
            if key == "$ref" && value.is_a?(String) && value.start_with?(REF_PREFIX)
              out[key] = "#{REF_SCHEME}:///#{value.delete_prefix(REF_PREFIX)}"
            else
              out[key] = rewrite(value)
            end
          end
        when Array
          node.map { |item| rewrite(item) }
        else
          node
        end
      end

      def load(entry, key = nil)
        patch(key, JSON.parse(File.binread(entry.path, entry.length, entry.offset)))
      rescue Errno::ENOENT
        raise MissingSchemaError, missing_message(entry, key)
      end

      def missing_message(entry, key)
        if key
          named = "Schema #{key.inspect}"
        else
          named = "Schema"
        end

        if entry.spilled
          "#{named} is missing: the temp file it was spilled to (#{entry.path}) is gone." \
            "\nSomething garbage collected or swept it -- Tempfile unlinks on GC, and tmpdirs get cleaned." \
            "\nRe-register the schema with Kube::Schema.register."
        else
          "#{named} is missing: #{entry.path} could not be read."
        end
      end

      def raw(index, key)
        entry = index[key] or raise "No definition #{key.inspect} in the index!"

        load(entry, key)
      end

      def definition(index, key)
        rewrite(raw(index, key))
      end

      def resolver(index)
        ->(uri) { definition(index, uri.path.delete_prefix("/")) }
      end

      def schema_for(index, key)
        JSONSchemer.schema(definition(index, key), ref_resolver: resolver(index))
      end

      def schema_from(hash, index)
        JSONSchemer.schema(rewrite(hash), ref_resolver: resolver(index))
      end
    end
  end
end

__END__

require "kube/schema"

schemas = File.expand_path("../../../schemas", __dir__)
paths = [File.join(schemas, "v1.33.json")] + Dir.glob(File.join(schemas, "*-definitions.json")).sort
index = Kube::Schema::Lazy::Index.build(paths)

deployment = lambda {
  {
    "apiVersion" => "apps/v1",
    "kind" => "Deployment",
    "metadata" => {"name" => "web"},
    "spec" => {
      "selector" => {"matchLabels" => {"app" => "web"}},
      "template" => {"spec" => {"containers" => [{"name" => "web", "image" => "nginx"}]}}
    }
  }
}

describe "Kube::Schema::Lazy::Scanner" do
  it "slices every definition byte-identically to a full parse" do
    paths.each do |path|
      parsed = JSON.parse(File.read(path))
      truth = parsed.fetch("definitions", parsed)
      scanned = Kube::Schema::Lazy::Scanner.scan(path)

      scanned.keys.sort.should == truth.keys.sort

      scanned.each do |key, (file, offset, length)|
        JSON.parse(File.binread(file, length, offset)).should == truth[key]
      end
    end
  end
end

describe "Kube::Schema::Lazy::Index" do
  it "indexes every definition across the version and extra files" do
    index.size.should.be > 1_000
    index["io.k8s.api.apps.v1.Deployment"].gvks.first["kind"].should == "Deployment"
    index["io.k8s.api.apps.v1.Deployment"].properties.should.include "spec"
    index["io.k8s.api.apps.v1.Deployment"].properties.should.include "metadata"
  end
end

describe "Kube::Schema::Lazy::Source" do
  source = Kube::Schema::Lazy::Source.indexed(index, "io.k8s.api.apps.v1.Deployment")

  it "exposes properties without compiling a schema" do
    source.value["properties"].keys.should.include "spec"
  end

  it "validates through a compiled schema" do
    source.valid?(deployment.()).should.be.true
  end

  it "reports errors that are only reachable through refs" do
    manifest = deployment.()
    manifest["spec"]["template"]["spec"]["containers"] = [{"image" => "nginx"}]

    source.validate(manifest).to_a.size.should == 1
  end
end

describe "Kube::Schema::Lazy.load" do
  it "raises MissingSchemaError when a spilled temp file has vanished" do
    entry = Kube::Schema::Lazy::Spill.write("v1/Thing", {"properties" => {"spec" => {}}})
    File.unlink(entry.path)

    error = lambda { Kube::Schema::Lazy.load(entry, "v1/Thing") }.should.raise(Kube::MissingSchemaError)
    error.message.should.match(/temp file/)
  end

  it "raises MissingSchemaError when a shipped schema file cannot be read" do
    entry = Kube::Schema::Lazy::Entry.new("/nonexistent/schema.json", 0, 10, nil, [])

    error = lambda { Kube::Schema::Lazy.load(entry, "io.k8s.Thing") }.should.raise(Kube::MissingSchemaError)
    error.message.should.match(/could not be read/)
  end

  it "surfaces the error through Source#valid?" do
    entry = Kube::Schema::Lazy::Spill.write("v1/Gone", {"properties" => {}})
    spilled = Kube::Schema::Lazy::Source.spilled(index, entry)
    File.unlink(entry.path)

    lambda { spilled.valid?({}) }.should.raise(Kube::MissingSchemaError)
  end
end

describe "Kube::Schema::Lazy.patch" do
  it "widens IntOrString to accept integers and strings" do
    Kube::Schema::Lazy.raw(index, Kube::Schema::Lazy::INT_OR_STRING)["type"].should == ["string", "integer"]
  end
end

describe "Kube::Schema::Lazy.schema_for" do
  it "compiles only the subschemas the instance touches" do
    Kube::Schema::Lazy.schema_for(index, "io.k8s.api.apps.v1.Deployment").valid?(deployment.())

    ObjectSpace.each_object(JSONSchemer::Schema).count.should.be < 2_000
  end
end
