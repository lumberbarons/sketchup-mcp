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
| `su_mcp/test/` | Minitest suite for pure-logic helpers in the Ruby extension. `test_helper.rb` stubs the SketchUp environment so `main.rb` loads without it. | Adding tests for new pure helpers (no `Sketchup.`/`Geom.`/`UI.` calls). Use `make test-ruby`. |
| `examples/` | Ruby snippets bundled in `.py` wrappers, demonstrating what to send through `eval_ruby`. | Looking for reusable Ruby code to pass through `eval_ruby`, or writing a new demo. |
| `scripts/build_rbz.sh` | Build script that zips `su_mcp/` into `su_mcp_v<version>.rbz` for Extension Manager. Also runnable via `make rbz`. | Cutting a new extension build. |
| `pyproject.toml` | Python package metadata, dependencies, ruff config. Version lives here and in `server.py:__version__`. | Bumping the Python package version, adding a dependency. |
| `su_mcp/extension.json` | SketchUp extension metadata. Version lives here and is read by `build_rbz.sh`. | Bumping the extension version. |

## Common commands

```bash
make install      # uv sync with test + lint extras
make test         # pytest
make test-ruby    # Ruby minitest (no SketchUp required)
make lint         # ruff check + ruff format --check
make format       # ruff check --fix + ruff format
make rbz          # build the SketchUp .rbz (runs scripts/build_rbz.sh)
uvx sketchup-mcp  # run the MCP server (expects extension on localhost:9876)
```

## Gotchas

- The Python and Ruby sides share a **single version**. Bump all three
  together: `pyproject.toml`, `src/sketchup_mcp/server.py:__version__`, and
  `su_mcp/extension.json`. (`__init__.py` re-exports `__version__` from
  `server.py`; `su_mcp/package.rb` reads `extension.json`.)
- `SketchupClient` opens a fresh TCP connection per call — SketchUp closes
  the socket after each request, so reusing a socket will hang.
- `eval_ruby` runs arbitrary Ruby with full SketchUp API + filesystem
  access. Treat it as a trusted-client-only feature.
- The Ruby minitest suite (`make test-ruby`) only covers helpers that don't
  touch the SketchUp API. To add a test, write the helper so it takes plain
  data (numbers, hashes, points) — not `Sketchup::Group` / `Geom::Point3d` —
  and add a file under `su_mcp/test/test_<helper>.rb` using the `FakePoint`,
  `FakeBounds`, `FakeVector`, and `TestServer` fixtures from `test_helper.rb`.


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
