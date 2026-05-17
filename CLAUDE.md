# sketchup-mcp

Two-process bridge that lets MCP clients drive SketchUp: a Go MCP
server (`sketchup-mcp`) speaks JSON-RPC over a TCP socket to a Ruby
extension (`su_mcp`) that runs inside SketchUp itself.

## Navigation

| Directory | What | When to read |
| --- | --- | --- |
| `cmd/sketchup-mcp/` | Go entry point. Builds a `SketchupClient`, probes the extension, registers tools, and serves MCP over stdio. | Changing CLI flags, startup behavior, or version stamping. |
| `internal/skpclient/` | Go TCP client (`Client.SendCommand`, `Client.Probe`). Newline-terminated JSON-RPC 2.0, fresh connection per call, retry on connect failure only. | Debugging client/server framing or connection behavior. |
| `internal/tools/` | Tool registrations: per-tool input struct in `types.go`, `RegisterAll` + handlers in `tools.go`, in-memory MCP wiring tests in `tools_test.go`. | Adding or changing an MCP tool from the Go side. |
| `su_mcp/` | SketchUp Ruby extension. `su_mcp.rb` is the loader; `su_mcp/main.rb` is the in-process TCP server and tool dispatcher. | Adding or changing the SketchUp-side handler for an MCP tool, debugging Ruby errors, modifying joinery code. |
| `su_mcp/test/` | Minitest suite for pure-logic helpers in the Ruby extension. `test_helper.rb` stubs the SketchUp environment so `main.rb` loads without it. | Adding tests for new pure helpers (no `Sketchup.`/`Geom.`/`UI.` calls). Use `make test-ruby`. |
| `scripts/build_rbz.sh` | Build script that zips `su_mcp/` into `su_mcp_v<version>.rbz` for Extension Manager. Also runnable via `make rbz`. | Cutting a new extension build. |
| `.goreleaser.yaml` | Cross-compile config: produces darwin/linux/windows binaries on a `v*` tag push. | Adding a release target or changing archive layout. |
| `su_mcp/extension.json` | SketchUp extension metadata. Source `version` is the static placeholder `"local"`; the release workflow stamps it from the git tag at build time. | Changing extension metadata (name, description, etc.). |
| `Makefile` | Build/test/lint/rbz targets (run `make help` to list). | Looking for a command not covered by the 'Common commands' block. |

## Common commands

```bash
make build          # build ./bin/sketchup-mcp (Go MCP server)
make test-go        # Go test suite
make lint-go        # gofmt -l + go vet
make test-ruby      # Ruby minitest (no SketchUp required)
make format         # gofmt
make rbz            # build the SketchUp .rbz (runs scripts/build_rbz.sh)
./bin/sketchup-mcp  # run the MCP server (expects extension on localhost:9876)
```

## Gotchas

- The Go server and Ruby extension speak newline-terminated JSON-RPC 2.0
  framing. Don't refactor framing on one side without updating the other.
- Both versions are stamped at release time, not hand-bumped: the Go
  binary via goreleaser ldflags (`-X main.version={{ .Version }}`) and
  the Ruby extension by the release workflow rewriting
  `su_mcp/extension.json` from the git tag. Cutting a release is just
  `git tag vX.Y.Z && git push --tags`.
- The Go client opens a fresh TCP connection per call — SketchUp closes
  the socket after each request, so reusing a socket will hang.
- `eval_ruby` runs arbitrary Ruby with full SketchUp API + filesystem
  access. Treat it as a trusted-client-only feature.
- The Ruby minitest suite (`make test-ruby`) only covers helpers that don't
  touch the SketchUp API. To add a test, write the helper so it takes plain
  data (numbers, hashes, points) — not `Sketchup::Group` / `Geom::Point3d` —
  and add a file under `su_mcp/test/test_<helper>.rb` using the `FakePoint`,
  `FakeBounds`, `FakeVector`, and `TestServer` fixtures from `test_helper.rb`.
- Tool input structs in `internal/tools/types.go` use pointer types or
  `omitempty` for optional fields. The Ruby side branches on key presence
  for several tools (delete/transform/replace/inspect/find_groups and the
  create_extrusion axis-vs-plane mode), so never replace pointer types
  with value types or unset args will leak onto the wire as zero values
  rather than being omitted.


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
