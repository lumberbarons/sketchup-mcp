require_relative "test_helper"

# Regression test for sch-9d9: replace_geometry must wrap its erase+rebuild
# pair in a SketchUp operation so a failure during build leaves the original
# target Group intact (target.erase! gets rolled back by abort_operation).
#
# We can't run the real construction path without a live SU model, but we
# can install a fake Sketchup.active_model that records operation calls,
# returns a fake target Group from find_entity_by_id, and forces the inner
# build to fail by raising from active_entities (which create_component
# reads on its first line). The contract being tested: a failing build
# triggers abort_operation, not commit_operation, and the exception
# propagates so the caller sees the failure.

class FakeReplaceTargetGroup
  attr_reader :erased

  def initialize
    @erased = false
  end

  def is_a?(klass)
    return true if klass == Sketchup::Group
    super
  end

  def name
    "smk_cube"
  end

  def material
    nil
  end

  def respond_to?(method_name, include_private = false)
    return true if %i[layer name material erase!].include?(method_name.to_sym)
    super
  end

  def layer
    nil
  end

  def entities
    fake = Object.new
    def fake.grep(_klass); []; end
    fake
  end

  def erase!
    @erased = true
  end
end

class FakeReplaceModel
  attr_reader :operations

  def initialize(group)
    @operations = []
    @group = group
  end

  def start_operation(name, _disable_ui = false)
    @operations << [:start, name]
  end

  def commit_operation
    @operations << [:commit]
  end

  def abort_operation
    @operations << [:abort]
  end

  def find_entity_by_id(_id)
    @group
  end

  def active_entities
    # Force a failure inside build_replacement_group → create_named_primitive
    # → create_component, which calls model.active_entities on its first line.
    raise "boom in active_entities"
  end
end

class TestReplaceGeometryTransaction < Minitest::Test
  def setup
    @server = TestServer.new
    @group = FakeReplaceTargetGroup.new
    @model = FakeReplaceModel.new(@group)
    @original_active_model = Sketchup.method(:active_model)
    Sketchup.define_singleton_method(:active_model) { @_fake_replace_model }
    Sketchup.instance_variable_set(:@_fake_replace_model, @model)
  end

  def teardown
    orig = @original_active_model
    Sketchup.define_singleton_method(:active_model) { orig.call }
  end

  def test_replace_geometry_aborts_on_build_failure
    params = {
      "id" => 42,
      "geometry" => { "type" => "cube", "position" => [0, 0, 0], "dimensions" => [1, 1, 1] }
    }

    err = assert_raises(RuntimeError) { @server.send(:replace_geometry, params) }
    assert_match(/boom in active_entities/, err.message)

    assert_equal [:start, "Replace geometry"], @model.operations.first,
      "expected replace_geometry to open a SU operation before mutating the model"
    assert_equal [:abort], @model.operations.last,
      "expected replace_geometry to abort the SU operation when the build fails"
    refute_includes @model.operations, [:commit],
      "build failure must not reach commit_operation"
  end
end
