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

class TestValidateGeometryOBBOverlap < Minitest::Test
  def setup; @server = TestServer.new; end

  # When both boxes are axis-aligned at the origin, OBB SAT reduces to AABB
  # penetration along a single axis — sanity-check the trivial case.
  def test_axis_aligned_full_overlap_returns_min_extent
    a_center = [0.0, 0.0, 0.0]
    a_axes = [[5.0, 0, 0], [0, 5.0, 0], [0, 0, 5.0]]
    b_center = [4.0, 0.0, 0.0]
    b_axes = [[5.0, 0, 0], [0, 5.0, 0], [0, 0, 5.0]]
    d = @server.send(:obb_overlap_depth, a_center, a_axes, b_center, b_axes)
    # Boxes span [-5,5] and [-1,9] on X — overlap on X is 6, full overlap on Y/Z.
    assert_in_delta 6.0, d, 1e-9
  end

  def test_axis_aligned_separated_returns_negative
    a_center = [0.0, 0.0, 0.0]
    a_axes = [[1.0, 0, 0], [0, 1.0, 0], [0, 0, 1.0]]
    b_center = [10.0, 0.0, 0.0]
    b_axes = [[1.0, 0, 0], [0, 1.0, 0], [0, 0, 1.0]]
    d = @server.send(:obb_overlap_depth, a_center, a_axes, b_center, b_axes)
    assert d < 0, "expected separated, got depth #{d}"
  end

  def test_axis_aligned_touching_returns_zero
    a_center = [0.0, 0.0, 0.0]
    a_axes = [[1.0, 0, 0], [0, 1.0, 0], [0, 0, 1.0]]
    b_center = [2.0, 0.0, 0.0]
    b_axes = [[1.0, 0, 0], [0, 1.0, 0], [0, 0, 1.0]]
    d = @server.send(:obb_overlap_depth, a_center, a_axes, b_center, b_axes)
    assert_in_delta 0.0, d, 1e-9
  end

  # Regression for the issue: a rotated box can have an AABB that overlaps
  # an axis-aligned neighbor's AABB while the actual oriented boxes are
  # cleanly separated. AABB mode would report overlap; OBB mode must not.
  def test_rotated_box_separated_when_aabbs_overlap
    # A: unit cube at origin (axis-aligned). Occupies [-1, 1]^3.
    a_center = [0.0, 0.0, 0.0]
    a_axes = [[1.0, 0, 0], [0, 1.0, 0], [0, 0, 1.0]]
    # B: 1×1×1 cube (half-extent 0.5) rotated 45° about Z, centered at
    # (1.5, 1.5, 0). Its AABB on X and Y is [1.5 - √2/2, 1.5 + √2/2] ≈
    # [0.793, 2.207], which overlaps A's [-1, 1] on both axes by ~0.207.
    # But B's diamond's nearest point to A's corner (1,1) is ≈ (1.146,
    # 1.146) — outside A. So the OBBs are separated even though the AABBs
    # are not.
    s = Math.sqrt(2) / 2.0
    half = 0.5
    b_center = [1.5, 1.5, 0.0]
    b_axes = [[half * s, half * s, 0], [-half * s, half * s, 0], [0, 0, half]]

    # Sanity: AABBs do overlap on every axis (the AABB check would flag).
    aabb_half_x = (b_axes[0][0]).abs + (b_axes[1][0]).abs + (b_axes[2][0]).abs
    aabb_x_min_b = b_center[0] - aabb_half_x
    assert aabb_x_min_b < 1.0,
           "test setup broken: B's AABB does not overlap A on X (#{aabb_x_min_b})"

    d = @server.send(:obb_overlap_depth, a_center, a_axes, b_center, b_axes)
    assert d < 0, "expected OBB-separated despite AABB overlap, got depth #{d}"
  end

  # Cross-product axes from near-parallel boxes degenerate to zero; the
  # helper should skip them rather than divide-by-zero.
  def test_parallel_boxes_skip_degenerate_cross_axes
    a_center = [0.0, 0.0, 0.0]
    a_axes = [[2.0, 0, 0], [0, 1.0, 0], [0, 0, 1.0]]
    b_center = [10.0, 0.0, 0.0]
    b_axes = [[2.0, 0, 0], [0, 1.0, 0], [0, 0, 1.0]]
    # Parallel — every a_i × b_j is zero. Must return a finite negative
    # value from a box axis, not NaN.
    d = @server.send(:obb_overlap_depth, a_center, a_axes, b_center, b_axes)
    assert d.finite?, "expected finite depth, got #{d}"
    assert d < 0
  end
end

class TestValidateGeometryAABBToOBB < Minitest::Test
  include ValidateGeometryTestSupport

  def setup; @server = TestServer.new; end
  def pt(*args); ValidateGeometryTestSupport.pt(*args); end

  def test_aabb_to_obb_returns_axis_aligned_box
    min = pt(-1.0, -2.0, -3.0)
    max = pt(1.0, 2.0, 3.0)
    obb = @server.send(:aabb_to_obb, min, max)
    assert_equal [0.0, 0.0, 0.0], obb[:center]
    assert_equal [[1.0, 0.0, 0.0], [0.0, 2.0, 0.0], [0.0, 0.0, 3.0]], obb[:axes]
  end

  def test_aabb_to_obb_handles_nonzero_center
    min = pt(10.0, 20.0, 30.0)
    max = pt(14.0, 22.0, 36.0)
    obb = @server.send(:aabb_to_obb, min, max)
    assert_equal [12.0, 21.0, 33.0], obb[:center]
    assert_equal [[2.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 3.0]], obb[:axes]
  end
end

# Tests for compute_obb_from_local_aabb — pins the transformation-driven
# OBB composition that group_obb depends on for sloped framing. Uses
# synthetic 16-elem column-major 4×4 matrices to stand in for
# Geom::Transformation#to_a, so no live SketchUp is needed.
class TestValidateGeometryComputeOBBFromMatrix < Minitest::Test
  def setup; @server = TestServer.new; end

  IDENTITY = [
    1.0, 0.0, 0.0, 0.0,
    0.0, 1.0, 0.0, 0.0,
    0.0, 0.0, 1.0, 0.0,
    0.0, 0.0, 0.0, 1.0
  ].freeze

  def call(local_min, local_max, m)
    @server.send(:compute_obb_from_local_aabb, local_min, local_max, m)
  end

  def test_identity_matrix_returns_aabb_unchanged
    obb = call([-1.0, -2.0, -3.0], [1.0, 2.0, 3.0], IDENTITY)
    assert_equal [0.0, 0.0, 0.0], obb[:center]
    assert_equal [[1.0, 0.0, 0.0], [0.0, 2.0, 0.0], [0.0, 0.0, 3.0]], obb[:axes]
  end

  def test_translation_only_shifts_center_not_axes
    # Translation column [10, 20, 30] in the 13/14/15 slots.
    m = IDENTITY.dup
    m[12], m[13], m[14] = 10.0, 20.0, 30.0
    obb = call([-1.0, -1.0, -1.0], [1.0, 1.0, 1.0], m)
    assert_equal [10.0, 20.0, 30.0], obb[:center]
    assert_equal [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]], obb[:axes]
  end

  # Regression: a piece modeled as a 1.5×72×5.5 box on the X axis and
  # rotated 45° about Z (an in-between slope for clarity) must surface
  # with rotated half-extent vectors. This is exactly the case OBB mode
  # is meant to handle — a sloped rafter modeled in local frame.
  def test_z_rotation_45_rotates_axes_into_world_frame
    s = Math.sqrt(2) / 2.0
    # Column-major: first column = rotated X axis (s, s, 0); second column
    # = rotated Y axis (-s, s, 0); third column = Z axis (0, 0, 1).
    m = [
      s, s, 0.0, 0.0,
      -s, s, 0.0, 0.0,
      0.0, 0.0, 1.0, 0.0,
      0.0, 0.0, 0.0, 1.0
    ]
    # Local AABB: 2×2×2 box at origin.
    obb = call([-1.0, -1.0, -1.0], [1.0, 1.0, 1.0], m)
    assert_in_delta 0.0, obb[:center][0], 1e-12
    assert_in_delta 0.0, obb[:center][1], 1e-12
    assert_in_delta 0.0, obb[:center][2], 1e-12
    # Half-extent along local X (length 1) becomes (s, s, 0) in world.
    assert_in_delta s, obb[:axes][0][0], 1e-12
    assert_in_delta s, obb[:axes][0][1], 1e-12
    assert_in_delta 0.0, obb[:axes][0][2], 1e-12
    # Local Y becomes (-s, s, 0).
    assert_in_delta -s, obb[:axes][1][0], 1e-12
    assert_in_delta s, obb[:axes][1][1], 1e-12
    # Local Z is unchanged.
    assert_equal [0.0, 0.0, 1.0], obb[:axes][2]
  end

  # Combining rotation + translation: a 2×2×2 box rotated 45° about Z and
  # placed at (5, 0, 0). World OBB must have the rotated axes and the
  # translated center.
  def test_rotation_plus_translation_composes_correctly
    s = Math.sqrt(2) / 2.0
    m = [
      s, s, 0.0, 0.0,
      -s, s, 0.0, 0.0,
      0.0, 0.0, 1.0, 0.0,
      5.0, 0.0, 0.0, 1.0
    ]
    obb = call([-1.0, -1.0, -1.0], [1.0, 1.0, 1.0], m)
    assert_in_delta 5.0, obb[:center][0], 1e-12
    assert_in_delta 0.0, obb[:center][1], 1e-12
    assert_in_delta s, obb[:axes][0][0], 1e-12
    assert_in_delta s, obb[:axes][0][1], 1e-12
  end

  # Scale baked into the basis columns: a uniform 2× scale doubles the
  # half-extent vector magnitudes, since each axis is one matrix column
  # scaled by the local half-extent.
  def test_uniform_scale_in_basis_doubles_axis_lengths
    m = [
      2.0, 0.0, 0.0, 0.0,
      0.0, 2.0, 0.0, 0.0,
      0.0, 0.0, 2.0, 0.0,
      0.0, 0.0, 0.0, 1.0
    ]
    obb = call([-1.0, -1.0, -1.0], [1.0, 1.0, 1.0], m)
    assert_equal [[2.0, 0.0, 0.0], [0.0, 2.0, 0.0], [0.0, 0.0, 2.0]], obb[:axes]
  end

  # Non-symmetric local AABB (e.g. a rafter modeled 1.5×72×5.5 on local X):
  # rotating the long X axis into a slope must produce a long world-space
  # X half-extent vector pointing along the slope.
  def test_non_unit_local_extents_scale_each_basis_column
    s = Math.sqrt(2) / 2.0
    m = [
      s, s, 0.0, 0.0,
      -s, s, 0.0, 0.0,
      0.0, 0.0, 1.0, 0.0,
      0.0, 0.0, 0.0, 1.0
    ]
    # Rafter-shaped local AABB: long along X, short on Y/Z.
    obb = call([-36.0, -0.75, -2.75], [36.0, 0.75, 2.75], m)
    # Half-extent vector along local X (length 36) rotated into world:
    # 36 × (s, s, 0) = (36s, 36s, 0).
    assert_in_delta 36.0 * s, obb[:axes][0][0], 1e-9
    assert_in_delta 36.0 * s, obb[:axes][0][1], 1e-9
    # Z half-extent unchanged at 2.75.
    assert_equal [0.0, 0.0, 2.75], obb[:axes][2]
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
