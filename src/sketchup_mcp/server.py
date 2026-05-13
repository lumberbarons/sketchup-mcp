import json
import logging
import socket
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager, closing
from dataclasses import dataclass
from typing import Any

from mcp.server.fastmcp import Context, FastMCP

# Configure logging
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger("SketchupMCPServer")

# Define version directly to avoid pkg_resources dependency
__version__ = "1.9.0"
logger.info(f"SketchupMCP Server version {__version__} starting up")


@dataclass
class SketchupClient:
    """Stateless client for the SketchUp Ruby TCP server.

    SketchUp closes the client socket after each request, so this class
    holds no socket state — every send_command opens a fresh connection.
    """

    host: str
    port: int
    timeout: float = 15.0

    def _open_socket(self) -> socket.socket:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        sock.connect((self.host, self.port))
        return sock

    def probe(self) -> bool:
        """One-shot reachability check for startup diagnostics."""
        try:
            sock = self._open_socket()
            sock.close()
            logger.info(f"SketchUp reachable at {self.host}:{self.port}")
            return True
        except Exception as e:
            logger.warning(f"SketchUp not reachable at {self.host}:{self.port}: {e}")
            return False

    def send_command(
        self,
        method: str,
        params: dict[str, Any] = None,
        request_id: Any = None,
    ) -> dict[str, Any]:
        """Send a JSON-RPC request to Sketchup and return the response.

        Retries are limited to connect-time failures so we never replay a
        request that may have already reached SketchUp. Once the socket is
        open, send/recv failures bubble up and the call fails.
        """
        request = {
            "jsonrpc": "2.0",
            "method": method,
            "params": params or {},
            "id": request_id,
        }
        with closing(self._connect_with_retries()) as sock:
            self._send_request(sock, request)
            response = self._read_response(sock)
        return self._unwrap_response(response)

    def _connect_with_retries(self, max_retries: int = 2) -> socket.socket:
        last_error: Exception | None = None
        for attempt in range(max_retries + 1):
            try:
                return self._open_socket()
            except OSError as e:
                last_error = e
                logger.warning(f"Connect failed (attempt {attempt + 1}/{max_retries + 1}): {e}")
        raise ConnectionError(
            f"Could not connect to SketchUp at {self.host}:{self.port} "
            f"after {max_retries + 1} attempts: {last_error}"
        )

    def _send_request(self, sock: socket.socket, request: dict[str, Any]) -> None:
        request_bytes = json.dumps(request).encode("utf-8") + b"\n"
        tool_name = request.get("params", {}).get("name", request.get("method"))
        logger.info(f"calling tool {tool_name} ({len(request_bytes)} bytes)")
        logger.debug(f"Sending JSON-RPC request: {request}")
        logger.debug(f"Raw bytes being sent: {request_bytes}")
        sock.sendall(request_bytes)

    def _read_response(self, sock: socket.socket) -> Any:
        # Both sides terminate JSON messages with '\n', so one readline = one message.
        fp = sock.makefile("rb")
        line = fp.readline()
        if not line:
            raise Exception("Connection closed before receiving any data")
        logger.debug(f"Received response ({len(line)} bytes)")
        response = json.loads(line.decode("utf-8"))
        logger.debug(f"Response parsed: {response}")
        return response

    def _unwrap_response(self, response: Any) -> Any:
        if not isinstance(response, dict):
            return response
        if "error" in response:
            logger.error(f"Sketchup error: {response['error']}")
            raise Exception(response["error"].get("message", "Unknown error from Sketchup"))
        return response.get("result", {})


@asynccontextmanager
async def server_lifespan(server: FastMCP) -> AsyncIterator[dict[str, Any]]:
    """Construct the SketchUp client and probe reachability on startup.
    The client is exposed to tools via the lifespan context, not a global."""
    logger.info("SketchupMCP server starting up")
    client = SketchupClient(host="localhost", port=9876)
    if not client.probe():
        logger.warning(
            "Make sure the SketchUp extension is running and Start Server has been clicked"
        )
    try:
        yield {"sketchup": client}
    finally:
        logger.info("SketchupMCP server shut down")


def _client(ctx: Context) -> SketchupClient:
    """Get the SketchupClient injected by the lifespan."""
    return ctx.request_context.lifespan_context["sketchup"]


def _call_sketchup(ctx: Context, ruby_tool: str, arguments: dict[str, Any]) -> str:
    """Forward a tool call to the SketchUp Ruby server.

    Returns a JSON-encoded envelope with the same shape for every tool:
      success: bool
      result:  opaque payload from SketchUp on success, null on failure
      error:   error message string on failure, null on success
    """
    try:
        result = _client(ctx).send_command(
            method="tools/call",
            params={"name": ruby_tool, "arguments": arguments},
            request_id=ctx.request_id,
        )
        return json.dumps({"success": True, "result": result, "error": None})
    except Exception as e:
        logger.exception("tool %s failed", ruby_tool)
        return json.dumps({"success": False, "result": None, "error": str(e)})


# Create MCP server with lifespan support
mcp = FastMCP(
    "SketchupMCP",
    instructions="Sketchup integration through the Model Context Protocol",
    lifespan=server_lifespan,
)


# Tool endpoints — each one declares its parameters and forwards to _call_sketchup.
@mcp.tool()
def create_component(
    ctx: Context,
    type: str = "cube",
    position: list[float] | None = None,
    dimensions: list[float] | None = None,
) -> str:
    """Create a new component in Sketchup.

    type: one of "cube", "cylinder", "sphere", "cone".
    position: XYZ (inches) of the bounding-box minimum corner. Z extrusion is
        always +z, so a cube at position=[0,0,0] dimensions=[w,d,h] occupies
        z=[0, h] (no whim).
    dimensions: [width_x, depth_y, height_z] in inches.
    Returns id and bounds {min, max} so the caller can verify placement.
    """
    return _call_sketchup(
        ctx,
        "create_component",
        {
            "type": type,
            "position": position if position is not None else [0, 0, 0],
            "dimensions": dimensions if dimensions is not None else [1, 1, 1],
        },
    )


@mcp.tool()
def delete_component(ctx: Context, id: str | None = None, name: str | None = None) -> str:
    """Delete a component by entity ID or top-level group name.

    Provide exactly one of `id` (entity ID, as returned by create_*) or
    `name` (exact match against a top-level Group's name). Name lookup
    errors if zero or multiple groups match.
    """
    arguments: dict[str, Any] = {}
    if id is not None:
        arguments["id"] = id
    if name is not None:
        arguments["name"] = name
    return _call_sketchup(ctx, "delete_component", arguments)


@mcp.tool()
def transform_component(
    ctx: Context,
    id: str | None = None,
    name: str | None = None,
    move_to: list[float] | None = None,
    position: list[float] | None = None,
    rotation: list[float] | None = None,
    scale: list[float] | None = None,
) -> str:
    """Transform a component's placement.

    Provide exactly one of `id` (entity ID) or `name` (exact match against a
    top-level Group's name). Name lookup errors if zero or multiple groups match.

    move_to: absolute XYZ (inches) — translates the entity so its bounds.min
        lands at the given point. Use this for "place at" operations.
    position: relative translation (inches) applied to the existing transform.
        [0, 0, 0] is a no-op. Use this for "nudge by" operations.
    rotation: degrees about the entity's bounds-center, applied X then Y then Z.
    scale: per-axis scale factors about the entity's bounds-center.
    """
    arguments: dict[str, Any] = {}
    if id is not None:
        arguments["id"] = id
    if name is not None:
        arguments["name"] = name
    if move_to is not None:
        arguments["move_to"] = move_to
    if position is not None:
        arguments["position"] = position
    if rotation is not None:
        arguments["rotation"] = rotation
    if scale is not None:
        arguments["scale"] = scale
    return _call_sketchup(ctx, "transform_component", arguments)


@mcp.tool()
def batch_create(
    ctx: Context,
    operations: list[dict[str, Any]],
    transaction_name: str = "MCP batch",
) -> str:
    """Run many create / mutate / delete operations as a single SketchUp transaction.

    All operations execute inside one `model.start_operation` / `commit_operation`
    pair, so the whole batch is a single undo step. If any operation fails the
    transaction is rolled back via `model.abort_operation` — there is no partial
    state in the model. The error response identifies which operation failed.

    Each item in `operations` is a dict with an `op` key picking the action:

    Creates (return `{id, name, bounds}`):
      - `{"op": "cube",      "name", "position": [x,y,z], "dimensions": [dx,dy,dz], "material"?}`
      - `{"op": "cylinder",  "name", "position", "radius", "height", "material"?}`
      - `{"op": "sphere",    "name", "position", "radius",            "material"?}`
      - `{"op": "cone",      "name", "position", "radius", "height", "material"?}`
      - `{"op": "extrusion", "name", "profile", "extrude_axis", "extrude_from",
                                     "extrude_to", "material"?}`

    Mutations (return `{id, bounds}`):
      - `{"op": "translate", "id_or_name", "delta":  [dx, dy, dz]}` — relative
      - `{"op": "move_to",   "id_or_name", "target": [x,  y,  z]}` — absolute,
        anchors `bounds.min` to `target` (same semantics as
        `transform_component`'s `move_to`).

    Deletes (return `{id}`):
      - `{"op": "delete", "id_or_name"}`

    Replaces (return `{id, name, bounds}`):
      - `{"op": "replace", "id_or_name", "geometry": {...}, "recursive"?: bool}` —
        swaps the target's geometry in place; name, material, layer
        preserved. `geometry` matches the create-op shapes above. See
        replace_geometry for the recursive flag and entity-id semantics.

    `id_or_name` is an integer entityID or a string group name. A name that
    matches multiple groups errors — no ambiguous targets.

    operations: ordered list of operation dicts.
    transaction_name: label for SketchUp's undo stack (default "MCP batch").

    Returns `{success, results: [...], count}` with results in input order.
    """
    return _call_sketchup(
        ctx,
        "batch_create",
        {"transaction_name": transaction_name, "operations": operations},
    )


@mcp.tool()
def create_extrusion(
    ctx: Context,
    name: str,
    profile: list[list[float]],
    extrude_axis: str | None = None,
    extrude_from: float | None = None,
    extrude_to: float | None = None,
    holes: list[list[list[float]]] | None = None,
    plane: dict[str, list[float]] | None = None,
    extrude_depth: float | None = None,
    material: str | None = None,
) -> str:
    """Create a Group from a 2D profile extruded into a solid.

    Two extrusion modes; pick one:

    1. **Axis-aligned** (`extrude_axis` + `extrude_from` + `extrude_to`):
       The 2D profile is interpreted in the plane perpendicular to
       `extrude_axis`:

       - `"x"`: each `[a, b]` is `[y, z]`; face sits at `x=extrude_from`.
       - `"y"`: each `[a, b]` is `[x, z]`; face sits at `y=extrude_from`.
       - `"z"`: each `[a, b]` is `[x, y]`; face sits at `z=extrude_from`.

       `extrude_to` may be less than `extrude_from`; sign drives direction.

    2. **Arbitrary plane** (`plane` + `extrude_depth`): plane is
       `{"origin": [x,y,z], "normal": [nx,ny,nz]}`. The 2D profile is laid
       out on that plane via an internally-derived `(u, v)` basis; the
       solid extrudes `extrude_depth` inches along the plane's normal.
       Negative `extrude_depth` extrudes the opposite direction. Use this
       for sloped roof slabs, angled brackets, anything not axis-aligned.

    Vertex winding (CW vs CCW) doesn't matter — face direction is chosen
    from the requested extrude direction. The polygon is closed
    automatically (don't repeat the first vertex).

    `holes` is an optional list of 2D polygons (same coordinate system as
    `profile`) that become through-holes in the resulting solid. Each hole
    must lie entirely inside the outer profile and must not overlap any
    other hole.

    name: name assigned to the resulting Group.
    profile: ordered 2D vertices, length >= 3.
    extrude_axis: "x", "y", or "z". Mutually exclusive with `plane`.
    extrude_from / extrude_to: coordinates on the extrusion axis.
    holes: optional list of inner 2D polygons (each >= 3 vertices).
    plane: optional `{"origin", "normal"}` for arbitrary-plane extrusion.
        Mutually exclusive with `extrude_axis`.
    extrude_depth: signed inches along the plane's normal; required with `plane`.
    material: optional name or "#RRGGBB" hex applied to the resulting group.

    Returns `{id, bounds: {min, max}, success}` — same shape as create_component.
    """
    arguments: dict[str, Any] = {"name": name, "profile": profile}
    if extrude_axis is not None:
        arguments["extrude_axis"] = extrude_axis
    if extrude_from is not None:
        arguments["extrude_from"] = extrude_from
    if extrude_to is not None:
        arguments["extrude_to"] = extrude_to
    if holes is not None:
        arguments["holes"] = holes
    if plane is not None:
        arguments["plane"] = plane
    if extrude_depth is not None:
        arguments["extrude_depth"] = extrude_depth
    if material is not None:
        arguments["material"] = material
    return _call_sketchup(ctx, "create_extrusion", arguments)


@mcp.tool()
def replace_geometry(
    ctx: Context,
    geometry: dict[str, Any],
    id: str | None = None,
    name: str | None = None,
    recursive: bool = True,
) -> str:
    """Replace a Group's geometry in place, preserving name, material, and layer.

    Provide exactly one of `id` (entity ID) or `name` (exact match against a
    top-level Group's name). The resulting Group keeps the target's name,
    material, and layer; its bounds change to match the new geometry.

    Note: the entity ID changes (the old group is erased and a new one is
    created). Cache the returned `id` if you plan to address by ID rather
    than name.

    `geometry` is a dict picking the new shape:

      - `{"op": "cube",      "position": [x,y,z], "dimensions": [dx,dy,dz]}`
      - `{"op": "cylinder",  "position", "radius", "height"}`
      - `{"op": "sphere",    "position", "radius"}`
      - `{"op": "cone",      "position", "radius", "height"}`
      - `{"op": "extrusion", "profile", ... (see create_extrusion)}`

    A `material` key inside `geometry` is honored only if the target has no
    material to inherit (rare) — the target's own material always wins.

    By default (`recursive: true`) the call errors if the target Group
    contains nested sub-Groups or ComponentInstances, since those would be
    lost when the group is replaced. Pass `recursive: false` to acknowledge
    children-loss and proceed.

    Returns `{id, name, bounds: {min, max}, success}`.
    """
    arguments: dict[str, Any] = {"geometry": geometry, "recursive": recursive}
    if id is not None:
        arguments["id"] = id
    if name is not None:
        arguments["name"] = name
    return _call_sketchup(ctx, "replace_geometry", arguments)


@mcp.tool()
def inspect_geometry(
    ctx: Context,
    id: str | None = None,
    name: str | None = None,
    include_vertices: bool = True,
) -> str:
    """Return detailed geometry for a top-level Group.

    Provide exactly one of `id` (entity ID) or `name` (exact match against a
    top-level Group's name). Name lookup errors if zero or multiple groups
    match.

    Inspection is non-recursive: only faces in the target group's own
    entities are returned, not faces inside nested sub-groups.

    Response:
    ```
    {
      "id": 12345,
      "name": "WA Siding 1",
      "face_count": 10,
      "edge_count": 24,
      "is_solid": true,
      "faces": [
        {
          "normal": [0.0, -1.0, 0.0],
          "area": 3023.0,
          "loops": [
            {"role": "outer", "vertex_count": 4,
             "vertices": [[0,0,-0.375], [38,0,-0.375], [38,0,95.625], [0,0,95.625]]},
            {"role": "hole",  "vertex_count": 4,
             "vertices": [[8.25,0,36], [33.25,0,36], [33.25,0,61], [8.25,0,61]]}
          ]
        }, ...
      ]
    }
    ```

    Coordinates are in inches. Normals are rounded to 6 decimals, areas
    (square inches) to 2 decimals. `is_solid` is true iff every edge in the
    group bounds exactly 2 faces.

    include_vertices: when False, the `vertices` arrays are omitted from
        each loop — useful for cheap face/normal/loop-count summaries on
        large models. Loop counts and roles are still returned.
    """
    arguments: dict[str, Any] = {"include_vertices": include_vertices}
    if id is not None:
        arguments["id"] = id
    if name is not None:
        arguments["name"] = name
    return _call_sketchup(ctx, "inspect_geometry", arguments)


@mcp.tool()
def find_groups(
    ctx: Context,
    name_prefix: str | None = None,
    name_pattern: str | None = None,
    in_bounds: dict[str, list[float]] | None = None,
    parent_id: int | None = None,
    limit: int = 200,
    include_components: bool = False,
) -> str:
    """Query existing groups in the active model.

    All filters combine with AND. Returns a list of matches, each with
    `{id, name, bounds: {min, max}, layer, material}`, plus a `truncated`
    flag indicating whether the `limit` cap was hit.

    name_prefix: match groups whose name starts with this prefix.
    name_pattern: Ruby regex (as a string) matched against the group name.
        Mutually exclusive with `name_prefix`.
    in_bounds: {"min": [x,y,z], "max": [x,y,z]} (inches). Match groups whose
        bounds *intersect* this AABB — not strict containment.
    parent_id: restrict to children of a specific group (nested models).
        Top-level entities are searched if omitted. Non-group IDs error.
    limit: hard cap on results (default 200). `truncated: true` if reached.
    include_components: also include `Sketchup::ComponentInstance` (default
        is Groups only, matching this project's convention).
    """
    arguments: dict[str, Any] = {"limit": limit, "include_components": include_components}
    if name_prefix is not None:
        arguments["name_prefix"] = name_prefix
    if name_pattern is not None:
        arguments["name_pattern"] = name_pattern
    if in_bounds is not None:
        arguments["in_bounds"] = in_bounds
    if parent_id is not None:
        arguments["parent_id"] = parent_id
    return _call_sketchup(ctx, "find_groups", arguments)


@mcp.tool()
def get_selection(ctx: Context) -> str:
    """Get currently selected components"""
    return _call_sketchup(ctx, "get_selection", {})


@mcp.tool()
def set_material(ctx: Context, id: str, material: str) -> str:
    """Set material for a component"""
    return _call_sketchup(ctx, "set_material", {"id": id, "material": material})


@mcp.tool()
def export_scene(ctx: Context, format: str = "skp") -> str:
    """Export the current scene"""
    return _call_sketchup(ctx, "export", {"format": format})


@mcp.tool()
def create_mortise_tenon(
    ctx: Context,
    mortise_id: str,
    tenon_id: str,
    width: float = 1.0,
    height: float = 1.0,
    depth: float = 1.0,
    offset_x: float = 0.0,
    offset_y: float = 0.0,
    offset_z: float = 0.0,
) -> str:
    """Create a mortise and tenon joint between two components"""
    return _call_sketchup(
        ctx,
        "create_mortise_tenon",
        {
            "mortise_id": mortise_id,
            "tenon_id": tenon_id,
            "width": width,
            "height": height,
            "depth": depth,
            "offset_x": offset_x,
            "offset_y": offset_y,
            "offset_z": offset_z,
        },
    )


@mcp.tool()
def create_dovetail(
    ctx: Context,
    tail_id: str,
    pin_id: str,
    width: float = 1.0,
    height: float = 1.0,
    depth: float = 1.0,
    angle: float = 15.0,
    num_tails: int = 3,
    offset_x: float = 0.0,
    offset_y: float = 0.0,
    offset_z: float = 0.0,
) -> str:
    """Create a dovetail joint between two components"""
    return _call_sketchup(
        ctx,
        "create_dovetail",
        {
            "tail_id": tail_id,
            "pin_id": pin_id,
            "width": width,
            "height": height,
            "depth": depth,
            "angle": angle,
            "num_tails": num_tails,
            "offset_x": offset_x,
            "offset_y": offset_y,
            "offset_z": offset_z,
        },
    )


@mcp.tool()
def create_finger_joint(
    ctx: Context,
    board1_id: str,
    board2_id: str,
    width: float = 1.0,
    height: float = 1.0,
    depth: float = 1.0,
    num_fingers: int = 5,
    offset_x: float = 0.0,
    offset_y: float = 0.0,
    offset_z: float = 0.0,
) -> str:
    """Create a finger joint (box joint) between two components"""
    return _call_sketchup(
        ctx,
        "create_finger_joint",
        {
            "board1_id": board1_id,
            "board2_id": board2_id,
            "width": width,
            "height": height,
            "depth": depth,
            "num_fingers": num_fingers,
            "offset_x": offset_x,
            "offset_y": offset_y,
            "offset_z": offset_z,
        },
    )


@mcp.tool()
def eval_ruby(ctx: Context, code: str) -> str:
    """Evaluate arbitrary Ruby code in Sketchup"""
    return _call_sketchup(ctx, "eval_ruby", {"code": code})


def main():
    mcp.run()


if __name__ == "__main__":
    main()
