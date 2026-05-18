# SketchUp MCP

SketchUp MCP connects SketchUp to MCP clients (Claude Desktop, Claude
Code, and any other Model Context Protocol client) through a small Go
server and a Ruby extension that runs inside SketchUp. The result is
prompt-assisted 3D modeling: ask the model to build, inspect, or
transform geometry and it drives SketchUp directly.

## Requirements

- SketchUp 2021 or newer (the extension uses `UI.start_timer` and
  modern Ruby APIs available in 2021+).
- macOS, Linux, or Windows — prebuilt binaries are published for
  darwin/arm64, darwin/amd64, linux/amd64, linux/arm64, and
  windows/amd64.

## Installation

### Quick install (macOS / Linux)

One command fetches the matching binary and `.rbz` from the latest release:

```bash
curl -fsSL https://raw.githubusercontent.com/lumberbarons/sketchup-mcp/main/install.sh | bash
```

This installs `sketchup-mcp` to `/usr/local/bin` (or `~/.local/bin` if
the former isn't writable) and drops `su_mcp_v<version>.rbz` into
`~/Downloads/`. The script prints next steps for installing the `.rbz`
in SketchUp. Pin a specific release with
`SKETCHUP_MCP_VERSION=vX.Y.Z`, or override paths with `INSTALL_DIR=`
and `RBZ_DIR=`.

### Manual install

Download the archive for your platform from the
[GitHub Releases](https://github.com/lumberbarons/sketchup-mcp/releases)
page, extract it, and put the `sketchup-mcp` binary somewhere on your
`PATH`. The binary is a single static file — no runtime needed.

Alternatively, if you have a recent Go toolchain installed:

```bash
go install github.com/lumberbarons/sketchup-mcp/cmd/sketchup-mcp@latest
```

### SketchUp extension

The quick-install script above downloads the `.rbz` for you. If you're
installing manually, grab `su_mcp_v<version>.rbz` from the
[release assets](https://github.com/lumberbarons/sketchup-mcp/releases),
or build it locally with `make rbz` (produces `su_mcp_v<version>.rbz`
in the repo root from `su_mcp/extension.json`).

Then in SketchUp:

1. Window → Extension Manager
2. Click "Install Extension" and select the `.rbz` file
3. Restart SketchUp

## Usage

### Starting the connection

1. In SketchUp, go to **Extensions > MCP Server > Start Server**. The
   extension listens on `localhost:9876`.
2. Start the MCP server in a terminal to verify the connection:
   ```bash
   sketchup-mcp
   ```
   On a successful probe you'll see log lines like:
   ```
   level=INFO msg="SketchupMCP server starting" version=X.Y.Z
   level=INFO msg="SketchUp reachable" host=localhost port=9876
   ```
   If the second line says "SketchUp not reachable", confirm step 1
   completed and that nothing else is bound to port 9876. Override
   the target with `--host` / `--port` if needed.
3. Stop the server with `Ctrl-C` once you're ready to launch it from
   your MCP client.

### Wiring into an MCP client

The server speaks MCP over stdio, so any MCP client can launch it.

**Claude Desktop** — add to `claude_desktop_config.json`:

```json
"mcpServers": {
    "sketchup": {
        "command": "/usr/local/bin/sketchup-mcp"
    }
}
```

**Claude Code** — from your shell:

```bash
claude mcp add sketchup /usr/local/bin/sketchup-mcp
```

Use the absolute path the install step produced (or wherever the
binary lives on your `PATH`).

### Example prompts

* "Create a simple house model with a roof and windows"
* "Get the current selection and tell me what's in it"
* "Make the selected component red"
* "Move the selected component 10 units up"
* "Export the current scene as a 3D model"
* "Create a complex arts and crafts cabinet using Ruby code"

## Tools

* `create_component` — Create a primitive (cube, cylinder, sphere, cone) at a position with given dimensions
* `create_extrusion` — Create a Group by extruding a 2D profile along an axis or along an arbitrary plane's normal
* `delete_component` — Remove a component by entity ID or top-level group name
* `transform_component` — Move, rotate, or scale a component, addressed by entity ID or top-level group name
* `replace_geometry` — Swap a group's geometry in place; preserves name, material, and layer
* `inspect_geometry` — Return per-face normals, areas, and loops (outer + holes) for a group
* `find_groups` — Query the model for groups by name prefix, regex, bounds intersection, or parent
* `batch_create` — Run many create / mutate / delete operations as one SketchUp transaction (one undo step)
* `boolean_op` — CSG via SketchUp Pro's Solid Tools (union, subtract, intersect, outer_shell) — produces a manifold solid
* `pattern_linear` — Replicate a Group along a vector (linear array) — typical for studs, rafters, fence posts
* `mirror_component` — Reflect a Group across a plane (bilateral symmetry counterpart to `pattern_linear`)
* `get_selection` — Get information about currently selected components
* `set_material` — Apply a material or color to a component
* `export_scene` — Export the current scene to skp/obj/dae/stl/png/jpg. With `format=png` it doubles as a visual snapshot tool; optional `width`/`height` and `camera={eye, target, up?, perspective?, fov?}` let an agent compose a specific framed shot at a context-friendly size, and the user's SketchUp camera is restored after the render
* `eval_ruby` — Execute arbitrary Ruby code in SketchUp for advanced operations

### Batching many operations

`batch_create` runs an array of operations as a single SketchUp transaction. The whole batch is one undo step, the wire round-trip happens once instead of per piece, and any failure aborts the transaction — the model is unchanged.

One-at-a-time (3 separate round trips, 3 separate undo steps):

```text
create_component({"type": "cube", "position": [0, 0, 0], "dimensions": [16, 16, 8]})
create_component({"type": "cube", "position": [24, 0, 0], "dimensions": [16, 16, 8]})
create_component({"type": "cube", "position": [48, 0, 0], "dimensions": [16, 16, 8]})
```

Batched (one round trip, one undo step, named groups):

```text
batch_create({
  "transaction_name": "Foundation blocks",
  "operations": [
    {"op": "cube", "name": "Block 1", "position": [0,  0, 0], "dimensions": [16, 16, 8]},
    {"op": "cube", "name": "Block 2", "position": [24, 0, 0], "dimensions": [16, 16, 8]},
    {"op": "cube", "name": "Block 3", "position": [48, 0, 0], "dimensions": [16, 16, 8]}
  ]
})
```

Mixing op kinds in one batch is the point — composes especially well with `find_groups` for "find these, then move them":

```text
batch_create({
  "operations": [
    {"op": "extrusion", "name": "Rafter W 1", "profile": [...], "extrude_axis": "y",
     "extrude_from": 0.0,   "extrude_to": 1.5},
    {"op": "extrusion", "name": "Rafter W 2", "profile": [...], "extrude_axis": "y",
     "extrude_from": 15.25, "extrude_to": 16.75},
    {"op": "translate", "id_or_name": "Ridge", "delta": [0, 0, 0.5]},
    {"op": "delete",    "id_or_name": "Old Fascia"}
  ]
})
```

`id_or_name` is an integer entityID or a string group name. If a name matches more than one group the batch aborts — no ambiguous targets.

### Extruded profiles

`create_extrusion` covers the most common shape in framing work — a 2D profile pushed along an axis — without dropping into `eval_ruby`. The 2D vertices are interpreted in the plane perpendicular to `extrude_axis`, and the face is auto-flipped so vertex winding doesn't matter.

Before — about 20 lines of `eval_ruby` for one sloped rafter:

```ruby
g = Sketchup.active_model.active_entities.add_group
g.name = "Rafter W 5"
face = g.entities.add_face(
  Geom::Point3d.new(-12, 15.25, 89.625),
  Geom::Point3d.new(59.25, 15.25, 125.25),
  Geom::Point3d.new(59.25, 15.25, 131.399),
  Geom::Point3d.new(-12, 15.25, 95.774)
)
face.reverse! if face.normal.y < 0
face.pushpull(1.5)
```

After — one call:

```text
create_extrusion({
  "name": "Rafter W 5",
  "profile": [[-12, 89.625], [59.25, 125.25], [59.25, 131.399], [-12, 95.774]],
  "extrude_axis": "y",
  "extrude_from": 15.25,
  "extrude_to": 16.75
})
```

`extrude_to` may be less than `extrude_from` (e.g. building a sloped stud top-down). An optional `material` argument applies a color or named material in the same call.

`holes` cuts through-cutouts into the extruded solid. Each hole is a 2D polygon in the same coordinate system as `profile`, must lie entirely inside the outer profile, and must not overlap any other hole:

```text
create_extrusion({
  "name": "Siding W1",
  "profile": [[0, 0], [38, 0], [38, 96], [0, 96]],
  "extrude_axis": "y",
  "extrude_from": 0,
  "extrude_to": 0.5,
  "holes": [[[8.25, 36], [33.25, 36], [33.25, 61], [8.25, 61]]]
})
```

For non-axis-aligned solids (sloped roof slabs, angled brackets), pass a `plane` (`origin` + `normal`) and `extrude_depth` instead of `extrude_axis`. The 2D profile is laid out on the plane and the solid extrudes along the plane's normal — negative `extrude_depth` extrudes the opposite direction:

```text
create_extrusion({
  "name": "Roof Sheathing W1",
  "profile": [[0, 0], [48, 0], [48, 96], [0, 96]],
  "plane": {"origin": [0, 0, 0], "normal": [0, -0.4472, 0.8944]},  # 6:12 pitch
  "extrude_depth": 0.625
})
```

### Discovering existing geometry

`find_groups` answers "what's already in the model?" without round-tripping through `eval_ruby`. Filters combine with AND; each match comes back with `id`, `name`, `bounds`, `layer`, and `material`. A `truncated: true` flag indicates results were capped at `limit` (default 200).

Typical queries:

* All Wall A pieces: `find_groups({"name_prefix": "WA "})`
* Just the common rafters (excluding doubled/fly rafters): `find_groups({"name_pattern": "^Rafter [WE] \\d+$"})`
* Everything that intersects the door rough-opening volume on Wall A: `find_groups({"in_bounds": {"min": [38, 0, 0], "max": [82, 3.5, 95]}})`

Compose with the name-based mutate ops to operate on the model without tracking IDs:

```text
find_groups({"name_prefix": "WA "})       # list the pieces
transform_component({"name": "WA Stud 3", # then mutate by name
                     "move_to": [12, 0, 0]})
```

`name_prefix` and `name_pattern` are mutually exclusive. Pass `parent_id` to scope the search into a nested group. By default only the direct children of the search root are scanned; pass `recursive=true` to descend into nested groups, and `include_components=true` to also descend into `ComponentInstance` definitions — useful when named groups live inside other groups. Bounds matching is intersection (not strict containment), since "what's near X?" is the more common need.

### Addressing entities: by ID or by name

`delete_component` and `transform_component` accept exactly one of:

* `id` — the integer entity ID returned by `create_*` calls. Cheapest and unambiguous; use it inside tight loops where the ID is fresh.
* `name` — exact match against a top-level Group's name (e.g. `"Ridge"`, `"Rafter W 5"`). Prefer this for human-driven edits where IDs are easy to lose track of. Lookup errors clearly if zero or multiple groups share the name — there is no silent first-match.

## How it works

Two processes, one socket:

1. **SketchUp extension** (`su_mcp/`) — a Ruby extension that runs inside
   SketchUp and listens on a TCP socket for tool calls.
2. **MCP server** (`cmd/sketchup-mcp/`) — a Go process that speaks MCP
   to your client over stdio and forwards each tool call to the
   extension as newline-terminated JSON-RPC 2.0 over TCP
   (default `localhost:9876`). A fresh connection is opened per call.

## Troubleshooting

* **Connection issues** — make sure both the SketchUp extension server and the MCP server are running.
* **Command failures** — check the Ruby Console in SketchUp for error messages.
* **Timeout errors** — try simplifying your requests or breaking them into smaller steps.

## Contributing

Contributions are welcome — please open a pull request.

## Acknowledgements

Big shoutout to [Blender MCP](https://github.com/ahujasid/blender-mcp) for the inspiration and structure.

## License

MIT
