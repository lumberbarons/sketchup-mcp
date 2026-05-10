require_relative "test_helper"

class TestCalculatePositionOnFace < Minitest::Test
  def setup
    @server = TestServer.new
    @bounds = FakeBounds.new(
      FakePoint.new(0, 0, 0),
      FakePoint.new(10, 20, 30),
      FakePoint.new(5, 10, 15),
    )
    # Fixtures are picked so width/2 != oy and height/2 != oz: every
    # in-face coordinate differs from the corresponding bounds.center
    # value, so dropping the offset arithmetic in production breaks at
    # least one assertion per direction.
    @width   = 4
    @height  = 6
    @depth   = 8
    @ox      = 5
    @oy      = 7
    @oz      = 11
  end

  def position(face)
    @server.send(
      :calculate_position_on_face,
      face, @bounds, @width, @height, @depth, @ox, @oy, @oz
    )
  end

  def test_east_anchors_to_max_x
    assert_equal [10, 15, 23], position(:east)
  end

  def test_west_anchors_to_min_x
    assert_equal [0, 15, 23], position(:west)
  end

  def test_north_anchors_to_max_y
    assert_equal [8, 20, 23], position(:north)
  end

  def test_south_anchors_to_min_y
    assert_equal [8, 0, 23], position(:south)
  end

  def test_top_anchors_to_max_z
    assert_equal [8, 14, 30], position(:top)
  end

  def test_bottom_anchors_to_min_z
    assert_equal [8, 14, 0], position(:bottom)
  end

  # With zero offsets each in-face coordinate equals
  # `bounds.center - dim/2` on the two non-anchored axes; the anchored
  # axis equals max or min on that axis. Covering all six directions
  # ensures dropping a `- width/2` or `- height/2` term in any branch
  # of main.rb's case statement breaks at least one assertion.
  def test_zero_offsets_centers_on_face_for_all_directions
    expected = {
      east:   [10, 10 - @width / 2, 15 - @height / 2],
      west:   [0,  10 - @width / 2, 15 - @height / 2],
      north:  [5  - @width / 2, 20, 15 - @height / 2],
      south:  [5  - @width / 2, 0,  15 - @height / 2],
      top:    [5  - @width / 2, 10 - @height / 2, 30],
      bottom: [5  - @width / 2, 10 - @height / 2, 0],
    }

    expected.each do |direction, expected_position|
      result = @server.send(
        :calculate_position_on_face,
        direction, @bounds, @width, @height, @depth, 0, 0, 0
      )
      assert_equal expected_position, result, "zero-offset position for #{direction.inspect}"
    end
  end

  def test_unknown_direction_raises_argument_error
    error = assert_raises(ArgumentError) { position(:nowhere) }
    assert_match(/face_direction/, error.message)
  end
end
