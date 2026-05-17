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

  def test_rejects_zero_vector
    err = assert_raises(RuntimeError) do
      @server.send(:pattern_linear, { "id" => 1, "vector" => [0, 0, 0], "count" => 3 })
    end
    assert_match(/vector/, err.message)
    assert_match(/non-zero/, err.message)
  end

  def test_rejects_non_string_name_template
    err = assert_raises(RuntimeError) do
      @server.send(:pattern_linear, {
                     "id" => 1,
                     "vector" => [1, 0, 0],
                     "count" => 1,
                     "name_template" => 42
                   })
    end
    assert_match(/name_template/, err.message)
  end
end

class TestPatternLinearNamingSeed < Minitest::Test
  def setup
    @server = TestServer.new
  end

  def test_strips_trailing_integer_and_continues
    base, n = @server.send(:pattern_linear_naming_seed, "Floor Joist 1")
    assert_equal "Floor Joist", base
    assert_equal 2, n
  end

  def test_strips_trailing_integer_without_space
    base, n = @server.send(:pattern_linear_naming_seed, "Joist7")
    assert_equal "Joist", base
    assert_equal 8, n
  end

  def test_falls_back_to_full_name_starting_at_2
    base, n = @server.send(:pattern_linear_naming_seed, "Rafter")
    assert_equal "Rafter", base
    assert_equal 2, n
  end

  def test_handles_pure_integer_name
    base, n = @server.send(:pattern_linear_naming_seed, "42")
    assert_equal "", base
    assert_equal 43, n
  end
end

class TestPatternLinearCopyName < Minitest::Test
  def setup
    @server = TestServer.new
  end

  def test_default_continues_from_seed
    name, next_n = @server.send(:pattern_linear_copy_name,
                                template: nil, src: "Joist 1", base: "Joist",
                                i: 1, start_n: 2, taken: ["Joist 1"])
    assert_equal "Joist 2", name
    assert_equal 3, next_n
  end

  def test_default_skips_taken_names
    name, next_n = @server.send(:pattern_linear_copy_name,
                                template: nil, src: "Joist 1", base: "Joist",
                                i: 1, start_n: 2, taken: ["Joist 1", "Joist 2", "Joist 3"])
    assert_equal "Joist 4", name
    assert_equal 5, next_n
  end

  def test_template_substitutes_placeholders
    name, next_n = @server.send(:pattern_linear_copy_name,
                                template: "{base}-{i}-{n}-{src}",
                                src: "Joist 1", base: "Joist",
                                i: 3, start_n: 7, taken: [])
    assert_equal "Joist-3-7-Joist 1", name
    assert_equal 8, next_n
  end

  def test_template_does_not_skip_collisions
    # When the caller supplies a template, they're taking control of naming;
    # we substitute and trust them rather than auto-incrementing.
    name, _ = @server.send(:pattern_linear_copy_name,
                           template: "{src}",
                           src: "Joist", base: "Joist",
                           i: 1, start_n: 2, taken: ["Joist"])
    assert_equal "Joist", name
  end

  def test_empty_base_yields_bare_integer
    name, _ = @server.send(:pattern_linear_copy_name,
                           template: nil, src: "42", base: "",
                           i: 1, start_n: 43, taken: [])
    assert_equal "43", name
  end
end
