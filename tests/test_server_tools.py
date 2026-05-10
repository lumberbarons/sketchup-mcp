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


async def test_every_tool_is_registered(fake: FakeSketchupClient) -> None:
    async with make_session() as session:
        listed = await session.list_tools()
    names = {t.name for t in listed.tools}
    assert names == {
        "batch_create",
        "create_component",
        "create_extrusion",
        "delete_component",
        "transform_component",
        "find_groups",
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
    assert "move_to" not in args, "unset move_to must be omitted, not passed as null"
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
                "move_to": [10, 20, 30],
                "position": [1, 2, 3],
                "rotation": [0, 90, 0],
                "scale": [2, 2, 2],
            },
        )
    assert fake.last_arguments == {
        "id": "abc",
        "move_to": [10, 20, 30],
        "position": [1, 2, 3],
        "rotation": [0, 90, 0],
        "scale": [2, 2, 2],
    }


async def test_transform_component_forwards_move_to_alone(
    fake: FakeSketchupClient,
) -> None:
    async with make_session() as session:
        await session.call_tool("transform_component", {"id": "abc", "move_to": [10, 20, 30]})
    args = fake.last_arguments
    assert args == {"id": "abc", "move_to": [10, 20, 30]}
    assert "position" not in args, "unset position must be omitted, not passed as null"


# ---------------------------------------------------------------------------
# Name-based addressing — `name` is forwarded in place of `id` for
# delete_component and transform_component. The actual resolution (and the
# both/neither/not-found/ambiguous error paths) lives on the Ruby side and
# is exercised by su_mcp/test/test_resolve_entity.rb. Here we just verify
# the wire-level forwarding so a future rename in the Python tool can't
# silently drop the parameter.
# ---------------------------------------------------------------------------


async def test_delete_component_forwards_name(fake: FakeSketchupClient) -> None:
    async with make_session() as session:
        await session.call_tool("delete_component", {"name": "Rafter W 5"})
    assert fake.last_tool_name == "delete_component"
    assert fake.last_arguments == {"name": "Rafter W 5"}
    assert "id" not in fake.last_arguments


async def test_transform_component_forwards_name(fake: FakeSketchupClient) -> None:
    async with make_session() as session:
        await session.call_tool("transform_component", {"name": "Ridge", "move_to": [0, 0, 5]})
    assert fake.last_tool_name == "transform_component"
    assert fake.last_arguments == {"name": "Ridge", "move_to": [0, 0, 5]}
    assert "id" not in fake.last_arguments


async def test_delete_component_forwards_neither_when_omitted(
    fake: FakeSketchupClient,
) -> None:
    """When neither id nor name is given, both are omitted from the forwarded
    payload; the Ruby side raises the both/neither validation error."""
    async with make_session() as session:
        await session.call_tool("delete_component", {})
    assert fake.last_arguments == {}


async def test_transform_component_forwards_both_when_both_given(
    fake: FakeSketchupClient,
) -> None:
    """Python doesn't validate exclusivity — both are forwarded so the Ruby
    side's resolve_entity is the single source of truth for the error."""
    async with make_session() as session:
        await session.call_tool("transform_component", {"id": "5", "name": "Ridge"})
    assert fake.last_arguments == {"id": "5", "name": "Ridge"}


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
        (
            "find_groups",
            {},  # no filters — defaults forwarded
            "find_groups",
            {"limit": 200, "include_components": False},
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


# ---------------------------------------------------------------------------
# find_groups — each filter must be forwarded under the right key. Filtering
# logic itself lives in Ruby (see su_mcp/test/test_find_groups_filters.rb);
# these tests pin the wire shape so a rename or dropped key can't slip past.
# ---------------------------------------------------------------------------


async def test_find_groups_forwards_name_prefix(fake: FakeSketchupClient) -> None:
    async with make_session() as session:
        await session.call_tool("find_groups", {"name_prefix": "WA "})
    assert fake.last_tool_name == "find_groups"
    assert fake.last_arguments == {
        "name_prefix": "WA ",
        "limit": 200,
        "include_components": False,
    }


async def test_find_groups_forwards_name_pattern(fake: FakeSketchupClient) -> None:
    async with make_session() as session:
        await session.call_tool("find_groups", {"name_pattern": r"^Rafter [WE] \d+$"})
    assert fake.last_arguments == {
        "name_pattern": r"^Rafter [WE] \d+$",
        "limit": 200,
        "include_components": False,
    }


async def test_find_groups_forwards_in_bounds_positive(
    fake: FakeSketchupClient,
) -> None:
    """A typical 'what's near the door RO?' query — bounds intersection.
    Pinning the exact wire shape protects the Ruby-side parser."""
    async with make_session() as session:
        await session.call_tool(
            "find_groups",
            {"in_bounds": {"min": [38, 0, 0], "max": [82, 3.5, 95]}},
        )
    assert fake.last_arguments == {
        "in_bounds": {"min": [38, 0, 0], "max": [82, 3.5, 95]},
        "limit": 200,
        "include_components": False,
    }


async def test_find_groups_forwards_in_bounds_negative_aabb(
    fake: FakeSketchupClient,
) -> None:
    """A negative-coordinate AABB must round-trip unchanged — bounds are
    inches in SketchUp's coordinate system and routinely go negative."""
    async with make_session() as session:
        await session.call_tool(
            "find_groups",
            {"in_bounds": {"min": [-10, -10, -10], "max": [-1, -1, -1]}},
        )
    assert fake.last_arguments["in_bounds"] == {
        "min": [-10, -10, -10],
        "max": [-1, -1, -1],
    }


async def test_find_groups_forwards_combined_filters(
    fake: FakeSketchupClient,
) -> None:
    async with make_session() as session:
        await session.call_tool(
            "find_groups",
            {
                "name_prefix": "WA ",
                "in_bounds": {"min": [0, 0, 0], "max": [100, 100, 100]},
                "parent_id": 42,
                "limit": 10,
                "include_components": True,
            },
        )
    assert fake.last_arguments == {
        "name_prefix": "WA ",
        "in_bounds": {"min": [0, 0, 0], "max": [100, 100, 100]},
        "parent_id": 42,
        "limit": 10,
        "include_components": True,
    }


async def test_find_groups_forwards_truncation_limit(
    fake: FakeSketchupClient,
) -> None:
    async with make_session() as session:
        await session.call_tool("find_groups", {"limit": 5})
    assert fake.last_arguments["limit"] == 5


async def test_find_groups_forwards_include_components(
    fake: FakeSketchupClient,
) -> None:
    async with make_session() as session:
        await session.call_tool("find_groups", {"include_components": True})
    assert fake.last_arguments["include_components"] is True


async def test_find_groups_omits_unset_filters(fake: FakeSketchupClient) -> None:
    """A bare call must not leak null filter keys onto the wire — the Ruby
    side branches on key presence (`params.key?("name_prefix")`)."""
    async with make_session() as session:
        await session.call_tool("find_groups", {})
    assert fake.last_arguments == {"limit": 200, "include_components": False}
    for key in ("name_prefix", "name_pattern", "in_bounds", "parent_id"):
        assert key not in fake.last_arguments, f"unset {key} must be omitted"


# ---------------------------------------------------------------------------
# create_extrusion — non-axis-aligned profiles on each axis, reverse-direction
# extrusion, and the material round-trip. Geometry construction itself lives
# in Ruby (see su_mcp/test/test_extrusion_helpers.rb); these cases pin the
# wire shape and confirm that each axis option survives the round trip.
# ---------------------------------------------------------------------------


# Parallelogram side profile of a sloped 2x6 rafter — taken verbatim from
# the create_extrusion bead's worked example. Vertices are intentionally not
# axis-aligned (sloped top and bottom edges) so a future refactor that
# accidentally axis-snaps the profile would break the assertion.
_RAFTER_PROFILE = [
    [-12, 89.625],
    [59.25, 125.25],
    [59.25, 131.399],
    [-12, 95.774],
]


async def test_create_extrusion_y_axis_rafter(fake: FakeSketchupClient) -> None:
    """The canonical use case from the bead: parallelogram profile extruded
    1.5" along y to make a single rafter."""
    async with make_session() as session:
        await session.call_tool(
            "create_extrusion",
            {
                "name": "Rafter W 5",
                "profile": _RAFTER_PROFILE,
                "extrude_axis": "y",
                "extrude_from": 15.25,
                "extrude_to": 16.75,
            },
        )
    assert fake.last_tool_name == "create_extrusion"
    assert fake.last_arguments == {
        "name": "Rafter W 5",
        "profile": _RAFTER_PROFILE,
        "extrude_axis": "y",
        "extrude_from": 15.25,
        "extrude_to": 16.75,
    }
    assert "material" not in fake.last_arguments


async def test_create_extrusion_x_axis(fake: FakeSketchupClient) -> None:
    async with make_session() as session:
        await session.call_tool(
            "create_extrusion",
            {
                "name": "Header A",
                "profile": _RAFTER_PROFILE,
                "extrude_axis": "x",
                "extrude_from": 0.0,
                "extrude_to": 3.5,
            },
        )
    assert fake.last_arguments["extrude_axis"] == "x"
    assert fake.last_arguments["profile"] == _RAFTER_PROFILE


async def test_create_extrusion_z_axis(fake: FakeSketchupClient) -> None:
    async with make_session() as session:
        await session.call_tool(
            "create_extrusion",
            {
                "name": "Post 1",
                "profile": _RAFTER_PROFILE,
                "extrude_axis": "z",
                "extrude_from": 0.0,
                "extrude_to": 96.0,
            },
        )
    assert fake.last_arguments["extrude_axis"] == "z"


async def test_create_extrusion_reverse_direction(
    fake: FakeSketchupClient,
) -> None:
    """`extrude_to < extrude_from` must round-trip unchanged — Ruby's
    extrude_direction helper handles the sign. If we sorted these in Python
    we'd break the "face faces the right way" contract."""
    async with make_session() as session:
        await session.call_tool(
            "create_extrusion",
            {
                "name": "Sloped Stud",
                "profile": _RAFTER_PROFILE,
                "extrude_axis": "z",
                "extrude_from": 96.0,
                "extrude_to": 0.0,
            },
        )
    assert fake.last_arguments["extrude_from"] == 96.0
    assert fake.last_arguments["extrude_to"] == 0.0


async def test_create_extrusion_forwards_material(
    fake: FakeSketchupClient,
) -> None:
    async with make_session() as session:
        await session.call_tool(
            "create_extrusion",
            {
                "name": "Fascia",
                "profile": [[0, 0], [1, 0], [1, 1], [0, 1]],
                "extrude_axis": "y",
                "extrude_from": 0,
                "extrude_to": 100,
                "material": "#8B4513",
            },
        )
    assert fake.last_arguments["material"] == "#8B4513"


async def test_create_extrusion_omits_unset_material(
    fake: FakeSketchupClient,
) -> None:
    async with make_session() as session:
        await session.call_tool(
            "create_extrusion",
            {
                "name": "Fascia",
                "profile": [[0, 0], [1, 0], [1, 1], [0, 1]],
                "extrude_axis": "y",
                "extrude_from": 0,
                "extrude_to": 100,
            },
        )
    assert "material" not in fake.last_arguments


# ---------------------------------------------------------------------------
# batch_create — wire-shape tests. Per-op dispatch and the start/commit/abort
# transaction logic live in Ruby (see su_mcp/test/test_batch_create.rb).
# These tests confirm the Python tool faithfully forwards `operations` and
# `transaction_name`, and that a failure envelope round-trips with the
# message the Ruby side raises after aborting.
# ---------------------------------------------------------------------------


async def test_batch_create_forwards_mixed_ops(fake: FakeSketchupClient) -> None:
    """A realistic batch: a couple of creates, a relative translate, an
    absolute move_to, and a delete. All five op shapes must round-trip
    unchanged so the Ruby dispatcher sees what the caller wrote."""
    ops = [
        {
            "op": "cube",
            "name": "Foundation Block 1",
            "position": [0, 0, 0],
            "dimensions": [16, 16, 8],
        },
        {
            "op": "cylinder",
            "name": "Post 1",
            "position": [10, 10, 0],
            "radius": 1.75,
            "height": 96,
        },
        {"op": "translate", "id_or_name": 42, "delta": [0, 0, 1.5]},
        {"op": "move_to", "id_or_name": "Ridge", "target": [0, 0, 96]},
        {"op": "delete", "id_or_name": 99},
    ]
    async with make_session() as session:
        await session.call_tool(
            "batch_create", {"operations": ops, "transaction_name": "Foundation pass"}
        )
    assert fake.last_tool_name == "batch_create"
    assert fake.last_arguments == {
        "transaction_name": "Foundation pass",
        "operations": ops,
    }


async def test_batch_create_defaults_transaction_name(
    fake: FakeSketchupClient,
) -> None:
    async with make_session() as session:
        await session.call_tool(
            "batch_create",
            {
                "operations": [
                    {
                        "op": "sphere",
                        "name": "Ball",
                        "position": [0, 0, 0],
                        "radius": 1,
                    }
                ]
            },
        )
    assert fake.last_arguments["transaction_name"] == "MCP batch"


async def test_batch_create_name_based_mutates_round_trip(
    fake: FakeSketchupClient,
) -> None:
    """Name-based references for mutates and deletes are the headline win of
    composing batch_create with find_groups — make sure strings stay strings."""
    ops = [
        {"op": "translate", "id_or_name": "Rafter W 5", "delta": [0, 0, 0.5]},
        {"op": "delete", "id_or_name": "Old Rafter"},
    ]
    async with make_session() as session:
        await session.call_tool("batch_create", {"operations": ops})
    forwarded = fake.last_arguments["operations"]
    assert forwarded[0]["id_or_name"] == "Rafter W 5"
    assert isinstance(forwarded[0]["id_or_name"], str)
    assert forwarded[1]["id_or_name"] == "Old Rafter"
    assert isinstance(forwarded[1]["id_or_name"], str)


async def test_batch_create_forwards_extrusion_op(fake: FakeSketchupClient) -> None:
    """Extrusion params include a nested list (profile) and floats —
    confirm the whole shape round-trips."""
    extrusion_op = {
        "op": "extrusion",
        "name": "Rafter W 1",
        "profile": [
            [-12, 89.625],
            [59.25, 125.25],
            [59.25, 131.399],
            [-12, 95.774],
        ],
        "extrude_axis": "y",
        "extrude_from": 0.0,
        "extrude_to": 1.5,
    }
    async with make_session() as session:
        await session.call_tool("batch_create", {"operations": [extrusion_op]})
    assert fake.last_arguments["operations"][0] == extrusion_op


async def test_batch_create_failure_envelope_round_trip(
    fake: FakeSketchupClient,
) -> None:
    """When the Ruby side aborts the transaction and raises, the error message
    must surface intact in the failure envelope. The Ruby-side rollback itself
    is covered by su_mcp/test/test_batch_create.rb."""
    fake.next_error = RuntimeError(
        'batch_create operation #2 ("cube") failed: bad face. Aborted; 2 prior op(s) rolled back.'
    )
    async with make_session() as session:
        result = await session.call_tool(
            "batch_create",
            {
                "operations": [
                    {"op": "cube", "name": "A", "position": [0, 0, 0], "dimensions": [1, 1, 1]},
                    {"op": "cube", "name": "B", "position": [2, 0, 0], "dimensions": [1, 1, 1]},
                    {"op": "cube", "name": "C", "position": [4, 0, 0], "dimensions": [1, 1, 1]},
                ]
            },
        )
    env = envelope(result)
    assert env["success"] is False
    assert env["result"] is None
    assert "operation #2" in env["error"]
    assert "rolled back" in env["error"]


async def test_batch_create_preserves_op_order(fake: FakeSketchupClient) -> None:
    """Order matters — a later move_to depends on an earlier create. Don't
    let any future "optimization" reorder the operations array."""
    ops = [
        {"op": "cube", "name": "First", "position": [0, 0, 0], "dimensions": [1, 1, 1]},
        {"op": "cube", "name": "Second", "position": [2, 0, 0], "dimensions": [1, 1, 1]},
        {"op": "cube", "name": "Third", "position": [4, 0, 0], "dimensions": [1, 1, 1]},
    ]
    async with make_session() as session:
        await session.call_tool("batch_create", {"operations": ops})
    forwarded = fake.last_arguments["operations"]
    assert [op["name"] for op in forwarded] == ["First", "Second", "Third"]
