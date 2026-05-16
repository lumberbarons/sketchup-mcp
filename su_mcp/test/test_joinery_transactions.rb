require_relative "test_helper"

# Regression tests for sch-8hw: joinery handlers must wrap their work in a
# SketchUp model.start_operation/commit_operation/abort_operation pair so
# that any orphan scratch Groups created before a failure are rolled back.
#
# We can't run real Solid Tools without SU Pro + a live model, but we can
# install a fake Sketchup.active_model that records operation calls and
# force the handler to fail early (missing entity). The contract being
# tested: every joinery handler that raises also calls abort_operation,
# leaving the transaction balanced.

class FakeJoineryModel
  attr_reader :operations

  def initialize
    @operations = []
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
    nil
  end

  def active_entities
    raise "active_entities should not be reached when the handler fails on missing entities"
  end
end

class TestJoineryTransactions < Minitest::Test
  def setup
    @server = TestServer.new
    @model = FakeJoineryModel.new
    @original_active_model = Sketchup.method(:active_model)
    Sketchup.define_singleton_method(:active_model) { @_fake_joinery_model }
    Sketchup.instance_variable_set(:@_fake_joinery_model, @model)
  end

  def teardown
    orig = @original_active_model
    Sketchup.define_singleton_method(:active_model) { orig.call }
  end

  def test_create_mortise_tenon_aborts_on_missing_entity
    assert_raises(RuntimeError) do
      @server.send(:create_mortise_tenon, "mortise_id" => "1", "tenon_id" => "2")
    end
    assert_equal [:start, "MortiseTenon"], @model.operations.first
    assert_equal [:abort], @model.operations.last
    refute_includes @model.operations, [:commit]
  end

  def test_create_dovetail_aborts_on_missing_entity
    assert_raises(RuntimeError) do
      @server.send(:create_dovetail, "tail_id" => "1", "pin_id" => "2")
    end
    assert_equal [:start, "Dovetail"], @model.operations.first
    assert_equal [:abort], @model.operations.last
    refute_includes @model.operations, [:commit]
  end

  def test_create_finger_joint_aborts_on_missing_entity
    assert_raises(RuntimeError) do
      @server.send(:create_finger_joint, "board1_id" => "1", "board2_id" => "2")
    end
    assert_equal [:start, "FingerJoint"], @model.operations.first
    assert_equal [:abort], @model.operations.last
    refute_includes @model.operations, [:commit]
  end
end
