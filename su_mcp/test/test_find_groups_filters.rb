require_relative "test_helper"

# Pure-helper tests for find_groups' filter predicates. The full method
# touches Sketchup.active_model and entity-collection iteration, which need
# a live SketchUp; the helpers it delegates to are pure data + branching
# and are the parts most likely to harbor logic bugs (especially the AABB
# intersection rules), so we cover them in isolation.
#
# Fixtures are nested inside FindGroupsTestSupport so they cannot leak into
# the shared top-level namespace and collide with sibling test files (which
# can be loaded in the same process by the test runner).

module FindGroupsTestSupport
  # A fake "BoundingBox" with .min and .max returning point structs.
  FakeFGBounds = Struct.new(:min, :max)
  FakeFGPoint = Struct.new(:x, :y, :z)

  def self.make_bounds(min_xyz, max_xyz)
    FakeFGBounds.new(FakeFGPoint.new(*min_xyz), FakeFGPoint.new(*max_xyz))
  end

  class FakeFGGroup < Sketchup::Group
  end

  class FakeFGComponent < Sketchup::ComponentInstance
  end
end

class TestFindGroupsFilters < Minitest::Test
  include FindGroupsTestSupport

  def make_bounds(*args); FindGroupsTestSupport.make_bounds(*args); end
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

  def test_kind_accepts_groups_when_components_flag_on
    # Groups should match regardless of the include_components flag — turning
    # the flag on never narrows the Group result set.
    assert_equal true,
                 @server.send(:entity_matches_kind?, FakeFGGroup.new, true)
  end

  def test_kind_rejects_arbitrary_entities_when_flag_off
    # Round out the matrix: non-Group, non-Component, flag off → false.
    assert_equal false,
                 @server.send(:entity_matches_kind?, Object.new, false)
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

  def test_bounds_touch_on_y_face_counts_as_match
    # Same touching-counts contract, exercised on the y axis. If '<' on
    # emax.y were flipped to '<=', this would no longer match.
    eb = make_bounds([0, 10, 0], [10, 20, 10])
    query = { "min" => [0, 0, 0], "max" => [10, 10, 10] }
    assert_equal true, @server.send(:bounds_matches?, eb, query)
  end

  def test_bounds_touch_on_z_face_counts_as_match
    eb = make_bounds([0, 0, 10], [10, 10, 20])
    query = { "min" => [0, 0, 0], "max" => [10, 10, 10] }
    assert_equal true, @server.send(:bounds_matches?, eb, query)
  end

  def test_bounds_low_side_disjoint_on_x_misses
    # Pin the 'emax.x < qmin[0]' disjunct (entity sits below the query box
    # on x). Without this case, that disjunct could be deleted unnoticed.
    eb = make_bounds([-30, 0, 0], [-20, 10, 10])
    query = { "min" => [0, 0, 0], "max" => [10, 10, 10] }
    assert_equal false, @server.send(:bounds_matches?, eb, query)
  end

  def test_bounds_low_side_disjoint_on_y_misses
    eb = make_bounds([0, -30, 0], [10, -20, 10])
    query = { "min" => [0, 0, 0], "max" => [10, 10, 10] }
    assert_equal false, @server.send(:bounds_matches?, eb, query)
  end

  def test_bounds_low_side_disjoint_on_z_misses
    eb = make_bounds([0, 0, -30], [10, 10, -20])
    query = { "min" => [0, 0, 0], "max" => [10, 10, 10] }
    assert_equal false, @server.send(:bounds_matches?, eb, query)
  end

  def test_bounds_negative_coordinates_work
    eb = make_bounds([-5, -5, -5], [-1, -1, -1])
    query = { "min" => [-10, -10, -10], "max" => [0, 0, 0] }
    assert_equal true, @server.send(:bounds_matches?, eb, query)

    far = make_bounds([-100, -100, -100], [-50, -50, -50])
    assert_equal false, @server.send(:bounds_matches?, far, query)
  end
end

module FindGroupsTestSupport
  # A find_groups-callable group. Exposes the attributes describe_match reads
  # (entityID, name, bounds) and is_a?(Sketchup::Group) via inheritance.
  class FakeFGFullGroup < Sketchup::Group
    attr_reader :name, :entityID, :bounds
    def initialize(name, id, bounds = nil)
      @name = name
      @entityID = id
      @bounds = bounds || FindGroupsTestSupport.make_bounds([0, 0, 0], [1, 1, 1])
    end
    def layer; nil; end
    def material; nil; end
    # Empty by default so the recursive walker can call `.entities` on
    # leaf groups without blowing up; FakeNestedGroup overrides.
    def entities; []; end
  end

  # TestServer subclass that bypasses resolve_search_root so find_groups can
  # run without a live SketchUp model. Set @fake_entities to drive the loop.
  class FindGroupsTestServer < TestServer
    attr_accessor :fake_entities
    def resolve_search_root(_model, _parent_id)
      @fake_entities || []
    end
  end
end

class TestFindGroupsOrchestration < Minitest::Test
  include FindGroupsTestSupport

  def make_bounds(*args); FindGroupsTestSupport.make_bounds(*args); end

  def setup
    @server = FindGroupsTestServer.new
  end

  def test_mutual_exclusion_raises_when_both_filters_given
    err = assert_raises(RuntimeError) do
      @server.send(:find_groups,
                   "name_prefix" => "WA", "name_pattern" => "^WA")
    end
    assert_match(/at most one/, err.message)
    assert_match(/name_prefix/, err.message)
    assert_match(/name_pattern/, err.message)
  end

  def test_limit_truncates_at_boundary
    # 5 matching groups, limit=3 — expect exactly 3 returned, truncated=true.
    # If '>= limit' were changed to '> limit', this would return 4.
    @server.fake_entities = (1..5).map { |i| FakeFGFullGroup.new("G#{i}", i) }
    result = @server.send(:find_groups, "limit" => 3)
    assert_equal 3, result[:groups].length
    assert_equal true, result[:truncated]
  end

  def test_limit_not_reached_does_not_truncate
    @server.fake_entities = (1..2).map { |i| FakeFGFullGroup.new("G#{i}", i) }
    result = @server.send(:find_groups, "limit" => 5)
    assert_equal 2, result[:groups].length
    assert_equal false, result[:truncated]
  end

  def test_default_limit_is_200
    # Build 201 matches; the default limit should truncate at 200.
    @server.fake_entities = (1..201).map { |i| FakeFGFullGroup.new("G#{i}", i) }
    result = @server.send(:find_groups, {})
    assert_equal 200, result[:groups].length
    assert_equal true, result[:truncated]
  end

  # -- regression: each filter mode returns non-empty matches when groups exist ---
  # The bug (sch-owl) reported that name_prefix / name_pattern / in_bounds all
  # returned [] in a populated model where matching groups clearly existed.
  # These tests drive the full filter loop against fixture groups to pin each
  # mode end-to-end — not just the per-predicate helpers.

  def test_name_prefix_returns_matching_groups
    @server.fake_entities = [
      FakeFGFullGroup.new("smoke_extrusion", 101),
      FakeFGFullGroup.new("smoke_b1", 102),
      FakeFGFullGroup.new("smoke_b2", 103),
      FakeFGFullGroup.new("other", 999),
    ]
    result = @server.send(:find_groups, "name_prefix" => "smoke")
    names = result[:groups].map { |g| g[:name] }
    assert_equal %w[smoke_extrusion smoke_b1 smoke_b2], names
    assert_equal false, result[:truncated]
  end

  def test_name_pattern_returns_matching_groups
    @server.fake_entities = [
      FakeFGFullGroup.new("smoke_extrusion", 101),
      FakeFGFullGroup.new("smoke_b1", 102),
      FakeFGFullGroup.new("smoke_b2", 103),
      FakeFGFullGroup.new("other", 999),
    ]
    result = @server.send(:find_groups, "name_pattern" => "smoke.*")
    names = result[:groups].map { |g| g[:name] }.sort
    assert_equal %w[smoke_b1 smoke_b2 smoke_extrusion], names
  end

  def test_in_bounds_returns_matching_groups
    @server.fake_entities = [
      FakeFGFullGroup.new("smoke_b1", 102, make_bounds([1040, 0, 0], [1057, 6, 30])),
      FakeFGFullGroup.new("far_away", 999, make_bounds([0, 0, 0], [10, 10, 10])),
    ]
    result = @server.send(:find_groups,
      "in_bounds" => { "min" => [1000, -1, -1], "max" => [1100, 10, 30] })
    names = result[:groups].map { |g| g[:name] }
    assert_equal ["smoke_b1"], names
  end

  # Fixture for nested-group tests: a Group whose .entities returns a
  # provided list (mimics Sketchup::Group#entities for the recursive walker).
  class FakeNestedGroup < FakeFGFullGroup
    def initialize(name, id, children, bounds = nil)
      super(name, id, bounds)
      @children = children
    end
    def entities; @children; end
  end

  def test_recursive_finds_nested_groups
    inner1 = FakeFGFullGroup.new("smoke_b1", 102)
    inner2 = FakeFGFullGroup.new("smoke_b2", 103)
    parent = FakeNestedGroup.new("Container", 1, [inner1, inner2])
    @server.fake_entities = [parent]

    # Non-recursive: only the parent is scanned; smoke_* groups are missed.
    non_rec = @server.send(:find_groups, "name_prefix" => "smoke")
    assert_equal [], non_rec[:groups].map { |g| g[:name] }

    # Recursive: descends into parent.entities, finds both smoke_* groups.
    rec = @server.send(:find_groups, "name_prefix" => "smoke", "recursive" => true)
    assert_equal %w[smoke_b1 smoke_b2], rec[:groups].map { |g| g[:name] }.sort
  end

  def test_each_match_has_full_descriptor
    @server.fake_entities = [
      FakeFGFullGroup.new("smoke_b1", 102, make_bounds([1040, 0, 0], [1057, 6, 30])),
    ]
    result = @server.send(:find_groups, "name_prefix" => "smoke")
    match = result[:groups].first
    assert_equal 102, match[:id]
    assert_equal "smoke_b1", match[:name]
    assert_equal [1040.0, 0.0, 0.0], match[:bounds][:min]
    assert_equal [1057.0, 6.0, 30.0], match[:bounds][:max]
    # layer and material are nullable in the fixture but the keys must exist
    # so consumers can rely on the descriptor shape.
    assert match.key?(:layer)
    assert match.key?(:material)
  end

  def test_include_components_truthiness_coercion
    # Pass a truthy non-boolean — should be coerced to true and include components.
    comp = FakeFGComponent.new
    comp.define_singleton_method(:name) { "C1" }
    comp.define_singleton_method(:entityID) { 42 }
    comp.define_singleton_method(:bounds) { FakeFGBounds.new(FakeFGPoint.new(0, 0, 0), FakeFGPoint.new(1, 1, 1)) }
    comp.define_singleton_method(:layer) { nil }
    comp.define_singleton_method(:material) { nil }
    @server.fake_entities = [comp]
    result = @server.send(:find_groups, "include_components" => "yes")
    assert_equal 1, result[:groups].length

    # Pass nil/false/missing — components excluded.
    @server.fake_entities = [comp]
    result2 = @server.send(:find_groups, "include_components" => nil)
    assert_equal 0, result2[:groups].length

    @server.fake_entities = [comp]
    result3 = @server.send(:find_groups, {})
    assert_equal 0, result3[:groups].length
  end
end
