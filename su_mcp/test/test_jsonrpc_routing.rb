require_relative "test_helper"
require "minitest/mock"

FakeEntity = Struct.new(:entityID, :typename)
FakeModel  = Struct.new(:entities)

# Spy server: captures handle_tool_call invocations so the legacy
# command-format conversion and tools/call dispatch can be asserted
# without touching any SketchUp-backed tool implementations.
class SpyServer < TestServer
  attr_reader :tool_calls

  def initialize
    super
    @tool_calls = []
  end

  def handle_tool_call(request)
    @tool_calls << request
    { jsonrpc: request["jsonrpc"] || "2.0", result: { success: true }, id: request["id"] }
  end
end

class TestJsonrpcRouting < Minitest::Test
  def test_prompts_list_returns_empty_prompts
    server = TestServer.new
    response = server.send(:handle_jsonrpc_request,
      "jsonrpc" => "2.0", "method" => "prompts/list", "id" => 7)

    assert_equal "2.0", response[:jsonrpc]
    assert_equal 7,     response[:id]
    assert_equal [],    response[:result][:prompts]
    assert_equal true,  response[:result][:success]
  end

  def test_unknown_method_returns_method_not_found_error
    server = TestServer.new
    response = server.send(:handle_jsonrpc_request,
      "jsonrpc" => "2.0", "method" => "nope/whatever", "id" => 11)

    assert_equal "2.0",              response[:jsonrpc]
    assert_equal 11,                 response[:id]
    assert_equal(-32601,             response[:error][:code])
    assert_equal "Method not found", response[:error][:message]
    assert_equal false,              response[:error][:data][:success]
  end

  def test_missing_jsonrpc_field_defaults_to_2_0
    server = TestServer.new
    response = server.send(:handle_jsonrpc_request, "method" => "prompts/list", "id" => 1)

    assert_equal "2.0", response[:jsonrpc]
    assert_equal 1,     response[:id]
    assert_equal [],    response[:result][:prompts]
    refute response.key?(:error), "tolerated-missing-jsonrpc must complete routing without an error"
  end

  def test_resources_list_with_no_active_model_returns_empty_array
    # The `sketchup` stub returns nil from Sketchup.active_model, which
    # exercises list_resources's nil-guard branch.
    server = TestServer.new
    response = server.send(:handle_jsonrpc_request,
      "jsonrpc" => "2.0", "method" => "resources/list", "id" => 3)

    assert_equal [],   response[:result][:resources]
    assert_equal true, response[:result][:success]
    assert_equal 3,    response[:id]
  end

  def test_resources_list_with_active_model_maps_entities
    server = TestServer.new
    fake_model = FakeModel.new([
      FakeEntity.new(101, "Group"),
      FakeEntity.new(202, "ComponentInstance"),
    ])

    response = Sketchup.stub :active_model, fake_model do
      server.send(:handle_jsonrpc_request,
        "jsonrpc" => "2.0", "method" => "resources/list", "id" => 5)
    end

    assert_equal 5,    response[:id]
    assert_equal true, response[:result][:success]
    assert_equal(
      [
        { id: 101, type: "group" },
        { id: 202, type: "componentinstance" },
      ],
      response[:result][:resources],
    )
  end

  def test_legacy_command_format_is_converted_to_tools_call
    server = SpyServer.new
    response = server.send(:handle_jsonrpc_request,
      "command"    => "create_component",
      "parameters" => { "type" => "cube" },
      "jsonrpc"    => "2.0",
      "id"         => 42)

    assert_equal 1, server.tool_calls.length
    converted = server.tool_calls.first
    assert_equal "tools/call",        converted["method"]
    assert_equal "create_component",  converted["params"]["name"]
    assert_equal({ "type" => "cube" }, converted["params"]["arguments"])
    assert_equal 42, converted["id"]
    # The converted request must carry the incoming jsonrpc field; otherwise
    # downstream handlers default to "2.0" and a mismatch is invisible.
    assert_equal "2.0", converted["jsonrpc"]

    # Production must return handle_tool_call's response, not nil; otherwise
    # real clients receive a broken response even though the spy was called.
    assert_equal({ jsonrpc: "2.0", result: { success: true }, id: 42 }, response)
  end

  # -- jsonrpc field is echoed (not hard-coded "2.0") per routing branch ----

  def test_prompts_list_echoes_non_default_jsonrpc
    server = TestServer.new
    response = server.send(:handle_jsonrpc_request,
      "jsonrpc" => "2.1", "method" => "prompts/list", "id" => 1)
    assert_equal "2.1", response[:jsonrpc]
  end

  def test_resources_list_echoes_non_default_jsonrpc
    server = TestServer.new
    response = server.send(:handle_jsonrpc_request,
      "jsonrpc" => "2.1", "method" => "resources/list", "id" => 2)
    assert_equal "2.1", response[:jsonrpc]
  end

  def test_method_not_found_echoes_non_default_jsonrpc
    server = TestServer.new
    response = server.send(:handle_jsonrpc_request,
      "jsonrpc" => "2.1", "method" => "nope/whatever", "id" => 3)
    assert_equal "2.1", response[:jsonrpc]
  end

  def test_legacy_command_propagates_non_default_jsonrpc
    server = SpyServer.new
    server.send(:handle_jsonrpc_request,
      "command" => "get_selection", "jsonrpc" => "2.1", "id" => 4)
    converted = server.tool_calls.first
    assert_equal "2.1", converted["jsonrpc"]
  end

  def test_legacy_command_with_no_parameters_passes_nil_arguments
    server = SpyServer.new
    server.send(:handle_jsonrpc_request,
      "jsonrpc" => "2.0",
      "command" => "get_selection",
      "id"      => 7)

    assert_equal 1, server.tool_calls.length
    converted = server.tool_calls.first
    assert_equal "tools/call",     converted["method"]
    assert_equal "get_selection",  converted["params"]["name"]
    assert_nil converted["params"]["arguments"]
  end

  def test_command_takes_precedence_over_method
    server = SpyServer.new
    server.send(:handle_jsonrpc_request,
      "jsonrpc"    => "2.0",
      "command"    => "get_selection",
      "method"     => "tools/call",
      "parameters" => { "foo" => "bar" },
      "id"         => 8)

    assert_equal 1, server.tool_calls.length
    converted = server.tool_calls.first
    # Legacy path wins: name comes from "command", not the params of an
    # already-formed tools/call request.
    assert_equal "get_selection",      converted["params"]["name"]
    assert_equal({ "foo" => "bar" }, converted["params"]["arguments"])
  end

  def test_tools_call_method_dispatches_to_handle_tool_call
    server = SpyServer.new
    request = {
      "jsonrpc" => "2.0",
      "method"  => "tools/call",
      "params"  => { "name" => "get_selection", "arguments" => {} },
      "id"      => 99,
    }
    response = server.send(:handle_jsonrpc_request, request)

    assert_equal 1, server.tool_calls.length
    assert_same request, server.tool_calls.first
    assert_equal({ jsonrpc: "2.0", result: { success: true }, id: 99 }, response)
  end

  # -- malformed tools/call requests -----------------------------------------

  def test_tools_call_with_missing_params_returns_jsonrpc_error
    # Real MCP clients can send broken requests; handle_tool_call must convert
    # the resulting nil-deref into the rescue-branch error, not crash. If the
    # rescue handler is removed (or the nil-params guard is dropped), this
    # NoMethodErrors out of the server.
    server = TestServer.new
    response = server.send(:handle_jsonrpc_request,
      "jsonrpc" => "2.0", "method" => "tools/call", "id" => 1)

    assert_equal "2.0", response[:jsonrpc]
    assert_equal 1, response[:id]
    assert_equal(-32603, response[:error][:code])
    assert_equal false, response[:error][:data][:success]
    refute_nil response[:error][:message], "structured error must carry a message"
  end

  def test_tools_call_with_non_hash_params_returns_jsonrpc_error
    server = TestServer.new
    response = server.send(:handle_jsonrpc_request,
      "jsonrpc" => "2.0", "method" => "tools/call",
      "params" => "not a hash", "id" => 2)

    assert_equal(-32603, response[:error][:code])
    assert_equal 2, response[:id]
  end
end
