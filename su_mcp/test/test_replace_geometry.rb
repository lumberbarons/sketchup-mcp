require_relative "test_helper"

# Unit tests for replace_geometry's pure helpers. The full method runs
# inside SketchUp (resolve_entity, erase!, create_*), but the geometry-
# dict validation is shape-only and worth pinning here so a typo can't
# silently turn into an unhelpful runtime error against a live model.

class TestReplaceGeometry < Minitest::Test
  def setup
    @server = TestServer.new
  end

  # -- validate_replace_geometry_dict --------------------------------------

  def test_validate_accepts_every_known_op
    %w[cube cylinder sphere cone extrusion].each do |op_name|
      @server.send(:validate_replace_geometry_dict, { "op" => op_name })
    end
  end

  def test_validate_rejects_nil_geometry
    err = assert_raises(RuntimeError) { @server.send(:validate_replace_geometry_dict, nil) }
    assert_match(/required/, err.message)
  end

  def test_validate_rejects_non_hash_geometry
    err = assert_raises(RuntimeError) do
      @server.send(:validate_replace_geometry_dict, [1, 2, 3])
    end
    assert_match(/must be a Hash/, err.message)
  end

  def test_validate_rejects_unknown_op
    # A typo'd op name must come back with the bad value in the message so
    # the caller can fix the input without inspecting the server log.
    err = assert_raises(RuntimeError) do
      @server.send(:validate_replace_geometry_dict, { "op" => "morph" })
    end
    assert_match(/morph/, err.message)
    assert_match(/cube/, err.message)
  end

  def test_validate_rejects_missing_op
    # `op` is required — a dict with the right shape but no op fails the
    # known-op check (op.to_s = "" which isn't in the allowlist).
    err = assert_raises(RuntimeError) do
      @server.send(:validate_replace_geometry_dict, { "position" => [0, 0, 0] })
    end
    assert_match(/must be one of/, err.message)
  end

  # -- batch_create accepts the new "replace" op ---------------------------

  def test_batch_validate_accepts_replace_op
    # The replace op routes through batch_create's validator first — make
    # sure it's in the allowlist (regression guard for KNOWN_BATCH_OPS).
    @server.send(:validate_batch_op, { "op" => "replace" }, 0)
  end
end
