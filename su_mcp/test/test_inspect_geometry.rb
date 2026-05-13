require_relative "test_helper"

# Unit tests for inspect_geometry's pure helpers. The full method walks
# Sketchup::Group / Face / Edge / Loop and so can't run without SketchUp;
# the bits most likely to drift (solid detection, rounding) are isolated
# as plain functions on counts and tuples.

class TestInspectGeometry < Minitest::Test
  def setup
    @server = TestServer.new
  end

  # -- is_solid_from_edge_face_counts? -------------------------------------

  def test_all_edges_with_two_faces_is_solid
    # A closed box has 12 edges, each shared by exactly 2 faces.
    assert @server.send(:is_solid_from_edge_face_counts?, [2] * 12)
  end

  def test_any_edge_with_one_face_is_not_solid
    # An open box (top face missing) leaves 4 edges with only 1 face each.
    counts = [2] * 8 + [1] * 4
    refute @server.send(:is_solid_from_edge_face_counts?, counts)
  end

  def test_any_edge_with_three_faces_is_not_solid
    # T-junctions: an edge shared by 3 faces is non-manifold, so not solid.
    refute @server.send(:is_solid_from_edge_face_counts?, [2, 2, 3, 2])
  end

  def test_empty_edges_is_not_solid
    # A curve-only or empty group has no edges-per-face structure to call
    # solid — explicitly not solid, not "trivially true".
    refute @server.send(:is_solid_from_edge_face_counts?, [])
  end

  # -- round_xyz -----------------------------------------------------------

  def test_round_xyz_truncates_to_decimals
    assert_equal [1.123457, -0.000001, 99.999999],
                 @server.send(:round_xyz, [1.12345678, -0.00000054, 99.99999949], 6)
  end

  def test_round_xyz_coerces_to_float
    # Integer inputs must come out as floats; the response JSON otherwise
    # leaks a mix of types to the client.
    result = @server.send(:round_xyz, [1, 2, 3], 2)
    result.each { |v| assert_kind_of Float, v }
  end

  def test_round_xyz_handles_axis_aligned_normal_exactly
    # (0, 0, ±1) and (±1, 0, 0) etc. must round to clean tuples — these
    # are the canonical box-face normals and we want the response to show
    # them without floating point noise.
    assert_equal [0.0, 0.0, 1.0], @server.send(:round_xyz, [0.0, 0.0, 1.0], 6)
    assert_equal [-1.0, 0.0, 0.0], @server.send(:round_xyz, [-1.0, 0.0, 0.0], 6)
  end
end
