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
end
