# frozen_string_literal: true

require "test_helper"

class KubeSchemaTest < Minitest::Test
  def test_version
    refute_nil KubeSchema::VERSION
  end
end
