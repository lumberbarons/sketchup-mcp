require_relative "test_helper"

class TestCalculatePositionOnFace < Minitest::Test
  def setup
    @server = TestServer.new
    @bounds = FakeBounds.new(
      FakePoint.new(0, 0, 0),
      FakePoint.new(10, 20, 30),
      FakePoint.new(5, 10, 15),
    )
    @width   = 4
    @height  = 6
    @depth   = 8
    @ox      = 1
    @oy      = 2
    @oz      = 3
  end

  def position(face)
    @server.send(
      :calculate_position_on_face,
      face, @bounds, @width, @height, @depth, @ox, @oy, @oz
    )
  end

  def test_east_anchors_to_max_x
    assert_equal [10, 10, 15], position(:east)
  end

  def test_west_anchors_to_min_x
    assert_equal [0, 10, 15], position(:west)
  end

  def test_north_anchors_to_max_y
    assert_equal [4, 20, 15], position(:north)
  end

  def test_south_anchors_to_min_y
    assert_equal [4, 0, 15], position(:south)
  end

  def test_top_anchors_to_max_z
    assert_equal [4, 9, 30], position(:top)
  end

  def test_bottom_anchors_to_min_z
    assert_equal [4, 9, 0], position(:bottom)
  end

  # With zero offsets the in-face position should land on the face center
  # (minus half-width / half-height), confirming the offset arithmetic
  # actually depends on the offset args rather than being constant.
  def test_zero_offsets_centers_on_face
    result = @server.send(
      :calculate_position_on_face,
      :east, @bounds, @width, @height, @depth, 0, 0, 0
    )
    assert_equal [10, 10 - @width / 2, 15 - @height / 2], result
  end
end
