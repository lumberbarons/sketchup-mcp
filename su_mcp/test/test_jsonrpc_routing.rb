require_relative "test_helper"

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

  def test_legacy_command_format_is_converted_to_tools_call
    server = SpyServer.new
    server.send(:handle_jsonrpc_request,
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
  end

  def test_tools_call_method_dispatches_to_handle_tool_call
    server = SpyServer.new
    request = {
      "jsonrpc" => "2.0",
      "method"  => "tools/call",
      "params"  => { "name" => "get_selection", "arguments" => {} },
      "id"      => 99,
    }
    server.send(:handle_jsonrpc_request, request)

    assert_equal 1, server.tool_calls.length
    assert_same request, server.tool_calls.first
  end
end
