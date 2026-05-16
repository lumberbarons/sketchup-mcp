require_relative "test_helper"

# Validator extracted from create_finger_joint so that the no-other-args
# call against two cubes succeeds rather than failing inside SketchUp with
# the cryptic 'Duplicate points in array' message.

class TestFingerJointValidation < Minitest::Test
  def setup
    @server = TestServer.new
  end

  def call(width:, height:, depth:, num_fingers:)
    @server.send(:validate_finger_joint_geometry!, width, height, depth, num_fingers)
  end

  def test_accepts_current_defaults
    # width=2, num_fingers=5 → slot_width = 2/9 ≈ 0.22, well above the
    # build-safe floor. Pin so default tuning doesn't drift back below it.
    call(width: 2.0, height: 2.0, depth: 1.0, num_fingers: 5)
  end

  def test_rejects_zero_num_fingers
    err = assert_raises(RuntimeError) { call(width: 1, height: 1, depth: 1, num_fingers: 0) }
    assert_match(/num_fingers/, err.message)
  end

  def test_rejects_non_positive_width
    err = assert_raises(RuntimeError) { call(width: 0, height: 1, depth: 1, num_fingers: 5) }
    assert_match(/width/, err.message)
  end

  def test_rejects_non_positive_height
    err = assert_raises(RuntimeError) { call(width: 1, height: 0, depth: 1, num_fingers: 5) }
    assert_match(/height/, err.message)
  end

  def test_rejects_non_positive_depth
    err = assert_raises(RuntimeError) { call(width: 1, height: 1, depth: 0, num_fingers: 5) }
    assert_match(/depth/, err.message)
  end

  def test_rejects_slot_width_below_build_floor
    # width = 1e-5, num_fingers = 5 → slot_width ≈ 1.1e-6, below the 1e-4
    # floor. The error must name both knobs the caller can adjust.
    err = assert_raises(RuntimeError) do
      call(width: 1.0e-5, height: 1.0, depth: 1.0, num_fingers: 5)
    end
    assert_match(/num_fingers/, err.message)
    assert_match(/width/, err.message)
  end
end
