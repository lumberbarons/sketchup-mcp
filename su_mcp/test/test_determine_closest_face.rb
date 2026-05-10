require_relative "test_helper"

class TestDetermineClosestFace < Minitest::Test
  def setup
    @server = TestServer.new
  end

  def closest(x, y, z)
    @server.send(:determine_closest_face, FakeVector.new(x, y, z))
  end

  def test_positive_x_axis_is_east
    assert_equal :east, closest(1, 0, 0)
  end

  def test_negative_x_axis_is_west
    assert_equal :west, closest(-1, 0, 0)
  end

  def test_positive_y_axis_is_north
    assert_equal :north, closest(0, 1, 0)
  end

  def test_negative_y_axis_is_south
    assert_equal :south, closest(0, -1, 0)
  end

  def test_positive_z_axis_is_top
    assert_equal :top, closest(0, 0, 1)
  end

  def test_negative_z_axis_is_bottom
    assert_equal :bottom, closest(0, 0, -1)
  end

  def test_off_axis_picks_dominant_component
    assert_equal :east,  closest(3, 1, 1)
    assert_equal :north, closest(1, 3, 1)
    assert_equal :top,   closest(1, 1, 3)
  end

  # Ties are resolved deterministically by the order of the if/elsif chain:
  # x wins over y, y wins over z. Lock that behavior so refactors don't
  # accidentally flip a tie's outcome.
  def test_xy_tie_picks_x
    assert_equal :east, closest(1, 1, 0)
    assert_equal :west, closest(-1, 1, 0)
  end

  def test_yz_tie_picks_y
    assert_equal :north, closest(0, 1, 1)
    assert_equal :south, closest(0, -1, 1)
  end

  def test_normalize_is_called_on_input
    v = FakeVector.new(3, 0, 0)
    @server.send(:determine_closest_face, v)
    assert_in_delta 1.0, v.x, 1e-9
  end
end
