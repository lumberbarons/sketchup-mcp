require_relative "test_helper"

# Pure-helper tests for find_groups' filter predicates. The full method
# touches Sketchup.active_model and entity-collection iteration, which need
# a live SketchUp; the helpers it delegates to are pure data + branching
# and are the parts most likely to harbor logic bugs (especially the AABB
# intersection rules), so we cover them in isolation.

# A fake "BoundingBox" with .min and .max returning point structs.
FakeFGBounds = Struct.new(:min, :max)
FakeFGPoint = Struct.new(:x, :y, :z)

def make_bounds(min_xyz, max_xyz)
  FakeFGBounds.new(FakeFGPoint.new(*min_xyz), FakeFGPoint.new(*max_xyz))
end

class FakeFGGroup < Sketchup::Group
end

class FakeFGComponent < Sketchup::ComponentInstance
end

class TestFindGroupsFilters < Minitest::Test
  def setup
    @server = TestServer.new
  end

  # -- entity_matches_kind? -------------------------------------------------

  def test_kind_accepts_groups_by_default
    assert_equal true,
                 @server.send(:entity_matches_kind?, FakeFGGroup.new, false)
  end

  def test_kind_rejects_components_when_flag_off
    assert_equal false,
                 @server.send(:entity_matches_kind?, FakeFGComponent.new, false)
  end

  def test_kind_accepts_components_when_flag_on
    assert_equal true,
                 @server.send(:entity_matches_kind?, FakeFGComponent.new, true)
  end

  def test_kind_rejects_arbitrary_entities
    # Edges, faces, etc. — anything that's neither a Group nor a Component.
    assert_equal false,
                 @server.send(:entity_matches_kind?, Object.new, true)
  end

  # -- name_matches? --------------------------------------------------------

  def test_name_no_filter_always_matches
    assert_equal true, @server.send(:name_matches?, "anything", nil, nil)
    assert_equal true, @server.send(:name_matches?, "", nil, nil)
  end

  def test_name_prefix_match
    assert_equal true,  @server.send(:name_matches?, "WA 5", "WA ", nil)
    assert_equal false, @server.send(:name_matches?, "WB 5", "WA ", nil)
    # Prefix is case-sensitive — matches String#start_with? semantics.
    assert_equal false, @server.send(:name_matches?, "wa 5", "WA ", nil)
  end

  def test_name_pattern_match
    pattern = Regexp.new("^Rafter [WE] \\d+$")
    assert_equal true,  @server.send(:name_matches?, "Rafter W 5", nil, pattern)
    assert_equal true,  @server.send(:name_matches?, "Rafter E 12", nil, pattern)
    assert_equal false, @server.send(:name_matches?, "Rafter Doubled W 1", nil, pattern)
    assert_equal false, @server.send(:name_matches?, "Fly Rafter", nil, pattern)
  end

  # -- bounds_matches? (AABB intersection) ----------------------------------

  def test_bounds_no_filter_always_matches
    eb = make_bounds([0, 0, 0], [1, 1, 1])
    assert_equal true, @server.send(:bounds_matches?, eb, nil)
  end

  def test_bounds_fully_inside_query_matches
    eb = make_bounds([2, 2, 2], [3, 3, 3])
    query = { "min" => [0, 0, 0], "max" => [10, 10, 10] }
    assert_equal true, @server.send(:bounds_matches?, eb, query)
  end

  def test_bounds_partial_overlap_matches
    eb = make_bounds([5, 5, 5], [15, 15, 15])
    query = { "min" => [0, 0, 0], "max" => [10, 10, 10] }
    assert_equal true, @server.send(:bounds_matches?, eb, query)
  end

  def test_bounds_query_inside_entity_matches
    # The opposite containment — query box sits inside the entity's larger
    # bounds. Intersection (not containment) is the contract, so this hits.
    eb = make_bounds([0, 0, 0], [100, 100, 100])
    query = { "min" => [10, 10, 10], "max" => [20, 20, 20] }
    assert_equal true, @server.send(:bounds_matches?, eb, query)
  end

  def test_bounds_disjoint_on_x_misses
    eb = make_bounds([20, 0, 0], [30, 10, 10])
    query = { "min" => [0, 0, 0], "max" => [10, 10, 10] }
    assert_equal false, @server.send(:bounds_matches?, eb, query)
  end

  def test_bounds_disjoint_on_y_misses
    eb = make_bounds([0, 20, 0], [10, 30, 10])
    query = { "min" => [0, 0, 0], "max" => [10, 10, 10] }
    assert_equal false, @server.send(:bounds_matches?, eb, query)
  end

  def test_bounds_disjoint_on_z_misses
    eb = make_bounds([0, 0, 20], [10, 10, 30])
    query = { "min" => [0, 0, 0], "max" => [10, 10, 10] }
    assert_equal false, @server.send(:bounds_matches?, eb, query)
  end

  def test_bounds_touch_on_face_counts_as_match
    # Two boxes that share a face (emax.x == qmin.x). This matches SketchUp's
    # BoundingBox#intersect semantics (touching counts) and is the more
    # forgiving choice for "what's adjacent to X" queries. Pin it.
    eb = make_bounds([10, 0, 0], [20, 10, 10])
    query = { "min" => [0, 0, 0], "max" => [10, 10, 10] }
    assert_equal true, @server.send(:bounds_matches?, eb, query)
  end

  def test_bounds_negative_coordinates_work
    eb = make_bounds([-5, -5, -5], [-1, -1, -1])
    query = { "min" => [-10, -10, -10], "max" => [0, 0, 0] }
    assert_equal true, @server.send(:bounds_matches?, eb, query)

    far = make_bounds([-100, -100, -100], [-50, -50, -50])
    assert_equal false, @server.send(:bounds_matches?, far, query)
  end
end
