require_relative "test_helper"

# Tests for the closest_points geometry helpers. The public handler still
# needs a live SketchUp (Geom::Transformation, mesh extraction, raytest),
# but the math the bugs would hide in — point-to-triangle distance,
# segment-segment distance, triangle-triangle min distance, AABB
# penetration depth, the search loop, and the AABB-overlap classifier —
# is all pure data and is exercised here.

class TestPointTriangleDistance < Minitest::Test
  def setup; @server = TestServer.new; end

  # Reference triangle in the z=0 plane: (0,0,0), (1,0,0), (0,1,0).
  TRI = [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]].freeze

  def call(p)
    @server.send(:point_triangle_distance_sq, p, TRI)
  end

  def test_point_in_triangle_plane_inside_is_zero
    dsq, c = call([0.25, 0.25, 0.0])
    assert_in_delta 0.0, dsq, 1e-12
    assert_equal [0.25, 0.25, 0.0], c
  end

  def test_point_directly_above_centroid_returns_plane_distance
    dsq, c = call([0.25, 0.25, 5.0])
    assert_in_delta 25.0, dsq, 1e-9
    assert_in_delta 0.25, c[0], 1e-9
    assert_in_delta 0.25, c[1], 1e-9
    assert_in_delta 0.0,  c[2], 1e-9
  end

  def test_closest_point_is_a_vertex_when_p_in_vertex_region
    # Far past vertex (1,0,0) in +x: the closest feature is that vertex.
    dsq, c = call([3.0, 0.0, 0.0])
    assert_in_delta 4.0, dsq, 1e-9
    assert_equal [1.0, 0.0, 0.0], c
  end

  def test_closest_point_is_on_edge_when_p_outside_one_edge
    # p outside the hypotenuse: closest feature is a point on edge (1,0)-(0,1).
    dsq, c = call([1.0, 1.0, 0.0])
    # Foot of perpendicular onto edge x+y=1 from (1,1,0) is (0.5,0.5,0).
    assert_in_delta 0.5, dsq, 1e-9
    assert_in_delta 0.5, c[0], 1e-9
    assert_in_delta 0.5, c[1], 1e-9
  end

  def test_point_at_vertex_returns_zero
    dsq, c = call([0.0, 1.0, 0.0])
    assert_in_delta 0.0, dsq, 1e-12
    assert_equal [0.0, 1.0, 0.0], c
  end
end

class TestSegmentSegmentDistance < Minitest::Test
  def setup; @server = TestServer.new; end

  def call(p1, p2, q1, q2)
    @server.send(:segment_segment_distance_sq, p1, p2, q1, q2)
  end

  def test_parallel_offset_segments
    dsq, _cp, _cq = call([0.0, 0.0, 0.0], [1.0, 0.0, 0.0],
                         [0.0, 2.0, 0.0], [1.0, 2.0, 0.0])
    assert_in_delta 4.0, dsq, 1e-12
  end

  def test_crossing_segments_have_zero_distance
    # Two segments crossing at (0,0,0).
    dsq, _cp, _cq = call([-1.0, 0.0, 0.0], [1.0, 0.0, 0.0],
                         [0.0, -1.0, 0.0], [0.0, 1.0, 0.0])
    assert_in_delta 0.0, dsq, 1e-12
  end

  def test_skew_segments_minimum_at_clamped_endpoint
    # Two perpendicular non-touching segments separated in z.
    dsq, cp, cq = call([0.0, 0.0, 0.0], [1.0, 0.0, 0.0],
                       [0.0, 0.0, 3.0], [0.0, 1.0, 3.0])
    assert_in_delta 9.0, dsq, 1e-9
    assert_in_delta 0.0, cp[0], 1e-9
    assert_in_delta 0.0, cq[0], 1e-9
  end

  def test_zero_length_first_segment_falls_back_to_point_segment
    dsq, _cp, _cq = call([5.0, 0.0, 0.0], [5.0, 0.0, 0.0],
                         [0.0, 0.0, 0.0], [10.0, 0.0, 0.0])
    # Distance from (5,0,0) to the x-axis from 0..10 is 0.
    assert_in_delta 0.0, dsq, 1e-12
  end

  def test_zero_length_both_segments
    dsq, cp, cq = call([1.0, 2.0, 3.0], [1.0, 2.0, 3.0],
                       [4.0, 5.0, 6.0], [4.0, 5.0, 6.0])
    assert_in_delta 27.0, dsq, 1e-9
    assert_equal [1.0, 2.0, 3.0], cp
    assert_equal [4.0, 5.0, 6.0], cq
  end
end

class TestTriangleTriangleMinDistance < Minitest::Test
  def setup; @server = TestServer.new; end

  def call(t1, t2)
    @server.send(:triangle_triangle_min_distance, t1, t2)
  end

  def test_coplanar_disjoint_triangles
    t1 = [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]]
    t2 = [[5.0, 0.0, 0.0], [6.0, 0.0, 0.0], [5.0, 1.0, 0.0]]
    dist, _pa, _pb = call(t1, t2)
    # Closest features: vertex (1,0,0) on t1 and vertex (5,0,0) on t2 — gap 4.
    assert_in_delta 4.0, dist, 1e-9
  end

  def test_stacked_triangles_along_z
    t1 = [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]]
    t2 = [[0.0, 0.0, 2.5], [1.0, 0.0, 2.5], [0.0, 1.0, 2.5]]
    dist, _pa, _pb = call(t1, t2)
    assert_in_delta 2.5, dist, 1e-9
  end

  def test_triangles_sharing_an_edge_have_zero_distance
    t1 = [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]]
    t2 = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [1.0, 1.0, 0.0]]
    dist, _pa, _pb = call(t1, t2)
    assert_in_delta 0.0, dist, 1e-9
  end

  def test_intersecting_triangles_have_zero_distance
    # Vertical triangle slicing through horizontal one — they intersect.
    t1 = [[0.0, 0.0, 0.0], [2.0, 0.0, 0.0], [0.0, 2.0, 0.0]]
    t2 = [[0.5, 0.5, -1.0], [0.5, 0.5, 1.0], [1.5, 0.5, 0.0]]
    dist, _pa, _pb = call(t1, t2)
    # Approximate: vertex-into-triangle test will find a point on t2 that
    # projects inside t1 at z=0 → distance 0.
    assert_in_delta 0.0, dist, 1e-6
  end
end

class TestAABBPenetrationDepth < Minitest::Test
  def setup; @server = TestServer.new; end

  def call(ox, oy, oz)
    @server.send(:aabb_penetration_depth, ox, oy, oz)
  end

  def test_returns_smallest_positive_axis_penetration
    # Boxes overlap by 5 in x, 1 in y, 3 in z — depth is 1 (the
    # easiest-to-separate axis).
    assert_in_delta 1.0, call(5.0, 1.0, 3.0), 1e-12
  end

  def test_ignores_negative_axes
    # AABBs clear on y (negative penetration) but overlap on x and z. For
    # the overlap branch we trust the caller to have classified as overlap
    # via aabb_overlap_extents; the helper just returns the min of the
    # positive extents.
    assert_in_delta 2.0, call(2.0, -3.0, 4.0), 1e-12
  end

  def test_all_clear_returns_zero
    assert_equal 0.0, call(-1.0, -2.0, -3.0)
  end
end

class TestFanTriangulate < Minitest::Test
  def setup; @server = TestServer.new; end

  def call(world_pts, face_id = 99)
    out = []
    @server.send(:fan_triangulate, world_pts, face_id, out)
    out
  end

  def test_triangle_passes_through_as_one_triangle
    pts = [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]]
    tris = call(pts)
    assert_equal 1, tris.length
    assert_equal pts, tris[0][:points]
    assert_equal 99, tris[0][:face_id]
  end

  def test_quad_splits_into_two_triangles_sharing_first_vertex
    # Vertices in CCW order around a unit square in z=0.
    q0 = [0.0, 0.0, 0.0]
    q1 = [1.0, 0.0, 0.0]
    q2 = [1.0, 1.0, 0.0]
    q3 = [0.0, 1.0, 0.0]
    tris = call([q0, q1, q2, q3])
    assert_equal 2, tris.length
    # Fan from q0: (q0,q1,q2) and (q0,q2,q3).
    assert_equal [q0, q1, q2], tris[0][:points]
    assert_equal [q0, q2, q3], tris[1][:points]
  end

  def test_pentagon_splits_into_three_triangles
    # n-gon coverage: 5-vertex polygon → 3 triangles. Verifies no
    # silent vertex drop on an arbitrary n.
    pts = (0..4).map { |i| [i.to_f, (i * 2).to_f, 0.0] }
    tris = call(pts)
    assert_equal 3, tris.length
    tris.each { |t| assert_equal pts[0], t[:points][0], "every fan triangle shares pts[0]" }
    # Last triangle reaches the final vertex.
    assert_equal pts[4], tris.last[:points][2]
  end

  def test_skips_degenerate_polygons_with_fewer_than_three_vertices
    out = []
    @server.send(:fan_triangulate, [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0]], 1, out)
    assert_empty out
  end

  def test_stamps_each_triangle_with_face_id
    pts = [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [1.0, 1.0, 0.0], [0.0, 1.0, 0.0]]
    tris = call(pts, 12345)
    tris.each { |t| assert_equal 12345, t[:face_id] }
  end
end

class TestClosestPointsClassify < Minitest::Test
  def setup; @server = TestServer.new; end

  def call(surface_distance, ox, oy, oz, tol)
    @server.send(:closest_points_classify, surface_distance, ox, oy, oz, tol)
  end

  def test_clear_when_surface_distance_exceeds_tolerance
    status, signed = call(5.0, -1.0, -1.0, -1.0, 0.0625)
    assert_equal "clear", status
    assert_in_delta 5.0, signed, 1e-12
  end

  def test_contact_when_within_tolerance_and_no_strict_aabb_overlap
    # Surface gap is sub-tolerance and AABBs touch on every axis (gap 0) but
    # don't strictly overlap by > tol on every axis. That's "contact", not
    # "overlap".
    status, signed = call(0.001, 0.0, 0.0, 0.0, 0.0625)
    assert_equal "contact", status
    assert_in_delta 0.001, signed, 1e-12
  end

  def test_overlap_when_aabbs_strictly_overlap_on_every_axis
    # Surface distance is zero (interpenetration found by face-pair scan)
    # AND AABBs overlap by more than tol on every axis. Magnitude is the
    # smallest of the three positive penetration extents.
    status, signed = call(0.0, 5.0, 1.0, 3.0, 0.0625)
    assert_equal "overlap", status
    assert_in_delta(-1.0, signed, 1e-12)
  end

  def test_contact_when_one_axis_clears_even_if_others_overlap
    # AABBs overlap deeply on x and z, but are clear on y. That's a
    # near-touch (e.g. surfaces grazing past each other), not overlap.
    status, signed = call(0.01, 5.0, -2.0, 5.0, 0.0625)
    assert_equal "contact", status
    assert_in_delta 0.01, signed, 1e-12
  end

  def test_overlap_threshold_is_strict_greater_than_tolerance
    # AABB overlap exactly at tolerance on the y axis does NOT count as
    # strict overlap (the condition is `> tol`, not `>= tol`). Mirrors
    # validate_geometry's no_overlap convention.
    status, _signed = call(0.0, 1.0, 0.0625, 1.0, 0.0625)
    assert_equal "contact", status
  end
end

# Fakes for the closest_points_search loop — exercise the search itself
# without needing actual triangle math fixtures.
class TestClosestPointsSearch < Minitest::Test
  def setup; @server = TestServer.new; end

  def tri(face_id, pts)
    { points: pts, face_id: face_id }
  end

  def test_picks_smallest_pair_and_records_face_ids
    tris_a = [
      tri(100, [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]]),
      tri(101, [[10.0, 0.0, 0.0], [11.0, 0.0, 0.0], [10.0, 1.0, 0.0]])
    ]
    tris_b = [
      tri(200, [[2.0, 0.0, 0.0], [3.0, 0.0, 0.0], [2.0, 1.0, 0.0]])  # ~1 from a[0]
    ]
    out = @server.send(:closest_points_search, tris_a, tris_b)
    assert_in_delta 1.0, out[:distance], 1e-9
    assert_equal 100, out[:face_a_id]
    assert_equal 200, out[:face_b_id]
  end

  def test_short_circuits_on_zero_distance
    # If an exact-zero pair is found early, the loop must not keep
    # scanning. Mark a second pair that would also be zero but with
    # different face IDs and assert the first one is returned.
    tris_a = [
      tri(1, [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]]),
      tri(2, [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]])
    ]
    tris_b = [tri(99, [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]])]
    out = @server.send(:closest_points_search, tris_a, tris_b)
    assert_in_delta 0.0, out[:distance], 1e-12
    assert_equal 1, out[:face_a_id]
  end
end

# Cube-mesh fixture for point-in-solid parity tests. Triangles are wound so
# face normals point outward — what world_triangles_for_group produces for a
# manifold group with consistent face orientation.
module CubeMeshFixture
  CORNER_BITS = [
    [-1, -1, -1], [-1, -1,  1], [-1,  1, -1], [-1,  1,  1],
    [ 1, -1, -1], [ 1, -1,  1], [ 1,  1, -1], [ 1,  1,  1]
  ].freeze
  # [v0, v1, v2, v3] in CCW order viewed from outside the cube.
  FACE_QUADS = [
    [4, 6, 7, 5],  # +X
    [0, 1, 3, 2],  # -X
    [2, 3, 7, 6],  # +Y
    [0, 4, 5, 1],  # -Y
    [1, 5, 7, 3],  # +Z
    [0, 2, 6, 4]   # -Z
  ].freeze

  def self.cube(cx:, cy:, cz:, hx:, hy:, hz:, face_id_base: 100)
    corners = CORNER_BITS.map do |sx, sy, sz|
      [cx + sx * hx, cy + sy * hy, cz + sz * hz]
    end
    tris = []
    FACE_QUADS.each_with_index do |(a, b, c, d), idx|
      fid = face_id_base + idx
      tris << { points: [corners[a], corners[b], corners[c]], face_id: fid }
      tris << { points: [corners[a], corners[c], corners[d]], face_id: fid }
    end
    tris
  end
end

class TestRayTriangleIntersect < Minitest::Test
  def setup; @server = TestServer.new; end

  TRI = [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]].freeze

  def test_ray_hits_through_triangle_interior
    assert @server.send(:ray_intersects_triangle?, [0.25, 0.25, -1.0], [0.0, 0.0, 1.0], TRI)
  end

  def test_ray_misses_off_to_one_side
    refute @server.send(:ray_intersects_triangle?, [2.0, 2.0, -1.0], [0.0, 0.0, 1.0], TRI)
  end

  def test_ray_parallel_to_triangle_plane_is_miss
    refute @server.send(:ray_intersects_triangle?, [0.25, 0.25, 1.0], [1.0, 0.0, 0.0], TRI)
  end

  def test_ray_pointing_away_from_triangle_is_miss
    # Origin above triangle, ray pointing further up — no forward hit.
    refute @server.send(:ray_intersects_triangle?, [0.25, 0.25, 1.0], [0.0, 0.0, 1.0], TRI)
  end

  def test_origin_exactly_on_triangle_is_excluded
    # Excluded so a sample point sitting on a face doesn't count itself.
    refute @server.send(:ray_intersects_triangle?, [0.25, 0.25, 0.0], [0.0, 0.0, 1.0], TRI)
  end
end

class TestPointInSolid < Minitest::Test
  def setup; @server = TestServer.new; end

  def cube(**kw); CubeMeshFixture.cube(**kw); end

  def test_center_of_cube_is_inside
    tris = cube(cx: 0.0, cy: 0.0, cz: 0.0, hx: 1.0, hy: 1.0, hz: 1.0)
    assert @server.send(:point_in_solid?, [0.0, 0.0, 0.0], tris)
  end

  def test_point_far_outside_cube_is_outside
    tris = cube(cx: 0.0, cy: 0.0, cz: 0.0, hx: 1.0, hy: 1.0, hz: 1.0)
    refute @server.send(:point_in_solid?, [5.0, 0.0, 0.0], tris)
  end

  def test_point_just_outside_face_is_outside
    tris = cube(cx: 0.0, cy: 0.0, cz: 0.0, hx: 1.0, hy: 1.0, hz: 1.0)
    refute @server.send(:point_in_solid?, [1.001, 0.0, 0.0], tris)
  end

  def test_point_inside_offset_cube
    tris = cube(cx: 10.0, cy: 20.0, cz: 30.0, hx: 0.5, hy: 0.5, hz: 0.5)
    assert @server.send(:point_in_solid?, [10.1, 20.0, 30.0], tris)
    refute @server.send(:point_in_solid?, [0.0, 0.0, 0.0], tris)
  end
end

class TestVolumesActuallyIntersect < Minitest::Test
  def setup; @server = TestServer.new; end

  def cube(**kw); CubeMeshFixture.cube(**kw); end

  # Two AABBs that share a face but no volume — the standard "stacked block"
  # contact case. Must not register as a volume intersection.
  def test_face_to_face_touching_cubes_have_disjoint_volumes
    a_tris = cube(cx: 0.0, cy: 0.0, cz: 0.0, hx: 1.0, hy: 1.0, hz: 1.0, face_id_base: 100)
    b_tris = cube(cx: 2.0, cy: 0.0, cz: 0.0, hx: 1.0, hy: 1.0, hz: 1.0, face_id_base: 200)
    refute @server.send(:volumes_actually_intersect?, a_tris, b_tris)
  end

  # Two cubes that genuinely interpenetrate must register as intersecting.
  def test_interpenetrating_cubes_intersect
    a_tris = cube(cx: 0.0, cy: 0.0, cz: 0.0, hx: 1.0, hy: 1.0, hz: 1.0, face_id_base: 100)
    b_tris = cube(cx: 1.0, cy: 0.0, cz: 0.0, hx: 1.0, hy: 1.0, hz: 1.0, face_id_base: 200)
    assert @server.send(:volumes_actually_intersect?, a_tris, b_tris)
  end

  # A small cube fully embedded in a larger cube's solid material is a real
  # interpenetration. Must register.
  def test_embedded_cube_in_larger_solid_intersects
    inner_tris = cube(cx: 0.0, cy: 0.0, cz: 0.0, hx: 0.5, hy: 0.5, hz: 0.5, face_id_base: 100)
    outer_tris = cube(cx: 0.0, cy: 0.0, cz: 0.0, hx: 2.0, hy: 2.0, hz: 2.0, face_id_base: 200)
    assert @server.send(:volumes_actually_intersect?, inner_tris, outer_tris)
  end

  # Regression for sch-jha: a part sitting cleanly in a cavity carved into
  # a host. The host's mesh is the outer wall (normals outward) + the
  # cavity walls (normals pointing INTO the cavity = away from host material).
  # The inner part's body occupies the cavity; surfaces are coincident but
  # the part's material is in the cavity-void, not in the host's solid.
  # volumes_actually_intersect? must say false.
  def test_part_in_cavity_does_not_intersect
    # Inner part: 1×1×1 cube at origin (half-extent 0.5).
    part_tris = cube(cx: 0.0, cy: 0.0, cz: 0.0, hx: 0.5, hy: 0.5, hz: 0.5, face_id_base: 100)

    # Host: outer 4×4×4 cube around origin (half-extent 2.0), with a 1×1×1
    # cavity at origin matching the part. Cavity walls are the same cube
    # as the part with reversed winding (b/c swap) — that flips each
    # triangle's normal so it points INTO the cavity rather than outward
    # from the part. Together with the outer cube this forms a closed
    # shell whose "inside" is the donut between the outer wall and the
    # cavity wall.
    host_outer = cube(cx: 0.0, cy: 0.0, cz: 0.0, hx: 2.0, hy: 2.0, hz: 2.0, face_id_base: 200)
    cavity_walls = cube(cx: 0.0, cy: 0.0, cz: 0.0, hx: 0.5, hy: 0.5, hz: 0.5, face_id_base: 300).map do |t|
      a, b, c = t[:points]
      { points: [a, c, b], face_id: t[:face_id] }
    end
    host_tris = host_outer + cavity_walls

    refute @server.send(:volumes_actually_intersect?, part_tris, host_tris),
           "part in cavity must not register as a volume intersection"
  end
end
