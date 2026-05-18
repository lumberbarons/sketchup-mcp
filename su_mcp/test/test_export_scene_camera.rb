require_relative "test_helper"

# Pure-helper tests for SU_MCP::Server.parse_camera_params. The surrounding
# export_scene orchestration calls Sketchup::Camera.new, Geom::Point3d.new,
# and view.camera=, which need a live SketchUp; the input validation and
# default-filling is pure data and is where bugs would hide.

class TestExportSceneCameraParser < Minitest::Test
  def parse(camera)
    SU_MCP::Server.parse_camera_params(camera)
  end

  def test_returns_nil_when_camera_absent
    assert_nil parse(nil)
  end

  def test_rejects_non_hash
    err = assert_raises(RuntimeError) { parse([1, 2, 3]) }
    assert_match(/camera must be a hash/, err.message)
  end

  def test_minimum_valid_camera_defaults_to_z_up
    result = parse("eye" => [-30, -30, 160], "target" => [0, 0, 100])
    assert_equal [-30.0, -30.0, 160.0], result[:eye]
    assert_equal [0.0, 0.0, 100.0], result[:target]
    assert_equal [0.0, 0.0, 1.0], result[:up]
    assert_nil result[:perspective]
    assert_nil result[:fov]
  end

  def test_accepts_explicit_up_vector
    result = parse("eye" => [0, 0, 10], "target" => [0, 0, 0], "up" => [0, 1, 0])
    assert_equal [0.0, 1.0, 0.0], result[:up]
  end

  def test_coerces_integer_coordinates_to_floats
    result = parse("eye" => [1, 2, 3], "target" => [4, 5, 6])
    assert(result[:eye].all? { |v| v.is_a?(Float) })
    assert(result[:target].all? { |v| v.is_a?(Float) })
  end

  def test_rejects_eye_missing
    err = assert_raises(RuntimeError) { parse("target" => [0, 0, 0]) }
    assert_match(/camera\.eye must be an \[x, y, z\] array/, err.message)
  end

  def test_rejects_wrong_length_triple
    err = assert_raises(RuntimeError) { parse("eye" => [1, 2], "target" => [0, 0, 0]) }
    assert_match(/camera\.eye must be an \[x, y, z\] array/, err.message)
  end

  def test_rejects_non_numeric_coordinate
    err = assert_raises(ArgumentError, TypeError) do
      parse("eye" => ["a", 0, 0], "target" => [0, 0, 0])
    end
    refute_nil err
  end

  def test_rejects_eye_equal_to_target
    err = assert_raises(RuntimeError) do
      parse("eye" => [1, 2, 3], "target" => [1, 2, 3])
    end
    assert_match(/eye and camera\.target must differ/, err.message)
  end

  def test_rejects_zero_up_vector
    err = assert_raises(RuntimeError) do
      parse("eye" => [0, 0, 10], "target" => [0, 0, 0], "up" => [0, 0, 0])
    end
    assert_match(/camera\.up must be a non-zero vector/, err.message)
  end

  def test_accepts_perspective_false
    result = parse("eye" => [0, 0, 10], "target" => [0, 0, 0], "perspective" => false)
    assert_equal false, result[:perspective]
  end

  def test_rejects_non_boolean_perspective
    err = assert_raises(RuntimeError) do
      parse("eye" => [0, 0, 10], "target" => [0, 0, 0], "perspective" => "yes")
    end
    assert_match(/camera\.perspective must be a boolean/, err.message)
  end

  def test_accepts_fov_in_range
    result = parse("eye" => [0, 0, 10], "target" => [0, 0, 0], "fov" => 35)
    assert_in_delta 35.0, result[:fov], 1e-9
  end

  def test_rejects_fov_out_of_range
    err = assert_raises(RuntimeError) do
      parse("eye" => [0, 0, 10], "target" => [0, 0, 0], "fov" => 0)
    end
    assert_match(/camera\.fov must be > 0 and < 180/, err.message)

    err = assert_raises(RuntimeError) do
      parse("eye" => [0, 0, 10], "target" => [0, 0, 0], "fov" => 180)
    end
    assert_match(/camera\.fov must be > 0 and < 180/, err.message)
  end
end

class TestExportSceneImageDimensions < Minitest::Test
  def parse(value, name = "width")
    SU_MCP::Server.parse_image_dimension(value, name)
  end

  def test_returns_nil_when_absent
    assert_nil parse(nil)
  end

  def test_accepts_positive_integer
    assert_equal 800, parse(800)
  end

  def test_rejects_zero
    err = assert_raises(RuntimeError) { parse(0) }
    assert_match(/width must be between 1 and/, err.message)
  end

  def test_rejects_negative
    err = assert_raises(RuntimeError) { parse(-1) }
    assert_match(/width must be between 1 and/, err.message)
  end

  def test_rejects_above_max
    err = assert_raises(RuntimeError) { parse(SU_MCP::Server::IMAGE_MAX_DIMENSION + 1) }
    assert_match(/width must be between 1 and/, err.message)
  end

  def test_rejects_non_integer
    assert_raises(ArgumentError, TypeError) { parse("abc") }
  end

  def test_uses_supplied_field_name_in_error
    err = assert_raises(RuntimeError) { parse(0, "height") }
    assert_match(/height must be between 1 and/, err.message)
  end
end
