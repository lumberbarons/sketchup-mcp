require_relative "test_helper"

# Unit tests for the pure helpers behind create_extrusion. The full method
# constructs Geom::Point3d / Geom::Vector3d and calls into SketchUp, but
# the axis-mapping and direction-sign logic — the parts most likely to harbor
# off-by-axis bugs — are isolated as plain functions returning [x, y, z]
# tuples so they can be locked down here.

class TestExtrusionHelpers < Minitest::Test
  def setup
    @server = TestServer.new
  end

  # -- build_profile_points -------------------------------------------------

  def test_x_axis_maps_profile_to_yz_plane
    # axis="x" → profile is [y, z], face sits at x=fixed
    profile = [[1, 2], [3, 4], [5, 6]]
    pts = @server.send(:build_profile_points, profile, "x", 9.0)
    assert_equal [[9.0, 1.0, 2.0], [9.0, 3.0, 4.0], [9.0, 5.0, 6.0]], pts
  end

  def test_y_axis_maps_profile_to_xz_plane
    profile = [[1, 2], [3, 4], [5, 6]]
    pts = @server.send(:build_profile_points, profile, "y", 9.0)
    assert_equal [[1.0, 9.0, 2.0], [3.0, 9.0, 4.0], [5.0, 9.0, 6.0]], pts
  end

  def test_z_axis_maps_profile_to_xy_plane
    profile = [[1, 2], [3, 4], [5, 6]]
    pts = @server.send(:build_profile_points, profile, "z", 9.0)
    assert_equal [[1.0, 2.0, 9.0], [3.0, 4.0, 9.0], [5.0, 6.0, 9.0]], pts
  end

  def test_profile_points_coerce_to_float
    # Integer profile coordinates must come out as floats — Geom::Point3d
    # gets fussy about types in some SketchUp versions.
    pts = @server.send(:build_profile_points, [[1, 2], [3, 4], [5, 6]], "z", 0)
    pts.flatten.each { |v| assert_kind_of Float, v }
  end

  def test_rafter_parallelogram_on_y_axis
    # Bead's canonical worked example: sloped 2x6 rafter side profile,
    # extruded along y. Verify the mapping is exactly what the bead promises:
    # each [a, b] becomes [a, fixed, b].
    profile = [
      [-12, 89.625], [59.25, 125.25], [59.25, 131.399], [-12, 95.774]
    ]
    pts = @server.send(:build_profile_points, profile, "y", 15.25)
    assert_equal [-12.0, 15.25, 89.625], pts[0]
    assert_equal [59.25, 15.25, 125.25], pts[1]
    assert_equal [59.25, 15.25, 131.399], pts[2]
    assert_equal [-12.0, 15.25, 95.774], pts[3]
  end

  # -- extrude_direction ----------------------------------------------------

  def test_extrude_direction_positive_x
    assert_equal [1.0, 0.0, 0.0], @server.send(:extrude_direction, "x", 0, 10)
  end

  def test_extrude_direction_negative_x
    assert_equal [-1.0, 0.0, 0.0], @server.send(:extrude_direction, "x", 10, 0)
  end

  def test_extrude_direction_positive_y
    assert_equal [0.0, 1.0, 0.0], @server.send(:extrude_direction, "y", 0, 5)
  end

  def test_extrude_direction_negative_y
    assert_equal [0.0, -1.0, 0.0], @server.send(:extrude_direction, "y", 5, 0)
  end

  def test_extrude_direction_positive_z
    assert_equal [0.0, 0.0, 1.0], @server.send(:extrude_direction, "z", 0, 96)
  end

  def test_extrude_direction_negative_z
    # Sloped-stud / top-down extrusion: from=top, to=bottom. The face's
    # normal will be flipped to -z so pushpull builds downward.
    assert_equal [0.0, 0.0, -1.0], @server.send(:extrude_direction, "z", 96, 0)
  end

  def test_extrude_direction_is_unit_for_any_magnitude
    # The magnitude of (to - from) shouldn't matter — direction is a unit
    # vector. A small delta and a huge delta must produce the same vector.
    a = @server.send(:extrude_direction, "y", 15.25, 16.75)
    b = @server.send(:extrude_direction, "y", 0, 1000)
    assert_equal a, b
  end

  # -- build_plane_basis ---------------------------------------------------

  def test_plane_basis_for_z_normal_is_xy
    # Normal along +z: profile lays in the xy plane. The basis must be
    # orthonormal and right-handed (u × v = n).
    u, v, n = @server.send(:build_plane_basis, [0, 0, 1])
    assert_equal [0.0, 0.0, 1.0], n
    assert_in_delta 1.0, dot(u, u), 1e-9
    assert_in_delta 1.0, dot(v, v), 1e-9
    assert_in_delta 0.0, dot(u, v), 1e-9
    assert_in_delta 0.0, dot(u, n), 1e-9
    assert_in_delta 0.0, dot(v, n), 1e-9
    assert_close [0.0, 0.0, 1.0], cross(u, v)
  end

  def test_plane_basis_normalizes_non_unit_normal
    # A normal of length 5 must come back as a unit vector — the bead's
    # contract is "normalize silently".
    _u, _v, n = @server.send(:build_plane_basis, [3.0, 4.0, 0.0])
    assert_in_delta 1.0, Math.sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]), 1e-9
    # 3-4-5 right triangle: unit form is (0.6, 0.8, 0)
    assert_in_delta 0.6, n[0], 1e-9
    assert_in_delta 0.8, n[1], 1e-9
    assert_in_delta 0.0, n[2], 1e-9
  end

  def test_plane_basis_rejects_zero_normal
    err = assert_raises(RuntimeError) { @server.send(:build_plane_basis, [0, 0, 0]) }
    assert_match(/non-zero/, err.message)
  end

  def test_plane_basis_orthonormal_for_sloped_normal
    # 6:12 roof pitch normal: tilted off vertical. Basis must still be
    # orthonormal and right-handed regardless of how the reference axis
    # was picked internally.
    u, v, n = @server.send(:build_plane_basis, [0.0, -0.4472, 0.8944])
    assert_in_delta 1.0, dot(u, u), 1e-6
    assert_in_delta 1.0, dot(v, v), 1e-6
    assert_in_delta 1.0, dot(n, n), 1e-6
    assert_in_delta 0.0, dot(u, v), 1e-6
    assert_in_delta 0.0, dot(u, n), 1e-6
    assert_in_delta 0.0, dot(v, n), 1e-6
    assert_close cross(u, v), n, 1e-6
  end

  # -- plane_profile_to_3d -------------------------------------------------

  def test_plane_profile_to_3d_xy_plane_at_origin
    # Identity-ish basis (u=+x, v=+y) at origin: profile coords come
    # straight through as (x, y, 0).
    pts = @server.send(:plane_profile_to_3d, [[1, 2], [3, 4]],
                      [0, 0, 0], [1, 0, 0], [0, 1, 0])
    assert_equal [[1.0, 2.0, 0.0], [3.0, 4.0, 0.0]], pts
  end

  def test_plane_profile_to_3d_offset_origin
    # Origin is the (a=0, b=0) anchor — translates the whole profile.
    pts = @server.send(:plane_profile_to_3d, [[0, 0], [1, 0], [1, 1]],
                      [10, 20, 30], [1, 0, 0], [0, 1, 0])
    assert_equal [[10.0, 20.0, 30.0], [11.0, 20.0, 30.0], [11.0, 21.0, 30.0]], pts
  end

  # -- point_in_polygon_2d? ------------------------------------------------

  SQUARE_10 = [[0, 0], [10, 0], [10, 10], [0, 10]].freeze

  def test_point_inside_square
    assert @server.send(:point_in_polygon_2d?, [5, 5], SQUARE_10)
  end

  def test_point_outside_square
    refute @server.send(:point_in_polygon_2d?, [15, 5], SQUARE_10)
    refute @server.send(:point_in_polygon_2d?, [-1, 5], SQUARE_10)
    refute @server.send(:point_in_polygon_2d?, [5, 20], SQUARE_10)
  end

  def test_point_in_polygon_concave_shape
    # L-shape — the "elbow" region between (5,5) and (10,10) is OUTSIDE
    # the L. A naive AABB check would say "inside"; ray casting must agree
    # with the actual polygon.
    l_shape = [[0, 0], [10, 0], [10, 5], [5, 5], [5, 10], [0, 10]]
    assert @server.send(:point_in_polygon_2d?, [2, 2], l_shape)
    assert @server.send(:point_in_polygon_2d?, [3, 8], l_shape)
    refute @server.send(:point_in_polygon_2d?, [7, 7], l_shape)
  end

  # -- validate_holes ------------------------------------------------------

  def test_validate_holes_passes_for_well_formed_holes
    holes = [
      [[1, 1], [2, 1], [2, 2], [1, 2]],
      [[5, 5], [6, 5], [6, 6], [5, 6]]
    ]
    @server.send(:validate_holes, SQUARE_10, holes)
  end

  def test_validate_holes_rejects_hole_outside_outer
    holes = [[[20, 20], [21, 20], [21, 21], [20, 21]]]
    err = assert_raises(RuntimeError) { @server.send(:validate_holes, SQUARE_10, holes) }
    assert_match(/hole #1/, err.message)
    assert_match(/outside the outer profile/, err.message)
  end

  def test_validate_holes_rejects_partially_outside_hole
    # First vertex inside, last vertex outside — must still raise.
    holes = [[[5, 5], [6, 5], [15, 6], [5, 6]]]
    err = assert_raises(RuntimeError) { @server.send(:validate_holes, SQUARE_10, holes) }
    assert_match(/outside the outer profile/, err.message)
  end

  def test_validate_holes_rejects_overlapping_pair
    holes = [
      [[1, 1], [4, 1], [4, 4], [1, 4]],
      [[3, 3], [6, 3], [6, 6], [3, 6]] # AABB overlaps the first
    ]
    err = assert_raises(RuntimeError) { @server.send(:validate_holes, SQUARE_10, holes) }
    assert_match(/holes #1 and #2 overlap/, err.message)
  end

  def test_validate_holes_accepts_empty_list
    # No holes is the existing baseline — explicitly cover it so the no-op
    # path doesn't regress as the implementation grows.
    @server.send(:validate_holes, SQUARE_10, [])
  end

  private

  def dot(a, b)
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
  end

  def cross(a, b)
    [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
  end

  def assert_close(expected, actual, eps = 1e-9)
    expected.zip(actual).each do |e, a|
      assert_in_delta e, a, eps
    end
  end
end
