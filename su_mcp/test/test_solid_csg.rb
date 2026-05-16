require_relative "test_helper"

# Validation paths for the solid_csg helper shared by boolean_operation
# and the joinery handlers. The real Solid Tools call requires SU Pro
# and a live model, so we only exercise the rejection branches that fire
# before the actual API call.

class FakeGroup < Sketchup::Group
  attr_reader :calls
  attr_accessor :manifold_value, :subtract_response

  def initialize(manifold: true)
    @manifold_value = manifold
    @subtract_response = nil
    @calls = []
  end

  def manifold?; @manifold_value; end

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
  end

  def test_rejects_non_manifold_tool
    err = assert_raises(RuntimeError) do
      @server.send(:solid_csg, FakeGroup.new, FakeGroup.new(manifold: false), :subtract)
    end
    assert_match(/manifold/, err.message)
  end

  def test_raises_when_solid_tools_returns_nil
    target = FakeGroup.new
    target.subtract_response = nil
    err = assert_raises(RuntimeError) do
      @server.send(:solid_csg, target, FakeGroup.new, :subtract)
    end
    assert_match(/returned nil/, err.message)
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
