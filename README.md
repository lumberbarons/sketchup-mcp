# SketchupMCP - Sketchup Model Context Protocol Integration

SketchupMCP connects Sketchup to Claude AI through the Model Context Protocol (MCP), allowing Claude to directly interact with and control Sketchup. This integration enables prompt-assisted 3D modeling, scene creation, and manipulation in Sketchup.

Big Shoutout to [Blender MCP](https://github.com/ahujasid/blender-mcp) for the inspiration and structure.

## Features

* **Two-way communication**: Connect Claude AI to Sketchup through a TCP socket connection
* **Component manipulation**: Create, modify, delete, and transform components in Sketchup
* **Material control**: Apply and modify materials and colors
* **Scene inspection**: Get detailed information about the current Sketchup scene
* **Selection handling**: Get and manipulate selected components
* **Ruby code evaluation**: Execute arbitrary Ruby code directly in SketchUp for advanced operations

## Components

The system consists of two main components:

1. **Sketchup Extension**: A Sketchup extension that creates a TCP server within Sketchup to receive and execute commands
2. **MCP Server (`sketchup_mcp/server.py`)**: A Python server that implements the Model Context Protocol and connects to the Sketchup extension

## Requirements

- SketchUp 2021 or newer (the extension uses `UI.start_timer` and
  modern Ruby APIs available in 2021+)
- Python 3.10 or newer
- macOS or Windows — both are supported. The install hints below show
  Homebrew commands; on Windows use the equivalent step linked in
  each tool's docs.

## Installation

### Python Packaging

We're using uv, so you'll need to install it. On macOS:

```bash
brew install uv
```

For other platforms see the [uv install docs](https://docs.astral.sh/uv/getting-started/installation/).

### Sketchup Extension

1. Build the `.rbz` from this repo:
   ```bash
   make rbz
   ```
   This runs `scripts/build_rbz.sh` and produces `su_mcp_v<version>.rbz`
   in the repo root (the version comes from `su_mcp/extension.json`).
2. In Sketchup, go to Window > Extension Manager
3. Click "Install Extension" and select the `.rbz` file you just built
4. Restart Sketchup

## Usage

### Starting the Connection

1. In Sketchup, go to Extensions > SketchupMCP > Start Server. The
   extension listens on `localhost:9876`.
2. Start the MCP server in a terminal so you can verify the
   connection before wiring it up to a client:
   ```bash
   uvx sketchup-mcp
   ```
   On a successful probe you'll see a log line like:
   ```
   SketchupMCP Server version X.Y.Z starting up
   SketchUp reachable at localhost:9876
   ```
   If the second line says "SketchUp not reachable", confirm step 1
   completed and that nothing else is bound to port 9876.
3. Leave the server running, or stop it with `Ctrl-C` once you're
   ready to launch it from your MCP client (see below).

### Using with Claude

Configure Claude to use the MCP server by adding the following to your Claude configuration:

```json
    "mcpServers": {
        "sketchup": {
            "command": "uvx",
            "args": [
                "sketchup-mcp"
            ]
        }
    }
```

This will pull the [latest from PyPI](https://pypi.org/project/sketchup-mcp/)

Once connected, Claude can interact with Sketchup using the following capabilities:

#### Tools

* `batch_create` - Run many create / mutate / delete operations as one SketchUp transaction (one undo step)
* `create_component` - Create a new component with specified type, position, and dimensions
* `create_extrusion` - Create a Group by extruding a 2D profile along x, y, or z (sloped tops, parallelogram rafters, fascia boards, etc.)
* `delete_component` - Remove a component from the scene by entity ID or top-level group name
* `transform_component` - Move, rotate, or scale a component, addressed by entity ID or top-level group name
* `find_groups` - Query the model for groups by name prefix, regex, bounds intersection, or parent
* `inspect_geometry` - Return per-face normals, areas, and loops (outer + holes) for a group
* `replace_geometry` - Swap a group's geometry in place; preserves name, material, and layer
* `get_selection` - Get information about currently selected components
* `set_material` - Apply a material or color to a component
* `export_scene` - Export the current scene (default format: `skp`)
* `create_mortise_tenon` - Create a mortise-and-tenon joint between two components
* `create_dovetail` - Create a dovetail joint between two components
* `create_finger_joint` - Create a finger (box) joint between two components
* `eval_ruby` - Execute arbitrary Ruby code in SketchUp for advanced operations

#### Batching many operations

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

#### Extruded profiles

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

#### Discovering existing geometry

`find_groups` answers "what's already in the model?" without round-tripping through `eval_ruby`. Filters combine with AND; each match comes back with `id`, `name`, `bounds`, `layer`, and `material`. A `truncated: true` flag indicates results were capped at `limit` (default 200).

Typical queries:

* All Wall A pieces: `find_groups({"name_prefix": "WA "})`
* Just the common rafters (excluding doubled/fly rafters): `find_groups({"name_pattern": "^Rafter [WE] \\d+$"})`
* Everything that intersects the door rough-opening volume on Wall A: `find_groups({"in_bounds": {"min": [38, 0, 0], "max": [82, 3.5, 95]}})`

Compose with the name-based mutate ops to operate on the model without tracking IDs:

```text
find_groups({"name_prefix": "WA "})       # list the pieces
transform_component({"name": "Ridge",     # then mutate by name
                     "move_to": [0, 0, 96]})
```

`name_prefix` and `name_pattern` are mutually exclusive. Pass `parent_id` to scope the search into a nested group. Bounds matching is intersection (not strict containment), since "what's near X?" is the more common need.

#### Addressing entities: by ID or by name

`delete_component` and `transform_component` accept exactly one of:

* `id` — the integer entity ID returned by `create_*` calls. Cheapest and unambiguous; use it inside tight loops where the ID is fresh.
* `name` — exact match against a top-level Group's name (e.g. `"Ridge"`, `"Rafter W 5"`). Prefer this for human-driven edits where IDs are easy to lose track of. Lookup errors clearly if zero or multiple groups share the name — there is no silent first-match.

### Example Commands

Here are some examples of what you can ask Claude to do:

* "Create a simple house model with a roof and windows"
* "Get the current selection and tell me what's in it"
* "Make the selected component red"
* "Move the selected component 10 units up"
* "Export the current scene as a 3D model"
* "Join those two boards with a dovetail joint"
* "Create a complex arts and crafts cabinet using Ruby code"

## Troubleshooting

* **Connection issues**: Make sure both the Sketchup extension server and the MCP server are running
* **Command failures**: Check the Ruby Console in Sketchup for error messages
* **Timeout errors**: Try simplifying your requests or breaking them into smaller steps

## Technical Details

### Communication Protocol

The system uses a simple JSON-based protocol over TCP sockets:

* **Commands** are sent as JSON objects with a `type` and optional `params`
* **Responses** are JSON objects with a `status` and `result` or `message`

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

MIT 