require_relative "test_helper"

# Pure-helper tests for intersect_ray. The end-to-end raytest needs a live
# SketchUp (`Geom::Point3d`, `Geom::Vector3d`, `Geom::Transformation`,
# `Sketchup.active_model#raytest`) so only the data-shaped helpers are
# exercised here: path filtering and the early input-shape guards that run
# before any Geom calls.

# Subclasses of the bare stubs in test_helper so `is_a?(Sketchup::Group)` /
# `is_a?(Sketchup::ComponentInstance)` matches. A real face stub isn't needed
# here — find_target_group_in_path only inspects Groups / Instances.
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
    # IDs that arrive as strings (e.g. "200") should still match by ID.
    path = [@outer, @inner, :face_placeholder]
    g = @server.send(:find_target_group_in_path, path, "200")
    assert_equal @inner, g
  end

  def test_prefers_innermost_match
    # If both an outer group and a same-named inner group are on the path,
    # the *innermost* wins — that's where the ray actually landed.
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
end
