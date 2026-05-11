require_relative "test_helper"

# Fakes for resolve_entity. FakeGroup inherits Sketchup::Group so
# entities.grep(Sketchup::Group) selects them via Array#grep === Class#===.
class FakeGroup < Sketchup::Group
  attr_reader :name, :entityID

  def initialize(name, entity_id)
    @name = name
    @entityID = entity_id
  end
end

class FakeEntities
  def initialize(arr)
    @arr = arr
  end

  def grep(klass)
    @arr.grep(klass)
  end
end

class FakeModel
  attr_reader :entities

  def initialize(entities)
    @entities = FakeEntities.new(entities)
    @by_id = entities.each_with_object({}) { |e, h| h[e.entityID] = e if e.respond_to?(:entityID) }
  end

  def find_entity_by_id(id)
    @by_id[id]
  end
end

class TestResolveEntity < Minitest::Test
  def setup
    @server = TestServer.new
  end

  def test_resolves_by_id
    g = FakeGroup.new("Ridge", 42)
    model = FakeModel.new([g])
    assert_same g, @server.send(:resolve_entity,{ "id" => 42 }, model)
  end

  def test_id_strips_quotes
    # Legacy clients sometimes send IDs as quoted strings; matches existing
    # behavior of the old delete_component / transform_component code paths.
    g = FakeGroup.new("Ridge", 42)
    model = FakeModel.new([g])
    assert_same g, @server.send(:resolve_entity,{ "id" => '"42"' }, model)
  end

  def test_id_not_found_raises
    model = FakeModel.new([])
    err = assert_raises(RuntimeError) { @server.send(:resolve_entity,{ "id" => 99 }, model) }
    assert_match(/Entity not found/, err.message)
    assert_match(/99/, err.message)
  end

  def test_resolves_by_unique_name
    a = FakeGroup.new("Rafter W 5", 10)
    b = FakeGroup.new("Ridge", 11)
    model = FakeModel.new([a, b])
    assert_same b, @server.send(:resolve_entity,{ "name" => "Ridge" }, model)
  end

  def test_name_no_match_raises
    model = FakeModel.new([FakeGroup.new("Ridge", 11)])
    err = assert_raises(RuntimeError) do
      @server.send(:resolve_entity,{ "name" => "Missing" }, model)
    end
    assert_match(/No group/, err.message)
    assert_match(/"Missing"/, err.message)
  end

  def test_name_ambiguous_raises_with_ids
    a = FakeGroup.new("Rafter", 7)
    b = FakeGroup.new("Rafter", 8)
    c = FakeGroup.new("Ridge", 9)
    model = FakeModel.new([a, b, c])
    err = assert_raises(RuntimeError) do
      @server.send(:resolve_entity,{ "name" => "Rafter" }, model)
    end
    assert_match(/Multiple groups/, err.message)
    assert_match(/"Rafter"/, err.message)
    assert_match(/7/, err.message)
    assert_match(/8/, err.message)
  end

  def test_name_ignores_non_groups
    # Entities that aren't Sketchup::Group instances must not be considered
    # for name matching. Faces / edges / etc. typically have no `.name` and
    # would crash select{} if leaked through.
    other = Object.new
    g = FakeGroup.new("Ridge", 11)
    model = FakeModel.new([other, g])
    assert_same g, @server.send(:resolve_entity,{ "name" => "Ridge" }, model)
  end

  def test_both_id_and_name_raises
    model = FakeModel.new([])
    err = assert_raises(RuntimeError) do
      @server.send(:resolve_entity,{ "id" => 1, "name" => "Ridge" }, model)
    end
    assert_match(/exactly one/, err.message)
    assert_match(/not both/, err.message)
  end

  def test_neither_id_nor_name_raises
    model = FakeModel.new([])
    err = assert_raises(RuntimeError) { @server.send(:resolve_entity,{}, model) }
    assert_match(/exactly one/, err.message)
    refute_match(/not both/, err.message)
  end

  def test_blank_string_treated_as_missing
    # An empty-string name (or id) should be treated as not-provided so that
    # callers don't accidentally trigger a lookup with "" against every group.
    model = FakeModel.new([FakeGroup.new("", 1)])
    err = assert_raises(RuntimeError) do
      @server.send(:resolve_entity,{ "name" => "" }, model)
    end
    assert_match(/exactly one/, err.message)
  end

  def test_nil_values_treated_as_missing
    model = FakeModel.new([])
    err = assert_raises(RuntimeError) do
      @server.send(:resolve_entity,{ "id" => nil, "name" => nil }, model)
    end
    assert_match(/exactly one/, err.message)
  end
end
