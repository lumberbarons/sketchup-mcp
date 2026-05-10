# SketchUp MCP Examples

This directory holds Ruby code snippets that demonstrate what you can do
through the `eval_ruby` MCP tool. The snippets are bundled inside `.py`
files so they're easy to read and copy, but the canonical way to run
them is to feed the Ruby code to the `eval_ruby` tool through Claude
(or any other MCP client).

## Ruby Code Evaluation

`eval_ruby` accepts a string of Ruby code, runs it inside SketchUp's
Ruby interpreter, and returns the value of the last expression. Because
the code runs in-process, it has the full SketchUp Ruby API available
to it.

### Requirements

- SketchUp with the `su_mcp` extension installed (see the repo root
  `README.md` for installation)
- An MCP client connected to the `sketchup-mcp` server (e.g. Claude
  Desktop with the `mcpServers` entry from the root `README.md`)

### What's in this directory

| File | What it shows |
| --- | --- |
| `simple_ruby_eval.py` | Three short Ruby snippets: drawing a line, extruding a cube, and serializing model info to JSON. |
| `arts_and_crafts_cabinet.py` | A full Ruby program that builds an arts-and-crafts style cabinet with working doors. |
| `eval_ruby_demo.py` | A minimal Ruby snippet (cube creation) used as a smoke test for `eval_ruby`. |
| `ruby_tester.py` | Ad-hoc Ruby snippets used during development. |
| `behavior_tester.py` | Ad-hoc Ruby snippets used during development. |

> The `.py` wrappers in this directory currently use a stale client
> API and are not runnable as standalone Python scripts. Treat them as
> Ruby-snippet libraries: open the file, copy the string assigned to
> the `*_CODE` / `EXAMPLES` constants, and pass it to `eval_ruby`.

### Running a snippet through Claude

Once the MCP server is configured in Claude (see the root `README.md`),
ask Claude something like:

> Run this Ruby in SketchUp via `eval_ruby`:
> ```ruby
> model = Sketchup.active_model
> entities = model.active_entities
> line = entities.add_line([0,0,0], [100,100,100])
> line.entityID
> ```

Claude will invoke the `eval_ruby` tool and report the response from
SketchUp.

### Tips for Using `eval_ruby`

1. **Return values**: the last expression in your Ruby code becomes the
   tool's result. Make it something meaningful (an entity ID, a JSON
   string).
2. **Error handling**: Ruby errors are caught by the extension and
   surfaced in the response envelope as `success: false` with an
   `error` message.
3. **Undo grouping**: wrap model-mutating code in
   `model.start_operation(...)` / `model.commit_operation` so the user
   can undo it as a single step.
4. **Performance**: prefer one large Ruby script over many small ones —
   each call pays a TCP round-trip.
5. **Security**: `eval_ruby` runs arbitrary Ruby with full access to
   the SketchUp API and the host filesystem. Only enable it for
   trusted MCP clients.
