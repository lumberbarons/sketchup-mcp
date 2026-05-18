require_relative "test_helper"

# Pure tests for mirror_component's helpers. The validation/plane-resolution/
# matrix-building helpers don't touch SketchUp.* so they're testable without
# stubbing the live API.

class TestResolveMirrorPlane < Minitest::Test
  def setup
    @server = TestServer.new
  end

  def test_axis_x_yields_x_normal
    origin, normal = @server.send(:resolve_mirror_plane, { "axis" => "x", "offset" => 60.5 })
    assert_equal [60.5, 0.0, 0.0], origin
    assert_equal [1.0, 0.0, 0.0], normal
  end

  def test_axis_y_yields_y_normal
    origin, normal = @server.send(:resolve_mirror_plane, { "axis" => "y", "offset" => 12 })
    assert_equal [0.0, 12.0, 0.0], origin
    assert_equal [0.0, 1.0, 0.0], normal
  end

  def test_axis_z_yields_z_normal
    origin, normal = @server.send(:resolve_mirror_plane, { "axis" => "z", "offset" => -3.25 })
    assert_equal [0.0, 0.0, -3.25], origin
    assert_equal [0.0, 0.0, 1.0], normal
  end

  def test_axis_rejects_unknown_axis
    err = assert_raises(RuntimeError) do
      @server.send(:resolve_mirror_plane, { "axis" => "w", "offset" => 0 })
    end
    assert_match(/axis/, err.message)
  end

  def test_axis_requires_offset
    err = assert_raises(RuntimeError) do
      @server.send(:resolve_mirror_plane, { "axis" => "x" })
    end
    assert_match(/offset/, err.message)
  end

  def test_plane_form_normalizes_normal
    origin, normal = @server.send(:resolve_mirror_plane, {
      "plane" => { "origin" => [1, 2, 3], "normal" => [0, 0, 4] }
    })
    assert_equal [1.0, 2.0, 3.0], origin
    assert_in_delta 0.0, normal[0], 1e-12
    assert_in_delta 0.0, normal[1], 1e-12
    assert_in_delta 1.0, normal[2], 1e-12
  end

  def test_plane_rejects_zero_normal
    err = assert_raises(RuntimeError) do
      @server.send(:resolve_mirror_plane, {
        "plane" => { "origin" => [0, 0, 0], "normal" => [0, 0, 0] }
      })
    end
    assert_match(/normal/, err.message)
  end

  def test_rejects_both_forms
    err = assert_raises(RuntimeError) do
      @server.send(:resolve_mirror_plane, {
        "axis" => "x", "offset" => 0,
        "plane" => { "origin" => [0, 0, 0], "normal" => [1, 0, 0] }
      })
    end
    assert_match(/not both/, err.message)
  end

  def test_rejects_neither_form
    err = assert_raises(RuntimeError) do
      @server.send(:resolve_mirror_plane, {})
    end
    assert_match(/plane/, err.message)
  end

  def test_plane_rejects_wrong_length_origin
    err = assert_raises(RuntimeError) do
      @server.send(:resolve_mirror_plane, {
        "plane" => { "origin" => [0, 0], "normal" => [1, 0, 0] }
      })
    end
    assert_match(/origin/, err.message)
  end
end

class TestBuildMirrorMatrix < Minitest::Test
  def setup
    @server = TestServer.new
  end

  # The matrix is column-major. Indices map as:
  #   col 1: 0..3 → basis-x image
  #   col 2: 4..7 → basis-y image
  #   col 3: 8..11 → basis-z image
  #   col 4: 12..15 → translation (last entry must be 1.0)
  def apply(m, p)
    x, y, z = p
    # p' = M * [x, y, z, 1]^T, with M column-major
    px = m[0] * x + m[4] * y + m[8]  * z + m[12]
    py = m[1] * x + m[5] * y + m[9]  * z + m[13]
    pz = m[2] * x + m[6] * y + m[10] * z + m[14]
    [px, py, pz]
  end

  def test_x_plane_at_10_reflects_origin_to_20
    m = @server.send(:build_mirror_matrix, [10.0, 0.0, 0.0], [1.0, 0.0, 0.0])
    assert_in_delta 20.0, apply(m, [0, 0, 0])[0], 1e-9
    assert_in_delta 0.0,  apply(m, [0, 0, 0])[1], 1e-9
    assert_in_delta 0.0,  apply(m, [0, 0, 0])[2], 1e-9
  end

  def test_x_plane_at_10_reflects_point_through_plane
    # A point at x=2 reflects to x=18 across the plane x=10.
    m = @server.send(:build_mirror_matrix, [10.0, 0.0, 0.0], [1.0, 0.0, 0.0])
    assert_in_delta 18.0, apply(m, [2, 3, 4])[0], 1e-9
    assert_in_delta 3.0,  apply(m, [2, 3, 4])[1], 1e-9
    assert_in_delta 4.0,  apply(m, [2, 3, 4])[2], 1e-9
  end

  def test_y_plane_at_0_negates_y
    m = @server.send(:build_mirror_matrix, [0.0, 0.0, 0.0], [0.0, 1.0, 0.0])
    p = apply(m, [1.0, 5.0, 7.0])
    assert_in_delta 1.0,   p[0], 1e-9
    assert_in_delta(-5.0,  p[1], 1e-9)
    assert_in_delta 7.0,   p[2], 1e-9
  end

  def test_z_plane_at_arbitrary_height
    m = @server.send(:build_mirror_matrix, [0.0, 0.0, 50.0], [0.0, 0.0, 1.0])
    p = apply(m, [3.0, 4.0, 10.0])
    assert_in_delta 3.0,  p[0], 1e-9
    assert_in_delta 4.0,  p[1], 1e-9
    assert_in_delta 90.0, p[2], 1e-9 # 50 + (50 - 10) = 90
  end

  def test_arbitrary_plane_reflects_correctly
    # Plane through origin with normal at 45° in XY: [1/√2, 1/√2, 0].
    # Reflecting (1, 0, 0) across this plane sends it to (0, -1, 0).
    s2 = 1.0 / Math.sqrt(2)
    m = @server.send(:build_mirror_matrix, [0.0, 0.0, 0.0], [s2, s2, 0.0])
    p = apply(m, [1.0, 0.0, 0.0])
    assert_in_delta 0.0,  p[0], 1e-9
    assert_in_delta(-1.0, p[1], 1e-9)
    assert_in_delta 0.0,  p[2], 1e-9
  end

  def test_reflection_is_involutive
    # Reflecting twice across the same plane returns the original point.
    m = @server.send(:build_mirror_matrix, [10.0, 0.0, 0.0], [1.0, 0.0, 0.0])
    p1 = apply(m, [2.5, 3.5, 4.5])
    p2 = apply(m, p1)
    assert_in_delta 2.5, p2[0], 1e-9
    assert_in_delta 3.5, p2[1], 1e-9
    assert_in_delta 4.5, p2[2], 1e-9
  end

  def test_translation_homogeneous_coord_is_one
    m = @server.send(:build_mirror_matrix, [10.0, 0.0, 0.0], [1.0, 0.0, 0.0])
    # Column 4 last element (index 15) must be 1.0 for the matrix to be a
    # valid affine transform — Geom::Transformation expects this layout.
    assert_equal 1.0, m[15]
  end
end
