require_relative "test_helper"

# Pure-helper tests for validate_geometry. The orchestration calls into
# Sketchup.active_model and walks entity bounds, which needs a live SketchUp;
# the per-kind math (bounds-axis deltas, contact gap, AABB overlap,
# alignment stats) is pure data + branching and is where bugs would hide.
# Fixtures are nested in a module so they don't collide with sibling tests.

module ValidateGeometryTestSupport
  VGPoint = Struct.new(:x, :y, :z)

  def self.pt(x, y, z); VGPoint.new(x.to_f, y.to_f, z.to_f); end
end

class TestValidateGeometryBoundsAxisErrors < Minitest::Test
  include ValidateGeometryTestSupport

  def setup
    @server = TestServer.new
  end

  def pt(*args); ValidateGeometryTestSupport.pt(*args); end

  def test_returns_empty_when_within_tolerance
    observed = pt(1.0, 2.0, 3.0)
    expected = [1.05, 2.0, 2.95]
    errs = @server.send(:bounds_axis_errors, observed, expected, "min", 0.1)
    assert_equal [], errs
  end

  def test_flags_each_axis_outside_tolerance
    observed = pt(1.0, 2.0, 3.0)
    expected = [0.0, 5.0, 3.0]
    errs = @server.send(:bounds_axis_errors, observed, expected, "min", 0.0625)
    assert_equal 2, errs.length
    assert_match(/min\.x/, errs[0])
    assert_match(/min\.y/, errs[1])
    # Detail must include the delta so the failure is actionable.
    assert_match(/Δ/, errs[0])
  end

  def test_label_passes_through_to_error
    observed = pt(0.0, 0.0, 0.0)
    expected = [1.0, 0.0, 0.0]
    errs = @server.send(:bounds_axis_errors, observed, expected, "max", 0.0625)
    assert_match(/max\.x/, errs.first)
  end

  def test_boundary_at_tolerance_passes
    # Δ exactly == tolerance is treated as a pass (the comparison is '>',
    # not '>='). Pin this — a tight joint right at the slop limit is fine.
    observed = pt(1.0625, 0.0, 0.0)
    expected = [1.0, 0.0, 0.0]
    errs = @server.send(:bounds_axis_errors, observed, expected, "min", 0.0625)
    assert_equal [], errs
  end

  def test_just_past_tolerance_fails
    observed = pt(1.0626, 0.0, 0.0)
    expected = [1.0, 0.0, 0.0]
    errs = @server.send(:bounds_axis_errors, observed, expected, "min", 0.0625)
    refute_empty errs
  end

  def test_raises_on_bad_expected_shape
    observed = pt(0.0, 0.0, 0.0)
    assert_raises(RuntimeError) do
      @server.send(:bounds_axis_errors, observed, [1.0, 2.0], "min", 0.0625)
    end
  end
end

class TestValidateGeometryContactGap < Minitest::Test
  include ValidateGeometryTestSupport

  def setup; @server = TestServer.new; end
  def pt(*args); ValidateGeometryTestSupport.pt(*args); end

  def test_plus_axis_touching_is_zero_gap
    # a.max.z == b.min.z → faces touch → gap == 0.
    a_min = pt(0, 0, 0); a_max = pt(10, 10, 5)
    b_min = pt(0, 0, 5); b_max = pt(10, 10, 10)
    gap = @server.send(:contact_face_gap, a_min, a_max, b_min, b_max, "z", "+")
    assert_in_delta 0.0, gap, 1e-9
  end

  def test_minus_axis_touching_is_zero_gap
    # a.min.z == b.max.z → faces touch from the other side.
    a_min = pt(0, 0, 5); a_max = pt(10, 10, 10)
    b_min = pt(0, 0, 0); b_max = pt(10, 10, 5)
    gap = @server.send(:contact_face_gap, a_min, a_max, b_min, b_max, "z", "-")
    assert_in_delta 0.0, gap, 1e-9
  end

  def test_separated_returns_positive_gap
    a_min = pt(0, 0, 0); a_max = pt(10, 10, 5)
    b_min = pt(0, 0, 8); b_max = pt(10, 10, 12)
    gap = @server.send(:contact_face_gap, a_min, a_max, b_min, b_max, "z", "+")
    assert_in_delta 3.0, gap, 1e-9
  end

  def test_overlap_also_returns_absolute_value
    # If a's +z face is above b's -z face (a penetrates b), still report the
    # magnitude — the caller cares about |gap| against tolerance, not the sign.
    a_min = pt(0, 0, 0); a_max = pt(10, 10, 7)
    b_min = pt(0, 0, 5); b_max = pt(10, 10, 10)
    gap = @server.send(:contact_face_gap, a_min, a_max, b_min, b_max, "z", "+")
    assert_in_delta 2.0, gap, 1e-9
  end

  def test_x_axis_plus_direction
    a_min = pt(0, 0, 0); a_max = pt(5, 10, 10)
    b_min = pt(5, 0, 0); b_max = pt(10, 10, 10)
    gap = @server.send(:contact_face_gap, a_min, a_max, b_min, b_max, "x", "+")
    assert_in_delta 0.0, gap, 1e-9
  end
end

class TestValidateGeometryAlignmentStats < Minitest::Test
  def setup; @server = TestServer.new; end

  def test_empty_returns_zeros
    spread, mean = @server.send(:alignment_stats, [])
    assert_in_delta 0.0, spread, 1e-9
    assert_in_delta 0.0, mean, 1e-9
  end

  def test_single_value_has_no_spread
    spread, mean = @server.send(:alignment_stats, [3.5])
    assert_in_delta 0.0, spread, 1e-9
    assert_in_delta 3.5, mean, 1e-9
  end

  def test_spread_and_mean
    spread, mean = @server.send(:alignment_stats, [1.0, 2.0, 3.0, 4.0])
    assert_in_delta 3.0, spread, 1e-9
    assert_in_delta 2.5, mean, 1e-9
  end

  def test_mean_ignores_order
    a, _ = @server.send(:alignment_stats, [4.0, 1.0, 3.0, 2.0])
    assert_in_delta 3.0, a, 1e-9
  end
end

class TestValidateGeometryAABBOverlap < Minitest::Test
  include ValidateGeometryTestSupport

  def setup; @server = TestServer.new; end
  def pt(*args); ValidateGeometryTestSupport.pt(*args); end

  def test_disjoint_returns_negative_on_separated_axis
    a_min = pt(0, 0, 0);   a_max = pt(10, 10, 10)
    b_min = pt(20, 0, 0);  b_max = pt(30, 10, 10)
    ox, oy, oz = @server.send(:aabb_overlap_extents, a_min, a_max, b_min, b_max)
    assert ox < 0, "expected negative x-overlap, got #{ox}"
    assert oy > 0
    assert oz > 0
  end

  def test_touching_returns_zero_on_shared_face
    # Two cubes sharing the x=10 face. Penetration on x is exactly 0;
    # y and z still overlap fully.
    a_min = pt(0, 0, 0);   a_max = pt(10, 10, 10)
    b_min = pt(10, 0, 0);  b_max = pt(20, 10, 10)
    ox, oy, oz = @server.send(:aabb_overlap_extents, a_min, a_max, b_min, b_max)
    assert_in_delta 0.0, ox, 1e-9
    assert oy > 0
    assert oz > 0
  end

  def test_full_overlap_returns_positive_on_all_axes
    a_min = pt(0, 0, 0); a_max = pt(10, 10, 10)
    b_min = pt(5, 5, 5); b_max = pt(15, 15, 15)
    ox, oy, oz = @server.send(:aabb_overlap_extents, a_min, a_max, b_min, b_max)
    assert_in_delta 5.0, ox, 1e-9
    assert_in_delta 5.0, oy, 1e-9
    assert_in_delta 5.0, oz, 1e-9
  end

  def test_contained_box_returns_full_size
    a_min = pt(0, 0, 0); a_max = pt(100, 100, 100)
    b_min = pt(10, 20, 30); b_max = pt(40, 50, 60)
    ox, oy, oz = @server.send(:aabb_overlap_extents, a_min, a_max, b_min, b_max)
    assert_in_delta 30.0, ox, 1e-9
    assert_in_delta 30.0, oy, 1e-9
    assert_in_delta 30.0, oz, 1e-9
  end
end

class TestValidateGeometryFormatters < Minitest::Test
  def setup; @server = TestServer.new; end

  def test_format_num_strips_trailing_zeros
    assert_equal "0.0625", @server.send(:format_num, 0.0625)
    assert_equal "1", @server.send(:format_num, 1.0)
  end

  def test_format_tol_includes_inch_glyph
    assert_equal "0.0625\"", @server.send(:format_tol, 0.0625)
  end
end
