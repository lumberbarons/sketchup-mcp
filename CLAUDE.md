# sketchup-mcp

Two-process bridge that lets MCP clients drive SketchUp: a Python MCP
server (`sketchup-mcp`) speaks JSON-RPC over a TCP socket to a Ruby
extension (`su_mcp`) that runs inside SketchUp itself.

## Navigation

| Directory | What | When to read |
| --- | --- | --- |
| `src/sketchup_mcp/` | Python MCP server. Defines tools (`@mcp.tool()`) and the `SketchupClient` that talks to the Ruby side over TCP. | Adding or changing an MCP tool, debugging client/server framing, changing connection behavior. |
| `su_mcp/` | SketchUp Ruby extension. `su_mcp.rb` is the loader; `su_mcp/main.rb` is the in-process TCP server and tool dispatcher. | Adding or changing the SketchUp-side handler for an MCP tool, debugging Ruby errors, modifying joinery code. |
| `tests/` | Pytest suite for the Python server. `test_sketchup_client.py` covers the TCP client; `test_server_tools.py` covers tool wiring. | Adding tests for new tools, reproducing client/server bugs without SketchUp running. |
| `examples/` | Ruby snippets bundled in `.py` wrappers, demonstrating what to send through `eval_ruby`. | Looking for reusable Ruby code to pass through `eval_ruby`, or writing a new demo. |
| `scripts/build_rbz.sh` | Build script that zips `su_mcp/` into `su_mcp_v<version>.rbz` for Extension Manager. Also runnable via `make rbz`. | Cutting a new extension build. |
| `pyproject.toml` | Python package metadata, dependencies, ruff config. Version lives here and in `server.py:__version__`. | Bumping the Python package version, adding a dependency. |
| `su_mcp/extension.json` | SketchUp extension metadata. Version lives here and is read by `build_rbz.sh`. | Bumping the extension version. |

## Common commands

```bash
make install      # uv sync with test + lint extras
make test         # pytest
make lint         # ruff check + ruff format --check
make format       # ruff check --fix + ruff format
make rbz          # build the SketchUp .rbz (runs scripts/build_rbz.sh)
uvx sketchup-mcp  # run the MCP server (expects extension on localhost:9876)
```

## Gotchas

- The Python and Ruby sides have **independent versions**. `pyproject.toml`
  / `server.py:__version__` is the MCP server version; `su_mcp/extension.json`
  is the extension version. Bump each on its own cadence.
- `SketchupClient` opens a fresh TCP connection per call — SketchUp closes
  the socket after each request, so reusing a socket will hang.
- `eval_ruby` runs arbitrary Ruby with full SketchUp API + filesystem
  access. Treat it as a trusted-client-only feature.
