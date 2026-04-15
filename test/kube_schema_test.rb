# frozen_string_literal: true

require "test_helper"

class KubeSchemaTest < Minitest::Test
  def test_version
    refute_nil KubeSchema::VERSION
  end

  def test_lookup_returns_class
    klass = KubeSchema["Deployment"]

    assert_equal Class, klass.class
    assert_operator klass, :<, KubeSchema::Resource
  end

  def test_versioned_lookup_returns_class
    klass = KubeSchema["1.33.6"]["Deployment"]

    assert_equal Class, klass.class
    assert_operator klass, :<, KubeSchema::Resource
  end

  def test_new_returns_resource_instance
    instance = KubeSchema["Deployment"].new

    assert_kind_of KubeSchema::Resource, instance
  end

  def test_schema_accessible_on_class
    klass = KubeSchema["Deployment"]

    assert_instance_of Hash, klass.schema
    assert_includes klass.schema.keys, "description"
  end

  def test_schema_accessible_on_instance
    instance = KubeSchema["Deployment"].new

    assert_instance_of Hash, instance.schema
    assert_includes instance.schema.keys, "description"
  end

  def test_new_with_block
    instance = KubeSchema["Deployment"].new do
      self.type = "custom"
    end

    assert_equal "custom", instance.type
  end

  def test_method_missing_delegates_to_data
    instance = KubeSchema["Deployment"].new

    assert_equal "object", instance.type
    assert_instance_of Hash, instance.properties
  end

  def test_parse_roundtrip
    instance = KubeSchema["Deployment"].new
    parsed   = KubeSchema.parse(instance.to_h)

    assert_equal instance, parsed
  end

  def test_parse_roundtrip_with_versioned_lookup
    instance = KubeSchema["1.33.6"]["Deployment"].new
    parsed   = KubeSchema.parse(instance.to_h)

    assert_equal instance, parsed
  end

  def test_parse_returns_resource
    instance = KubeSchema["Deployment"].new
    parsed   = KubeSchema.parse(instance.to_h)

    assert_instance_of KubeSchema::Resource, parsed
  end

  def test_full_gvk_lookup
    klass = KubeSchema["flowcontrol.apiserver.k8s.io/v1/WatchEvent"]

    assert_equal Class, klass.class
    assert_operator klass, :<, KubeSchema::Resource
  end

  def test_cached_class_identity
    a = KubeSchema["Deployment"]
    b = KubeSchema["Deployment"]

    assert_same a, b
  end

  def test_cached_instance_identity
    a = KubeSchema["1.33.6"]
    b = KubeSchema["v1.33.6"]

    assert_same a, b
  end
end
