$LOAD_PATH.unshift File.expand_path("stubs", __dir__)

require "minitest/autorun"

class FakeSketchupConsole
  def show; end
  def write(_msg); end
end
SKETCHUP_CONSOLE = FakeSketchupConsole.new unless defined?(SKETCHUP_CONSOLE)

unless defined?(Sketchup)
  module Sketchup
    def self.send_action(*); end
    def self.active_model; nil; end
  end
end

# Bare base class so resolve_entity's `grep(Sketchup::Group)` works against
# fakes — Array#grep matches with `===`, which on a class is `is_a?`.
unless defined?(Sketchup::Group)
  module Sketchup
    class Group; end
  end
end

# Same trick for ComponentInstance — find_groups checks is_a? against it
# under the include_components flag.
unless defined?(Sketchup::ComponentInstance)
  module Sketchup
    class ComponentInstance; end
  end
end

unless defined?(UI)
  module UI
    def self.start_timer(*); end
    def self.menu(*); FakeMenu.new; end
  end

  class FakeMenu
    def add_submenu(*); self; end
    def add_item(*); end
  end
end

# Sketchup's extensions.rb provides these as Kernel methods. Stubbing
# `file_loaded?` to true short-circuits the bootstrap block at the bottom
# of main.rb that would otherwise instantiate Server and register menu items.
unless private_methods.include?(:file_loaded?)
  def file_loaded?(_path); true; end
  def file_loaded(_path); end
end

require_relative "../su_mcp/main"

# Subclass that bypasses SketchUp-touching setup. Use for unit tests of
# pure-logic helpers; do not call methods that require a live model.
class TestServer < SU_MCP::Server
  def initialize
    @port = 9876
    @running = false
  end

  def log(_msg); end
end

FakePoint  = Struct.new(:x, :y, :z)
FakeBounds = Struct.new(:min, :max, :center)

class FakeVector
  attr_accessor :x, :y, :z

  def initialize(x, y, z)
    @x = x.to_f
    @y = y.to_f
    @z = z.to_f
  end

  def normalize!
    mag = Math.sqrt(@x * @x + @y * @y + @z * @z)
    return self if mag.zero?
    @x /= mag
    @y /= mag
    @z /= mag
    self
  end
end
