require_relative "test_helper"

# Pure helpers extracted from create_dovetail to keep the runtime
# 'Duplicate points in array' regression from coming back: the validator
# catches degenerate parameter combos up-front, and dedupe_points strips
# near-coincident vertices before they reach SketchUp's add_face.

class TestDovetailValidation < Minitest::Test
  def setup
    @server = TestServer.new
  end

  def call(width:, height:, depth:, angle:, num_tails:)
    @server.send(:validate_dovetail_geometry!, width, height, depth, angle, num_tails)
  end

  def test_accepts_current_defaults
    # Must not raise; current Go defaults (width=2, height=2, depth=0.25,
    # angle=15, num_tails=3) were chosen specifically so the no-other-args
    # call produces a buildable trapezoid. Pin them.
    call(width: 2.0, height: 2.0, depth: 0.25, angle: 15.0, num_tails: 3)
  end

  def test_rejects_legacy_defaults_that_were_the_bug
    # The pre-fix defaults (width=1, depth=1, num_tails=3, angle=15) flared
    # the tail bottom past the per-tail spacing — the trapezoid that
    # produced 'Duplicate points in array' in the wild. Keep this guard.
    err = assert_raises(RuntimeError) do
      call(width: 1.0, height: 1.0, depth: 1.0, angle: 15.0, num_tails: 3)
    end
    assert_match(/tail width too small/, err.message)
  end

  def test_rejects_zero_num_tails
    err = assert_raises(RuntimeError) { call(width: 1, height: 1, depth: 1, angle: 15, num_tails: 0) }
    assert_match(/num_tails/, err.message)
  end

  def test_rejects_non_positive_width
    err = assert_raises(RuntimeError) { call(width: 0, height: 1, depth: 1, angle: 15, num_tails: 3) }
    assert_match(/width/, err.message)
  end

  def test_rejects_non_positive_height
    err = assert_raises(RuntimeError) { call(width: 1, height: 0, depth: 1, angle: 15, num_tails: 3) }
    assert_match(/height/, err.message)
  end

  def test_rejects_non_positive_depth
    err = assert_raises(RuntimeError) { call(width: 1, height: 1, depth: 0, angle: 15, num_tails: 3) }
    assert_match(/depth/, err.message)
  end

  def test_rejects_angle_out_of_range
    err = assert_raises(RuntimeError) { call(width: 1, height: 1, depth: 1, angle: 90, num_tails: 3) }
    assert_match(/angle/, err.message)
    err2 = assert_raises(RuntimeError) { call(width: 1, height: 1, depth: 1, angle: 0, num_tails: 3) }
    assert_match(/angle/, err2.message)
  end

  def test_rejects_geometry_with_overflowing_tail_flare
    # depth=10 with the default angle pushes the bottom width past the
    # spacing budget — the message must tell the caller which knob to turn.
    err = assert_raises(RuntimeError) do
      call(width: 1.0, height: 1.0, depth: 10.0, angle: 15.0, num_tails: 5)
    end
    assert_match(/num_tails=5/, err.message)
    assert_match(/depth=10\.0/, err.message)
  end

  # -- dedupe_points -----------------------------------------------------

  def test_dedupe_passes_through_distinct_points
    pts = [[0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0]]
    assert_equal pts, @server.send(:dedupe_points, pts)
  end

  def test_dedupe_drops_near_coincident_points
    pts = [
      [0.0, 0.0, 0.0],
      [1.0, 0.0, 0.0],
      [1.0, 0.0, 0.000000001], # within default epsilon of the previous
      [0.0, 1.0, 0.0],
    ]
    deduped = @server.send(:dedupe_points, pts)
    assert_equal 3, deduped.length
  end

  def test_dedupe_drops_exact_duplicates
    pts = [[0, 0, 0], [1, 0, 0], [1, 0, 0], [1, 1, 0]]
    assert_equal [[0, 0, 0], [1, 0, 0], [1, 1, 0]],
                 @server.send(:dedupe_points, pts)
  end

  def test_dedupe_keeps_distant_third_axis
    # Points only differ on z — must not be deduped.
    pts = [[0, 0, 0], [0, 0, 1], [0, 0, 2]]
    assert_equal pts, @server.send(:dedupe_points, pts)
  end
end
