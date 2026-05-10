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
__version__ = "1.7.0"
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
def delete_component(ctx: Context, id: str) -> str:
    """Delete a component by ID"""
    return _call_sketchup(ctx, "delete_component", {"id": id})


@mcp.tool()
def transform_component(
    ctx: Context,
    id: str,
    move_to: list[float] | None = None,
    position: list[float] | None = None,
    rotation: list[float] | None = None,
    scale: list[float] | None = None,
) -> str:
    """Transform a component's placement.

    move_to: absolute XYZ (inches) — translates the entity so its bounds.min
        lands at the given point. Use this for "place at" operations.
    position: relative translation (inches) applied to the existing transform.
        [0, 0, 0] is a no-op. Use this for "nudge by" operations.
    rotation: degrees about the entity's bounds-center, applied X then Y then Z.
    scale: per-axis scale factors about the entity's bounds-center.
    """
    arguments: dict[str, Any] = {"id": id}
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
