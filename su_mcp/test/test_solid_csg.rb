require_relative "test_helper"

# Validation paths for the solid_csg helper shared by boolean_operation
# and the joinery handlers. The real Solid Tools call requires SU Pro
# and a live model, so we only exercise the rejection branches that fire
# before the actual API call.

class FakeGroup < Sketchup::Group
  attr_reader :calls
  attr_accessor :manifold_value, :subtract_response, :valid_value

  def initialize(manifold: true, valid: true)
    @manifold_value = manifold
    @valid_value = valid
    @subtract_response = nil
    @calls = []
  end

  def manifold?; @manifold_value; end
  def valid?; @valid_value; end

  def union(other); record(:union, other); end
  def subtract(other); record(:subtract, other); end
  def intersect(other); record(:intersect, other); end

  private

  def record(op, other)
    @calls << [op, other]
    @subtract_response
  end
end

class TestSolidCsg < Minitest::Test
  def setup
    @server = TestServer.new
  end

  def test_rejects_non_group_target
    err = assert_raises(RuntimeError) do
      @server.send(:solid_csg, Object.new, FakeGroup.new, :subtract)
    end
    assert_match(/two Sketchup::Group inputs/, err.message)
  end

  def test_rejects_non_group_tool
    err = assert_raises(RuntimeError) do
      @server.send(:solid_csg, FakeGroup.new, Object.new, :subtract)
    end
    assert_match(/two Sketchup::Group inputs/, err.message)
  end

  def test_rejects_non_manifold_target
    target = FakeGroup.new(manifold: false)
    err = assert_raises(RuntimeError) do
      @server.send(:solid_csg, target, FakeGroup.new, :subtract)
    end
    assert_match(/manifold/, err.message)
    # Error must name which side failed (sch-zwk) — bare "non-manifold" without
    # the side label sent debuggers chasing both operands.
    assert_match(/target/, err.message)
  end

  def test_rejects_non_manifold_tool
    err = assert_raises(RuntimeError) do
      @server.send(:solid_csg, FakeGroup.new, FakeGroup.new(manifold: false), :subtract)
    end
    assert_match(/manifold/, err.message)
    assert_match(/tool/, err.message)
  end

  def test_names_both_sides_when_both_non_manifold
    bad_target = FakeGroup.new(manifold: false)
    bad_tool = FakeGroup.new(manifold: false)
    err = assert_raises(RuntimeError) do
      @server.send(:solid_csg, bad_target, bad_tool, :subtract)
    end
    assert_match(/target/, err.message)
    assert_match(/tool/, err.message)
  end

  def test_raises_when_solid_tools_returns_nil
    target = FakeGroup.new
    target.subtract_response = nil
    err = assert_raises(RuntimeError) do
      @server.send(:solid_csg, target, FakeGroup.new, :subtract)
    end
    assert_match(/returned nil/, err.message)
  end

  def test_rejects_deleted_target
    target = FakeGroup.new(valid: false)
    err = assert_raises(RuntimeError) do
      @server.send(:solid_csg, target, FakeGroup.new, :subtract)
    end
    assert_match(/deleted/, err.message)
    assert_match(/target/, err.message)
  end

  def test_rejects_deleted_tool
    err = assert_raises(RuntimeError) do
      @server.send(:solid_csg, FakeGroup.new, FakeGroup.new(valid: false), :subtract)
    end
    assert_match(/deleted/, err.message)
    assert_match(/tool/, err.message)
  end

  def test_returns_result_group_on_success
    target = FakeGroup.new
    expected = FakeGroup.new
    target.subtract_response = expected
    result = @server.send(:solid_csg, target, FakeGroup.new, :subtract)
    assert_same expected, result
    assert_equal :subtract, target.calls.first[0]
  end
end
