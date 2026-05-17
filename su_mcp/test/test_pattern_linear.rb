require_relative "test_helper"

# Argument validation in pattern_linear runs before resolve_entity, so an
# invalid vector/count raises without ever touching the model. These tests
# pin that ordering — the Ruby handler must not crash on a nil
# Sketchup.active_model when the inputs are malformed.
class TestPatternLinearValidation < Minitest::Test
  def setup
    @server = TestServer.new
  end

  def test_rejects_missing_vector
    err = assert_raises(RuntimeError) do
      @server.send(:pattern_linear, { "id" => 1, "count" => 3 })
    end
    assert_match(/vector/, err.message)
  end

  def test_rejects_wrong_length_vector
    err = assert_raises(RuntimeError) do
      @server.send(:pattern_linear, { "id" => 1, "vector" => [1, 2], "count" => 3 })
    end
    assert_match(/vector/, err.message)
  end

  def test_rejects_zero_count
    err = assert_raises(RuntimeError) do
      @server.send(:pattern_linear, { "id" => 1, "vector" => [1, 0, 0], "count" => 0 })
    end
    assert_match(/count/, err.message)
  end

  def test_rejects_non_integer_count
    err = assert_raises(RuntimeError) do
      @server.send(:pattern_linear, { "id" => 1, "vector" => [1, 0, 0], "count" => 2.5 })
    end
    assert_match(/count/, err.message)
  end
end
