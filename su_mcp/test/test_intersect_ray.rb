require_relative "test_helper"

# Tests for intersect_ray. The outer public entry point still needs a live
# SketchUp for Geom::Point3d / Vector3d / Transformation, but the skip-and-
# retry loop has been extracted into intersect_ray_loop(...) which takes a
# raycaster callable. These tests drive that loop with a fake raycaster so
# target filtering, back-face culling, max_distance cutoff, and step-cap
# exhaustion are all exercised without SketchUp.

# Subclasses of the bare stubs in test_helper so `is_a?(Sketchup::Group)` /
# `is_a?(Sketchup::ComponentInstance)` matches.
class FakeIRGroup < Sketchup::Group
  attr_accessor :name, :entityID
  def initialize(name:, entityID:)
    @name = name
    @entityID = entityID
  end
end

class FakeIRInstance < Sketchup::ComponentInstance
  attr_accessor :name, :entityID
  def initialize(name:, entityID:)
    @name = name
    @entityID = entityID
  end
end

# Minimal face stand-in: only the loop reads `entityID` off the face leaf.
FakeIRFace = Struct.new(:entityID)

# Wrap a normal-xyz array in a no-arg callable, matching the production
# raycaster's lazy-normal protocol. Track invocation count so tests can
# assert that lazy evaluation actually happens.
class CountedNormal
  attr_reader :calls
  def initialize(xyz)
    @xyz = xyz
    @calls = 0
  end

  def call
    @calls += 1
    @xyz
  end

  def to_proc
    method(:call).to_proc
  end
end

def n_fn(xyz)
  CountedNormal.new(xyz)
end

# Scripted raycaster — pulls successive hits from a queue. `nil` is returned
# when the queue is empty, mimicking a "ray exits geometry" miss.
class ScriptedRaycaster
  attr_reader :calls

  def initialize(hits)
    @hits = hits.dup
    @calls = []
  end

  def call(origin)
    @calls << origin
    return nil if @hits.empty?
    @hits.shift
  end

  # Convenience so the tests can pass the object directly where a Proc is
  # expected (intersect_ray_loop uses `raycaster.call(current)`).
  def to_proc
    method(:call).to_proc
  end
end

class TestIntersectRayFindTargetGroupInPath < Minitest::Test
  def setup
    @server = TestServer.new
    @outer = FakeIRGroup.new(name: "Outer", entityID: 100)
    @inner = FakeIRGroup.new(name: "Rafter W Gable F", entityID: 200)
    @inst  = FakeIRInstance.new(name: "Cabinet", entityID: 300)
  end

  def test_matches_by_string_name
    path = [@outer, @inner, :face_placeholder]
    g = @server.send(:find_target_group_in_path, path, "Rafter W Gable F")
    assert_equal @inner, g
  end

  def test_matches_by_integer_id
    path = [@outer, @inner, :face_placeholder]
    g = @server.send(:find_target_group_in_path, path, 200)
    assert_equal @inner, g
  end

  def test_matches_by_numeric_string_id
    path = [@outer, @inner, :face_placeholder]
    g = @server.send(:find_target_group_in_path, path, "200")
    assert_equal @inner, g
  end

  def test_prefers_innermost_match
    nested = FakeIRGroup.new(name: "Shared", entityID: 400)
    same = FakeIRGroup.new(name: "Shared", entityID: 401)
    path = [nested, same, :face_placeholder]
    g = @server.send(:find_target_group_in_path, path, "Shared")
    assert_equal same, g
  end

  def test_returns_nil_when_no_match
    path = [@outer, @inner, :face_placeholder]
    assert_nil @server.send(:find_target_group_in_path, path, "Not There")
  end

  def test_matches_component_instance_by_name
    path = [@inst, :face_placeholder]
    g = @server.send(:find_target_group_in_path, path, "Cabinet")
    assert_equal @inst, g
  end

  def test_ignores_non_group_entities
    path = [:face_placeholder, :edge_placeholder]
    assert_nil @server.send(:find_target_group_in_path, path, "Anything")
  end
end

class TestIntersectRayFindInnermostGroupOrInstance < Minitest::Test
  def setup
    @server = TestServer.new
  end

  def test_returns_innermost_group
    outer = FakeIRGroup.new(name: "Outer", entityID: 1)
    inner = FakeIRGroup.new(name: "Inner", entityID: 2)
    path = [outer, inner, :face]
    assert_equal inner, @server.send(:find_innermost_group_or_instance, path)
  end

  def test_returns_component_instance
    # The no-target branch should not miss ComponentInstances: callers casting
    # a ray onto a component (cabinet, fixture, etc.) get the instance back.
    inst = FakeIRInstance.new(name: "Cabinet", entityID: 10)
    path = [inst, :face]
    assert_equal inst, @server.send(:find_innermost_group_or_instance, path)
  end

  def test_returns_nil_when_no_groups
    path = [:face_only]
    assert_nil @server.send(:find_innermost_group_or_instance, path)
  end
end

class TestIntersectRayPureHelpers < Minitest::Test
  def setup; @server = TestServer.new; end

  def test_euclid_distance_zero_for_same_point
    d = @server.send(:euclid_distance, [1.0, 2.0, 3.0], [1.0, 2.0, 3.0])
    assert_in_delta 0.0, d, 1e-12
  end

  def test_euclid_distance_3_4_5
    d = @server.send(:euclid_distance, [0.0, 0.0, 0.0], [3.0, 4.0, 0.0])
    assert_in_delta 5.0, d, 1e-12
  end

  def test_vec3_dot
    assert_in_delta 32.0, @server.send(:vec3_dot, [1, 2, 3], [4, 5, 6]), 1e-12
  end

  def test_vec3_dot_orthogonal_is_zero
    assert_in_delta 0.0, @server.send(:vec3_dot, [1, 0, 0], [0, 1, 0]), 1e-12
  end

  def test_advance_xyz_along_steps_by_eps
    eps = SU_MCP::Server::INTERSECT_RAY_EPS
    out = @server.send(:advance_xyz_along, [1.0, 2.0, 3.0], [0.0, 0.0, -1.0])
    assert_in_delta 1.0, out[0], 1e-12
    assert_in_delta 2.0, out[1], 1e-12
    assert_in_delta 3.0 - eps, out[2], 1e-12
  end

  def test_miss_envelope_clean
    out = @server.send(:intersect_ray_miss, :miss)
    assert_equal({ success: true, hit: false }, out)
  end

  def test_miss_envelope_max_distance
    out = @server.send(:intersect_ray_miss, :max_distance_exceeded)
    assert_equal "max_distance_exceeded", out[:reason]
    assert_equal false, out[:hit]
  end

  def test_miss_envelope_step_cap
    out = @server.send(:intersect_ray_miss, :step_cap_exceeded)
    assert_equal "step_cap_exceeded", out[:reason]
  end
end

# Integration tests for the skip-and-retry loop using a scripted raycaster.
# These cover the behaviors the data-shape helpers can't: target filtering,
# back-face culling, max_distance cutoff, step-cap exhaustion, no-target
# innermost-group resolution.
class TestIntersectRayLoop < Minitest::Test
  def setup
    @server = TestServer.new
    @rafter = FakeIRGroup.new(name: "Rafter W Gable F", entityID: 200)
    @other  = FakeIRGroup.new(name: "Other", entityID: 201)
    @face_a = FakeIRFace.new(12345)
    @face_b = FakeIRFace.new(67890)
  end

  def call_loop(*args)
    @server.send(:intersect_ray_loop, *args)
  end

  def test_returns_first_hit_when_no_target
    rc = ScriptedRaycaster.new([
      [[0.0, 0.0, 116.149], [@rafter, @face_a], @face_a, n_fn([0.0, 0.0, 1.0])]
    ])
    out = call_loop([0.0, 0.0, 200.0], [0.0, 0.0, -1.0], nil, nil, false, rc.to_proc)
    assert_equal true, out[:hit]
    assert_in_delta 83.851, out[:distance], 1e-6
    assert_equal "Rafter W Gable F", out[:group_name]
    assert_equal 200, out[:group_id]
    assert_equal 12345, out[:face_id]
    assert_equal [0.0, 0.0, 1.0], out[:face_normal]
  end

  def test_target_skip_until_match
    # First hit lands inside "Other" — skip. Second hit is inside the rafter
    # — accept. The loop must call raycaster twice (once at origin, once at
    # the advanced position).
    skipped = n_fn([0.0, 0.0, 1.0])
    rc = ScriptedRaycaster.new([
      [[0.0, 0.0, 150.0], [@other, @face_b], @face_b, skipped],
      [[0.0, 0.0, 116.149], [@rafter, @face_a], @face_a, n_fn([0.0, 0.0, 1.0])]
    ])
    out = call_loop([0.0, 0.0, 200.0], [0.0, 0.0, -1.0], "Rafter W Gable F", nil, false, rc.to_proc)
    assert_equal true, out[:hit]
    assert_equal "Rafter W Gable F", out[:group_name]
    assert_equal 2, rc.calls.length
    # Second call's origin is just past the first hit (stepped by EPS along
    # the unit direction [0,0,-1] — z decreases by EPS).
    assert_in_delta 150.0 - SU_MCP::Server::INTERSECT_RAY_EPS, rc.calls[1][2], 1e-9
    # The skipped (wrong-target) hit must NOT have triggered normal computation.
    assert_equal 0, skipped.calls, "normal_fn for target-skipped hit must stay lazy"
  end

  def test_back_face_skipped_by_default
    # First hit's normal points the same way as the ray direction (ray going
    # into the back of the face). Skip. Second hit's normal is opposite.
    rc = ScriptedRaycaster.new([
      [[0.0, 0.0, 150.0], [@rafter, @face_a], @face_a, n_fn([0.0, 0.0, -1.0])],
      [[0.0, 0.0, 116.149], [@rafter, @face_b], @face_b, n_fn([0.0, 0.0, 1.0])]
    ])
    out = call_loop([0.0, 0.0, 200.0], [0.0, 0.0, -1.0], nil, nil, false, rc.to_proc)
    assert_equal true, out[:hit]
    assert_equal 67890, out[:face_id]
  end

  def test_back_face_accepted_when_include_back_true
    rc = ScriptedRaycaster.new([
      [[0.0, 0.0, 150.0], [@rafter, @face_a], @face_a, n_fn([0.0, 0.0, -1.0])]
    ])
    out = call_loop([0.0, 0.0, 200.0], [0.0, 0.0, -1.0], nil, nil, true, rc.to_proc)
    assert_equal true, out[:hit]
    assert_equal 12345, out[:face_id]
  end

  def test_max_distance_exceeded_returns_reason
    # Hit lies 100 units away; max_distance is 50.
    rc = ScriptedRaycaster.new([
      [[0.0, 0.0, 100.0], [@rafter, @face_a], @face_a, n_fn([0.0, 0.0, 1.0])]
    ])
    out = call_loop([0.0, 0.0, 200.0], [0.0, 0.0, -1.0], nil, 50.0, false, rc.to_proc)
    assert_equal false, out[:hit]
    assert_equal "max_distance_exceeded", out[:reason]
  end

  def test_max_distance_inside_cap_returns_hit
    rc = ScriptedRaycaster.new([
      [[0.0, 0.0, 180.0], [@rafter, @face_a], @face_a, n_fn([0.0, 0.0, 1.0])]
    ])
    out = call_loop([0.0, 0.0, 200.0], [0.0, 0.0, -1.0], nil, 50.0, false, rc.to_proc)
    assert_equal true, out[:hit]
  end

  def test_clean_miss_has_no_reason
    rc = ScriptedRaycaster.new([])
    out = call_loop([0.0, 0.0, 200.0], [0.0, 0.0, 1.0], nil, nil, false, rc.to_proc)
    assert_equal false, out[:hit]
    refute out.key?(:reason), "clean miss must NOT carry a reason; got #{out.inspect}"
  end

  def test_step_cap_exhausted_returns_reason_and_skips_normal_work
    # An infinite stream of "wrong target" hits forces the step cap to fire.
    # MAX_STEPS = 256 — provide more than that. Each hit gets a fresh
    # CountedNormal so we can assert none of them were invoked: target-skipped
    # paths must never pay the normal-transform cost.
    normals = Array.new(300) { n_fn([0.0, 0.0, 1.0]) }
    hits = normals.map { |nrm| [[0.0, 0.0, 0.0], [@other, @face_a], @face_a, nrm] }
    rc = ScriptedRaycaster.new(hits)
    out = call_loop([0.0, 0.0, 200.0], [0.0, 0.0, -1.0], "Ghost", nil, false, rc.to_proc)
    assert_equal false, out[:hit]
    assert_equal "step_cap_exceeded", out[:reason]
    assert_equal SU_MCP::Server::INTERSECT_RAY_MAX_STEPS, rc.calls.length
    total_normal_calls = normals.sum(&:calls)
    assert_equal 0, total_normal_calls,
                 "target-skipped hits must not compute normals; got #{total_normal_calls}"
  end

  def test_face_normal_passed_through_to_hit
    # Normal points opposite-ish to the ray direction (negative dot product)
    # so the front-face filter doesn't reject the hit.
    nrm = n_fn([-0.447, 0.0, 0.894])
    rc = ScriptedRaycaster.new([
      [[1.0, 2.0, 3.0], [@rafter, @face_a], @face_a, nrm]
    ])
    out = call_loop([0.0, 0.0, 0.0], [1.0, 0.0, 0.0], nil, nil, false, rc.to_proc)
    assert_equal [-0.447, 0.0, 0.894], out[:face_normal]
    # Accepted hit: normal was invoked once (back-face check) and reused
    # for the response (no second invocation).
    assert_equal 1, nrm.calls
  end

  def test_hit_inside_component_instance_returns_group_name
    inst = FakeIRInstance.new(name: "Cabinet", entityID: 999)
    rc = ScriptedRaycaster.new([
      [[5.0, 5.0, 5.0], [inst, @face_a], @face_a, n_fn([0.0, 0.0, 1.0])]
    ])
    # No-target branch must surface the ComponentInstance.
    out = call_loop([0.0, 0.0, 0.0], [1.0, 0.0, 0.0], nil, nil, false, rc.to_proc)
    assert_equal "Cabinet", out[:group_name]
    assert_equal 999, out[:group_id]
  end

  def test_include_back_accepted_hit_still_computes_normal_for_response
    # When back-face culling is off, the back-face check is skipped — but
    # the response still wants face_normal, so the loop must still invoke
    # normal_fn exactly once.
    nrm = n_fn([0.0, 0.0, -1.0])
    rc = ScriptedRaycaster.new([
      [[0.0, 0.0, 150.0], [@rafter, @face_a], @face_a, nrm]
    ])
    out = call_loop([0.0, 0.0, 200.0], [0.0, 0.0, -1.0], nil, nil, true, rc.to_proc)
    assert_equal [0.0, 0.0, -1.0], out[:face_normal]
    assert_equal 1, nrm.calls
  end
end

class TestIntersectRayInputGuards < Minitest::Test
  def setup
    @server = TestServer.new
  end

  def test_rejects_missing_origin
    err = assert_raises(RuntimeError) do
      @server.send(:intersect_ray, { "direction" => [0, 0, -1] })
    end
    assert_match(/origin/, err.message)
  end

  def test_rejects_wrong_length_origin
    err = assert_raises(RuntimeError) do
      @server.send(:intersect_ray,
                   { "origin" => [0, 0], "direction" => [0, 0, -1] })
    end
    assert_match(/origin/, err.message)
  end

  def test_rejects_missing_direction
    err = assert_raises(RuntimeError) do
      @server.send(:intersect_ray, { "origin" => [0, 0, 0] })
    end
    assert_match(/direction/, err.message)
  end

  def test_rejects_wrong_length_direction
    err = assert_raises(RuntimeError) do
      @server.send(:intersect_ray,
                   { "origin" => [0, 0, 0], "direction" => [1, 0] })
    end
    assert_match(/direction/, err.message)
  end

  def test_rejects_zero_direction_within_tolerance
    err = assert_raises(RuntimeError) do
      @server.send(:intersect_ray,
                   { "origin" => [0, 0, 0], "direction" => [0.0, 0.0, 0.0] })
    end
    assert_match(/non-zero/, err.message)
  end
end
