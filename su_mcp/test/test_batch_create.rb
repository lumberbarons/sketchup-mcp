require_relative "test_helper"

# Records start/commit/abort calls so we can prove the transaction lifecycle
# is exactly start → (commit | abort) for every batch outcome.
class StubModel
  attr_reader :calls

  def initialize
    @calls = []
  end

  def start_operation(name, disable_ui)
    @calls << [:start, name, disable_ui]
  end

  def commit_operation
    @calls << [:commit]
  end

  def abort_operation
    @calls << [:abort]
  end

  # Plumbed in case batch_create reaches model.find_entity_by_id for a
  # delete op — tests that exercise deletes provide their own model.
  def find_entity_by_id(_id); nil; end
end

# A Server variant that bypasses every real SketchUp call inside
# execute_batch_op so we can drive the transaction loop deterministically.
# The stub records each op it sees, and can be configured to raise on the
# Nth op so we can verify abort-on-failure behavior.
class BatchTestServer < TestServer
  attr_accessor :raise_on_op_index
  attr_reader :executed_ops

  def initialize(model)
    super()
    @model = model
    @raise_on_op_index = nil
    @executed_ops = []
  end

  def execute_batch_op(op)
    i = @executed_ops.length
    @executed_ops << op
    raise "boom on op #{i}" if @raise_on_op_index == i
    { id: 1000 + i, name: op["name"] || "stub", success: true }
  end

  # Make Sketchup.active_model resolve to our stub during the test.
  def self.with_model(model)
    Sketchup.singleton_class.send(:define_method, :active_model) { model }
    yield
  ensure
    Sketchup.singleton_class.send(:define_method, :active_model) { nil }
  end
end

class TestBatchCreate < Minitest::Test
  # -- id_or_name_params (pure) --------------------------------------------

  def test_id_or_name_integer_becomes_id
    s = TestServer.new
    assert_equal({ "id" => 42 }, s.send(:id_or_name_params, 42))
  end

  def test_id_or_name_string_becomes_name
    s = TestServer.new
    assert_equal({ "name" => "Ridge" }, s.send(:id_or_name_params, "Ridge"))
  end

  def test_id_or_name_numeric_string_is_still_a_name
    # The bead's contract: Integer → id, String → name. A "42" string is a
    # name, not an id. Locks this so a "smart" string→int coercion can't
    # silently break name lookups for groups that happen to be named "1".
    s = TestServer.new
    assert_equal({ "name" => "42" }, s.send(:id_or_name_params, "42"))
  end

  def test_id_or_name_other_types_raise
    s = TestServer.new
    assert_raises(RuntimeError) { s.send(:id_or_name_params, nil) }
    assert_raises(RuntimeError) { s.send(:id_or_name_params, [1, 2]) }
  end

  # -- primitive_dimensions (pure) -----------------------------------------

  def test_primitive_dimensions_cube_passes_dimensions_through
    s = TestServer.new
    op = { "op" => "cube", "dimensions" => [3, 4, 5] }
    assert_equal [3, 4, 5], s.send(:primitive_dimensions, op)
  end

  def test_primitive_dimensions_cylinder_doubles_radius_for_xy
    s = TestServer.new
    op = { "op" => "cylinder", "radius" => 2.5, "height" => 10 }
    assert_equal [5.0, 5.0, 10.0], s.send(:primitive_dimensions, op)
  end

  def test_primitive_dimensions_sphere_uses_diameter_for_all_axes
    s = TestServer.new
    op = { "op" => "sphere", "radius" => 3 }
    assert_equal [6.0, 6.0, 6.0], s.send(:primitive_dimensions, op)
  end

  def test_primitive_dimensions_cone_matches_cylinder
    s = TestServer.new
    op = { "op" => "cone", "radius" => 1, "height" => 4 }
    assert_equal [2.0, 2.0, 4.0], s.send(:primitive_dimensions, op)
  end

  # -- validate_batch_op ----------------------------------------------------

  def test_validate_rejects_non_hash
    s = TestServer.new
    err = assert_raises(RuntimeError) { s.send(:validate_batch_op, "not a hash", 0) }
    assert_match(/must be a Hash/, err.message)
  end

  def test_validate_rejects_unknown_op
    s = TestServer.new
    err = assert_raises(RuntimeError) do
      s.send(:validate_batch_op, { "op" => "teleport" }, 3)
    end
    assert_match(/operation #3/, err.message)
    assert_match(/teleport/, err.message)
  end

  def test_validate_accepts_every_known_op
    s = TestServer.new
    %w[cube cylinder sphere cone extrusion translate move_to delete].each do |op_name|
      # Should not raise.
      s.send(:validate_batch_op, { "op" => op_name }, 0)
    end
  end

  # -- transaction lifecycle (integration via StubModel) -------------------

  def test_successful_batch_calls_start_then_commit
    model = StubModel.new
    server = BatchTestServer.new(model)
    BatchTestServer.with_model(model) do
      out = server.send(:batch_create,{
                                  "transaction_name" => "Roof pass",
                                  "operations" => [
                                    { "op" => "cube", "name" => "A" },
                                    { "op" => "cube", "name" => "B" }
                                  ]
                                })
      assert_equal true, out[:success]
      assert_equal 2, out[:count]
      assert_equal 2, out[:results].length
    end
    assert_equal [[:start, "Roof pass", true], [:commit]], model.calls
  end

  def test_default_transaction_name
    model = StubModel.new
    server = BatchTestServer.new(model)
    BatchTestServer.with_model(model) do
      server.send(:batch_create,{ "operations" => [{ "op" => "cube", "name" => "A" }] })
    end
    assert_equal "MCP batch", model.calls.first[1]
  end

  def test_failed_op_aborts_transaction_and_no_commit
    model = StubModel.new
    server = BatchTestServer.new(model)
    server.raise_on_op_index = 2  # third op blows up

    BatchTestServer.with_model(model) do
      err = assert_raises(RuntimeError) do
        server.send(:batch_create,{
                              "operations" => [
                                { "op" => "cube", "name" => "A" },
                                { "op" => "cube", "name" => "B" },
                                { "op" => "cube", "name" => "C" },
                                { "op" => "cube", "name" => "D" }
                              ]
                            })
      end
      assert_match(/operation #2/, err.message)
      assert_match(/"cube"/, err.message)
      # Two ops completed before the failure — message should say so.
      assert_match(/2 prior op\(s\) rolled back/, err.message)
    end

    # Critical: start fires, abort fires, commit MUST NOT fire. If anyone
    # ever swaps the order or forgets the rescue, the model would commit a
    # half-built batch.
    assert_equal :start, model.calls.first[0]
    assert_includes model.calls.map(&:first), :abort
    refute_includes model.calls.map(&:first), :commit
  end

  def test_failure_on_first_op_still_aborts
    model = StubModel.new
    server = BatchTestServer.new(model)
    server.raise_on_op_index = 0

    BatchTestServer.with_model(model) do
      err = assert_raises(RuntimeError) do
        server.send(:batch_create,{ "operations" => [{ "op" => "cube", "name" => "A" }] })
      end
      assert_match(/operation #0/, err.message)
      assert_match(/0 prior op\(s\) rolled back/, err.message)
    end

    assert_equal [[:start, "MCP batch", true], [:abort]], model.calls
  end

  def test_results_preserved_in_input_order
    model = StubModel.new
    server = BatchTestServer.new(model)
    BatchTestServer.with_model(model) do
      out = server.send(:batch_create,{
                                  "operations" => [
                                    { "op" => "cube", "name" => "First" },
                                    { "op" => "cube", "name" => "Second" },
                                    { "op" => "cube", "name" => "Third" }
                                  ]
                                })
      assert_equal %w[First Second Third], out[:results].map { |r| r[:name] }
    end
  end

  # -- pre-flight validation runs BEFORE start_operation -------------------

  def test_invalid_op_in_array_blocks_transaction_entirely
    # If validation catches a malformed op, we should never call
    # start_operation — there's nothing to roll back.
    model = StubModel.new
    server = BatchTestServer.new(model)
    BatchTestServer.with_model(model) do
      assert_raises(RuntimeError) do
        server.send(:batch_create,{
                              "operations" => [
                                { "op" => "cube", "name" => "A" },
                                { "op" => "teleport" }  # unknown
                              ]
                            })
      end
    end
    # No transaction lifecycle calls at all — bad input never gets to start.
    assert_empty model.calls
  end

  def test_operations_must_be_an_array
    model = StubModel.new
    server = BatchTestServer.new(model)
    BatchTestServer.with_model(model) do
      err = assert_raises(RuntimeError) do
        server.send(:batch_create,{ "operations" => "not an array" })
      end
      assert_match(/operations.*array/i, err.message)
    end
    assert_empty model.calls
  end
end
