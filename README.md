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
   SketchupMCP Server version 0.1.17 starting up
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

* `create_component` - Create a new component with specified type, position, and dimensions
* `delete_component` - Remove a component from the scene by ID
* `transform_component` - Move, rotate, or scale a component
* `get_selection` - Get information about currently selected components
* `set_material` - Apply a material or color to a component
* `export_scene` - Export the current scene (default format: `skp`)
* `create_mortise_tenon` - Create a mortise-and-tenon joint between two components
* `create_dovetail` - Create a dovetail joint between two components
* `create_finger_joint` - Create a finger (box) joint between two components
* `eval_ruby` - Execute arbitrary Ruby code in SketchUp for advanced operations

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