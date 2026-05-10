"""End-to-end tests for the @mcp.tool() endpoints.

Each test drives the FastMCP server through an in-memory ClientSession (no
sockets, no subprocess, no SketchUp) and asserts both:

  1. The exact arguments the tool forwards to SketchupClient.send_command —
     this catches typos in argument names, missing default substitutions,
     and dropped-vs-omitted keys.
  2. The {success, result, error} JSON envelope returned to the MCP client.
"""

from __future__ import annotations

import json
from typing import Any

import pytest
from mcp.shared.memory import create_connected_server_and_client_session

import sketchup_mcp.server as server_mod


# Inline rather than fixture: anyio task groups under
# create_connected_server_and_client_session must enter and exit in the SAME
# task, but pytest-asyncio's async-generator fixtures drive teardown from a
# different task — which trips anyio's cancel-scope check. Keeping the
# `async with` inside each test sidesteps that entirely.
def make_session():
    return create_connected_server_and_client_session(server_mod.mcp)


class FakeSketchupClient:
    """Replacement for SketchupClient that records calls instead of opening
    sockets. Tests configure next_result / next_error before calling tools."""

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        self.calls: list[dict[str, Any]] = []
        self.next_result: Any = {}
        self.next_error: BaseException | None = None

    def probe(self) -> bool:
        return True

    def send_command(
        self,
        method: str,
        params: dict[str, Any] | None = None,
        request_id: Any = None,
    ) -> Any:
        self.calls.append({"method": method, "params": params or {}, "request_id": request_id})
        if self.next_error is not None:
            raise self.next_error
        return self.next_result

    @property
    def last_arguments(self) -> dict[str, Any]:
        return self.calls[-1]["params"]["arguments"]

    @property
    def last_tool_name(self) -> str:
        return self.calls[-1]["params"]["name"]


@pytest.fixture
def fake(monkeypatch: pytest.MonkeyPatch) -> FakeSketchupClient:
    """Replace the real SketchupClient with a FakeSketchupClient for the
    duration of the test. The lifespan looks up SketchupClient by name in the
    server module each time it constructs a client, so monkeypatching the
    module attribute is sufficient."""
    instance = FakeSketchupClient()

    def factory(*args: Any, **kwargs: Any) -> FakeSketchupClient:
        return instance

    monkeypatch.setattr(server_mod, "SketchupClient", factory)
    return instance


def envelope(text_content_result: Any) -> dict[str, Any]:
    """Decode the JSON envelope from a CallToolResult."""
    return json.loads(text_content_result.content[0].text)


# ---------------------------------------------------------------------------
# Server registration
# ---------------------------------------------------------------------------


async def test_all_ten_tools_are_registered(fake: FakeSketchupClient) -> None:
    async with make_session() as session:
        listed = await session.list_tools()
    names = {t.name for t in listed.tools}
    assert names == {
        "create_component",
        "delete_component",
        "transform_component",
        "get_selection",
        "set_material",
        "export_scene",
        "create_mortise_tenon",
        "create_dovetail",
        "create_finger_joint",
        "eval_ruby",
    }


# ---------------------------------------------------------------------------
# Envelope shape — success and failure
# ---------------------------------------------------------------------------


async def test_success_envelope_wraps_send_command_result(
    fake: FakeSketchupClient,
) -> None:
    fake.next_result = {"id": "comp-1", "type": "cube"}
    async with make_session() as session:
        result = await session.call_tool("create_component", {})
    assert envelope(result) == {
        "success": True,
        "result": {"id": "comp-1", "type": "cube"},
        "error": None,
    }


async def test_failure_envelope_captures_exception_message(
    fake: FakeSketchupClient,
) -> None:
    fake.next_error = RuntimeError("ruby barfed")
    async with make_session() as session:
        result = await session.call_tool("create_component", {})
    assert envelope(result) == {
        "success": False,
        "result": None,
        "error": "ruby barfed",
    }


async def test_request_id_is_threaded_through(fake: FakeSketchupClient) -> None:
    """Every send_command call should receive the MCP request_id so the
    JSON-RPC id round-trips back to SketchUp."""
    async with make_session() as session:
        await session.call_tool("get_selection", {})
    assert fake.calls[-1]["request_id"] is not None


# ---------------------------------------------------------------------------
# create_component — default substitution for None position/dimensions
# ---------------------------------------------------------------------------


async def test_create_component_substitutes_defaults_when_omitted(
    fake: FakeSketchupClient,
) -> None:
    async with make_session() as session:
        await session.call_tool("create_component", {})
    assert fake.last_tool_name == "create_component"
    assert fake.last_arguments == {
        "type": "cube",
        "position": [0, 0, 0],
        "dimensions": [1, 1, 1],
    }


async def test_create_component_passes_explicit_args_through(
    fake: FakeSketchupClient,
) -> None:
    async with make_session() as session:
        await session.call_tool(
            "create_component",
            {
                "type": "sphere",
                "position": [1.0, 2.0, 3.0],
                "dimensions": [4.0, 5.0, 6.0],
            },
        )
    assert fake.last_arguments == {
        "type": "sphere",
        "position": [1.0, 2.0, 3.0],
        "dimensions": [4.0, 5.0, 6.0],
    }


# ---------------------------------------------------------------------------
# transform_component — None args must be OMITTED, not passed as null
# ---------------------------------------------------------------------------


async def test_transform_component_omits_none_arguments(
    fake: FakeSketchupClient,
) -> None:
    async with make_session() as session:
        await session.call_tool("transform_component", {"id": "abc", "position": [1, 2, 3]})
    args = fake.last_arguments
    assert args == {"id": "abc", "position": [1, 2, 3]}
    assert "rotation" not in args, "unset rotation must be omitted, not passed as null"
    assert "scale" not in args, "unset scale must be omitted, not passed as null"


async def test_transform_component_includes_all_provided_arguments(
    fake: FakeSketchupClient,
) -> None:
    async with make_session() as session:
        await session.call_tool(
            "transform_component",
            {
                "id": "abc",
                "position": [1, 2, 3],
                "rotation": [0, 90, 0],
                "scale": [2, 2, 2],
            },
        )
    assert fake.last_arguments == {
        "id": "abc",
        "position": [1, 2, 3],
        "rotation": [0, 90, 0],
        "scale": [2, 2, 2],
    }


# ---------------------------------------------------------------------------
# Argument-name parity for every tool — catches typos in keys forwarded to
# the Ruby side, which would otherwise fail silently as missing-arg errors
# at runtime against a live SketchUp.
#
# Note the asymmetry: the FastMCP-tool name (e.g. export_scene) and the
# Ruby-side method name (e.g. "export") can differ. Each parametrize row
# captures the expected mapping explicitly.
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "tool_name, mcp_args, expected_ruby_method, expected_ruby_args",
    [
        (
            "delete_component",
            {"id": "x"},
            "delete_component",
            {"id": "x"},
        ),
        (
            "get_selection",
            {},
            "get_selection",
            {},
        ),
        (
            "set_material",
            {"id": "x", "material": "wood"},
            "set_material",
            {"id": "x", "material": "wood"},
        ),
        (
            "export_scene",
            {"format": "obj"},
            "export",
            {"format": "obj"},
        ),
        (
            "export_scene",
            {},  # default format is "skp"
            "export",
            {"format": "skp"},
        ),
        (
            "create_mortise_tenon",
            {"mortise_id": "m", "tenon_id": "t"},
            "create_mortise_tenon",
            {
                "mortise_id": "m",
                "tenon_id": "t",
                "width": 1.0,
                "height": 1.0,
                "depth": 1.0,
                "offset_x": 0.0,
                "offset_y": 0.0,
                "offset_z": 0.0,
            },
        ),
        (
            "create_dovetail",
            {"tail_id": "t", "pin_id": "p"},
            "create_dovetail",
            {
                "tail_id": "t",
                "pin_id": "p",
                "width": 1.0,
                "height": 1.0,
                "depth": 1.0,
                "angle": 15.0,
                "num_tails": 3,
                "offset_x": 0.0,
                "offset_y": 0.0,
                "offset_z": 0.0,
            },
        ),
        (
            "create_finger_joint",
            {"board1_id": "a", "board2_id": "b"},
            "create_finger_joint",
            {
                "board1_id": "a",
                "board2_id": "b",
                "width": 1.0,
                "height": 1.0,
                "depth": 1.0,
                "num_fingers": 5,
                "offset_x": 0.0,
                "offset_y": 0.0,
                "offset_z": 0.0,
            },
        ),
        (
            "eval_ruby",
            {"code": "1+1"},
            "eval_ruby",
            {"code": "1+1"},
        ),
    ],
)
async def test_tool_forwards_expected_arguments(
    fake: FakeSketchupClient,
    tool_name: str,
    mcp_args: dict[str, Any],
    expected_ruby_method: str,
    expected_ruby_args: dict[str, Any],
) -> None:
    async with make_session() as session:
        await session.call_tool(tool_name, mcp_args)
    assert fake.last_tool_name == expected_ruby_method
    assert fake.last_arguments == expected_ruby_args


# ---------------------------------------------------------------------------
# eval_ruby — the central use case, deserves a dedicated end-to-end test
# ---------------------------------------------------------------------------


async def test_eval_ruby_round_trip(fake: FakeSketchupClient) -> None:
    fake.next_result = "42"
    async with make_session() as session:
        result = await session.call_tool("eval_ruby", {"code": "6 * 7"})

    assert fake.calls[-1]["method"] == "tools/call"
    assert fake.last_tool_name == "eval_ruby"
    assert fake.last_arguments == {"code": "6 * 7"}
    assert envelope(result) == {"success": True, "result": "42", "error": None}
