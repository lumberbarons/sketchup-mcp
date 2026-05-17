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

  # -- sch-0q8: dimensions fallback for cylinder/sphere/cone ----------------
  # replace_geometry forwards the geometry dict (create_component vocabulary)
  # through this method. Without the fallback, "dimensions" is ignored and
  # radius/height resolve to 0, producing degenerate primitives that raise
  # "Duplicate points in array" inside create_component.

  def test_primitive_dimensions_cylinder_accepts_dimensions
    s = TestServer.new
    op = { "op" => "cylinder", "dimensions" => [4, 4, 6] }
    assert_equal [4, 4, 6], s.send(:primitive_dimensions, op)
  end

  def test_primitive_dimensions_sphere_accepts_dimensions
    s = TestServer.new
    op = { "op" => "sphere", "dimensions" => [6, 6, 6] }
    assert_equal [6, 6, 6], s.send(:primitive_dimensions, op)
  end

  def test_primitive_dimensions_cone_accepts_dimensions
    s = TestServer.new
    op = { "op" => "cone", "dimensions" => [4, 4, 6] }
    assert_equal [4, 4, 6], s.send(:primitive_dimensions, op)
  end

  def test_primitive_dimensions_cylinder_prefers_explicit_dimensions_over_radius
    # If both are present (a caller bridging vocabularies), the explicit
    # dimensions array wins — radius/height are a derivation from it, not
    # the other way around.
    s = TestServer.new
    op = { "op" => "cylinder", "dimensions" => [4, 4, 6], "radius" => 99, "height" => 99 }
    assert_equal [4, 4, 6], s.send(:primitive_dimensions, op)
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
      # Should not raise for the valid op_name…
      s.send(:validate_batch_op, { "op" => op_name }, 0)
      # …and must raise for a perturbed variant. Pairing valid with invalid
      # proves the validator actually distinguishes between them — a no-op
      # validator would pass the first call but fail this assert_raises.
      assert_raises(RuntimeError) do
        s.send(:validate_batch_op, { "op" => "#{op_name}_oops" }, 0)
      end
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
    out = nil
    BatchTestServer.with_model(model) do
      out = server.send(:batch_create,{ "operations" => [{ "op" => "cube", "name" => "A" }] })
    end
    # Pin the exact lifecycle: start with default name → commit. A regression
    # that returns without committing (or without running ops) would slip past
    # a membership-only assertion.
    assert_equal [[:start, "MCP batch", true], [:commit]], model.calls
    assert_equal true, out[:success]
    assert_equal 1, out[:count]
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

    # Pin the exact lifecycle: start → abort, with nothing else. A bug that
    # called abort_operation twice (or any other extra lifecycle call) would
    # slip past a membership-only assertion.
    assert_equal [[:start, "MCP batch", true], [:abort]], model.calls
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

# Records the per-op dispatch in execute_batch_op (the real method, not the
# BatchTestServer stub). Spies on the underlying methods so we can prove
# each op-kind reaches the right one with the right params.
class DispatchSpyServer < TestServer
  attr_reader :calls
  def initialize
    super
    @calls = []
  end
  def create_named_primitive(op)
    @calls << [:create_named_primitive, op]
    { id: 1, success: true }
  end
  def create_extrusion(params)
    @calls << [:create_extrusion, params]
    { id: 2, success: true }
  end
  def transform_component(params)
    @calls << [:transform_component, params]
    { id: 3, success: true }
  end
  def resolve_entity(params, _model = nil)
    @calls << [:resolve_entity, params]
    FakeErasable.new(99)
  end
end

class FakeErasable
  attr_reader :entityID, :erased
  def initialize(id)
    @entityID = id
    @erased = false
  end
  def erase!
    @erased = true
  end
end

class TestExecuteBatchOpDispatch < Minitest::Test
  def setup
    @server = DispatchSpyServer.new
  end

  def test_cube_op_dispatches_to_create_named_primitive
    op = { "op" => "cube", "name" => "Box", "dimensions" => [1, 2, 3] }
    @server.send(:execute_batch_op, op)
    assert_equal [[:create_named_primitive, op]], @server.calls
  end

  def test_cylinder_op_dispatches_to_create_named_primitive
    op = { "op" => "cylinder", "name" => "Cyl", "radius" => 1, "height" => 2 }
    @server.send(:execute_batch_op, op)
    assert_equal [[:create_named_primitive, op]], @server.calls
  end

  def test_sphere_op_dispatches_to_create_named_primitive
    op = { "op" => "sphere", "name" => "Sph", "radius" => 1 }
    @server.send(:execute_batch_op, op)
    assert_equal [[:create_named_primitive, op]], @server.calls
  end

  def test_cone_op_dispatches_to_create_named_primitive
    op = { "op" => "cone", "name" => "Cone", "radius" => 1, "height" => 2 }
    @server.send(:execute_batch_op, op)
    assert_equal [[:create_named_primitive, op]], @server.calls
  end

  def test_extrusion_op_assembles_params_and_calls_create_extrusion
    op = {
      "op" => "extrusion",
      "name" => "Beam",
      "profile" => [[0, 0], [1, 0], [1, 1]],
      "extrude_axis" => "z",
      "extrude_from" => 0,
      "extrude_to" => 5,
      "material" => "wood"
    }
    @server.send(:execute_batch_op, op)
    method, params = @server.calls.first
    assert_equal :create_extrusion, method
    assert_equal "Beam", params["name"]
    assert_equal [[0, 0], [1, 0], [1, 1]], params["profile"]
    assert_equal "z", params["extrude_axis"]
    assert_equal 0, params["extrude_from"]
    assert_equal 5, params["extrude_to"]
    assert_equal "wood", params["material"]
  end

  def test_extrusion_op_omits_material_key_when_absent
    op = {
      "op" => "extrusion",
      "name" => "Beam",
      "profile" => [],
      "extrude_axis" => "z",
      "extrude_from" => 0,
      "extrude_to" => 5
    }
    @server.send(:execute_batch_op, op)
    _method, params = @server.calls.first
    refute params.key?("material"), "material should not be set when absent in op"
  end

  def test_translate_op_dispatches_to_transform_component_with_position
    op = { "op" => "translate", "id_or_name" => "Ridge", "delta" => [1, 0, 0] }
    @server.send(:execute_batch_op, op)
    method, params = @server.calls.first
    assert_equal :transform_component, method
    assert_equal "Ridge", params["name"]
    assert_equal [1, 0, 0], params["position"]
    refute params.key?("move_to"), "translate must not use move_to key"
  end

  # -- sch-gc5: translate accepts "position" + raises on missing field ----

  def test_translate_op_accepts_position_field
    # transform_component's vocabulary uses "position" for relative
    # translation; the translate op should match it so callers don't have
    # to learn a separate vocabulary.
    op = { "op" => "translate", "id_or_name" => "Ridge", "position" => [0, 0, 5] }
    @server.send(:execute_batch_op, op)
    _method, params = @server.calls.first
    assert_equal [0, 0, 5], params["position"]
  end

  def test_translate_op_prefers_position_over_delta
    op = { "op" => "translate", "id_or_name" => "Ridge", "position" => [0, 0, 5], "delta" => [9, 9, 9] }
    @server.send(:execute_batch_op, op)
    _method, params = @server.calls.first
    assert_equal [0, 0, 5], params["position"]
  end

  def test_translate_op_raises_when_position_and_delta_missing
    # Silent no-ops were the prior failure mode (sch-gc5). Surface the
    # error so the caller knows their op didn't apply.
    op = { "op" => "translate", "id_or_name" => "Ridge" }
    err = assert_raises(RuntimeError) { @server.send(:execute_batch_op, op) }
    assert_match(/position/, err.message)
  end

  def test_move_to_op_dispatches_to_transform_component_with_move_to
    op = { "op" => "move_to", "id_or_name" => 42, "target" => [5, 5, 5] }
    @server.send(:execute_batch_op, op)
    method, params = @server.calls.first
    assert_equal :transform_component, method
    assert_equal 42, params["id"]
    assert_equal [5, 5, 5], params["move_to"]
    refute params.key?("position"), "move_to must not use position key"
  end

  def test_delete_op_resolves_entity_and_erases
    op = { "op" => "delete", "id_or_name" => "Old" }
    result = @server.send(:execute_batch_op, op)
    assert_equal [:resolve_entity, { "name" => "Old" }], @server.calls.first
    assert_equal 99, result[:id]
    assert_equal true, result[:success]
  end

  # -- sch-i7a: sub-ops accept "id"/"name" directly -------------------------

  def test_translate_op_accepts_name_directly
    op = { "op" => "translate", "name" => "Ridge", "position" => [1, 0, 0] }
    @server.send(:execute_batch_op, op)
    _method, params = @server.calls.first
    assert_equal "Ridge", params["name"]
    refute params.key?("id_or_name"), "id_or_name should not leak into transform_component params"
  end

  def test_translate_op_accepts_id_directly
    op = { "op" => "translate", "id" => 42, "position" => [1, 0, 0] }
    @server.send(:execute_batch_op, op)
    _method, params = @server.calls.first
    assert_equal 42, params["id"]
  end

  def test_move_to_op_accepts_name_directly
    op = { "op" => "move_to", "name" => "Beam", "target" => [5, 5, 5] }
    @server.send(:execute_batch_op, op)
    _method, params = @server.calls.first
    assert_equal "Beam", params["name"]
    assert_equal [5, 5, 5], params["move_to"]
  end

  def test_delete_op_accepts_id_directly
    op = { "op" => "delete", "id" => 99 }
    @server.send(:execute_batch_op, op)
    assert_equal [:resolve_entity, { "id" => 99 }], @server.calls.first
  end

  def test_addressing_raises_when_no_id_name_or_id_or_name
    op = { "op" => "delete" }
    err = assert_raises(RuntimeError) { @server.send(:execute_batch_op, op) }
    assert_match(/'id'|'name'/, err.message)
  end

  def test_addressing_prefers_id_over_id_or_name
    # If both are supplied, "id" wins. Keeps the alias from silently
    # overriding the canonical field.
    op = { "op" => "translate", "id" => 7, "id_or_name" => "Other", "position" => [0, 0, 1] }
    @server.send(:execute_batch_op, op)
    _method, params = @server.calls.first
    assert_equal 7, params["id"]
    refute params.key?("name")
  end
end
