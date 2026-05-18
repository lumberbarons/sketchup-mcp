package tools

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"sync/atomic"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// Sender is the subset of skpclient.Client the tool layer needs. Tests
// supply a recording fake; production wires through to a real Client.
type Sender interface {
	SendCommand(method string, params map[string]any, requestID any) (any, error)
}

// requestIDs supplies the JSON-RPC id forwarded to the Ruby server. The Ruby
// side echoes it back; we don't verify correlation since SketchUp serves one
// request per connection. Monotonic ids are nicer to read in logs.
var requestIDs atomic.Uint64

func nextRequestID() uint64 { return requestIDs.Add(1) }

// envelope is the JSON envelope every tool returns, matching the Python:
//
//	{"success": true,  "result": <payload>, "error": null}
//	{"success": false, "result": null,      "error": "<message>"}
type envelope struct {
	Success bool    `json:"success"`
	Result  any     `json:"result"`
	Error   *string `json:"error"`
}

// callSketchup forwards a tool call to the SketchUp Ruby server and wraps
// the result (or any failure) in the standard envelope.
//
// args may be any value that marshals to a JSON object (typically the
// tool's input struct). It is round-tripped through JSON so that the
// `arguments` payload sent on the wire is a clean map[string]any honoring
// omitempty on the source struct.
func callSketchup(s Sender, rubyTool string, args any) (*mcp.CallToolResult, any, error) {
	argsMap, err := argsToMap(args)
	if err != nil {
		slog.Error("tool failed", "tool", rubyTool, "err", err)
		return textResult(failureEnvelope(err.Error())), nil, nil
	}
	result, err := s.SendCommand(
		"tools/call",
		map[string]any{"name": rubyTool, "arguments": argsMap},
		nextRequestID(),
	)
	if err != nil {
		slog.Error("tool failed", "tool", rubyTool, "err", err)
		return textResult(failureEnvelope(err.Error())), nil, nil
	}
	return textResult(successEnvelope(slimMCPFrame(result))), nil, nil
}

// mcpFrameKeys are the wrapper fields the Ruby server adds to every
// successful tool response. callers don't need them — the structured
// payload lives in the "extras" merged alongside.
var mcpFrameKeys = map[string]bool{
	"content": true, "isError": true, "success": true, "resourceId": true,
}

// slimMCPFrame strips the Ruby server's MCP-frame wrapper from a tool
// result, returning just the structured payload the caller actually
// cares about. The Ruby side returns
//
//	{content: [{type: text, text: ...}], isError, success, resourceId, ...extras}
//
// where `extras` is the handler-specific payload (bounds, groups, entities,
// path, faces, ...). We promote `resourceId` to `id` for symmetry with the
// rest of the API, then return just the extras. When there are no extras,
// fall back to the content text so simple tools (eval_ruby) still work.
func slimMCPFrame(result any) any {
	m, ok := result.(map[string]any)
	if !ok {
		return result
	}
	_, hasContent := m["content"]
	_, hasSuccess := m["success"]
	if !hasContent || !hasSuccess {
		return result
	}
	extras := map[string]any{}
	for k, v := range m {
		if !mcpFrameKeys[k] {
			extras[k] = v
		}
	}
	if rid, ok := m["resourceId"]; ok && rid != nil {
		extras["id"] = rid
	}
	if len(extras) > 0 {
		return extras
	}
	if content, ok := m["content"].([]any); ok && len(content) > 0 {
		if cm, ok := content[0].(map[string]any); ok {
			if text, ok := cm["text"].(string); ok {
				return text
			}
		}
	}
	return result
}

// argsToMap normalises the forwarded arguments to JSON-shaped types
// (map[string]any / []any / json.Number-ish primitives). Always round-tripping
// through JSON — rather than short-circuiting when args is already a
// map[string]any — keeps the on-wire types stable: a forwarded []map[string]any
// becomes []any of map[string]any after the round trip, which is what the
// Ruby side will see across a real TCP boundary.
func argsToMap(args any) (map[string]any, error) {
	if args == nil {
		return map[string]any{}, nil
	}
	raw, err := json.Marshal(args)
	if err != nil {
		return nil, fmt.Errorf("marshal args: %w", err)
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil, fmt.Errorf("unmarshal args: %w", err)
	}
	if m == nil {
		m = map[string]any{}
	}
	return m, nil
}

func successEnvelope(result any) string {
	b, _ := json.Marshal(envelope{Success: true, Result: result, Error: nil})
	return string(b)
}

func failureEnvelope(message string) string {
	b, _ := json.Marshal(envelope{Success: false, Result: nil, Error: &message})
	return string(b)
}

func textResult(text string) *mcp.CallToolResult {
	return &mcp.CallToolResult{
		Content: []mcp.Content{&mcp.TextContent{Text: text}},
	}
}

// RegisterAll registers every tool against the supplied MCP server, routing
// invocations through s.
func RegisterAll(server *mcp.Server, s Sender) {
	registerCreateComponent(server, s)
	registerDeleteComponent(server, s)
	registerTransformComponent(server, s)
	registerBatchCreate(server, s)
	registerCreateExtrusion(server, s)
	registerReplaceGeometry(server, s)
	registerInspectGeometry(server, s)
	registerFindGroups(server, s)
	registerGetSelection(server, s)
	registerSetMaterial(server, s)
	registerExportScene(server, s)
	registerBooleanOp(server, s)
	registerPatternLinear(server, s)
	registerMirrorComponent(server, s)
	registerValidateGeometry(server, s)
	registerEvalRuby(server, s)
}

// --- tool handlers ----------------------------------------------------------

func registerCreateComponent(srv *mcp.Server, s Sender) {
	mcp.AddTool(srv, &mcp.Tool{
		Name: "create_component",
		Description: `Create a new component in Sketchup.

type: one of "cube", "cylinder", "sphere", "cone".
name: optional group name (e.g. "Floor Joist 3"); enables addressing
    the created entity by name in later calls.
position: XYZ (inches) of the bounding-box minimum corner. Z extrusion is
    always +z, so a cube at position=[0,0,0] dimensions=[w,d,h] occupies
    z=[0, h] (no whim).
dimensions: [width_x, depth_y, height_z] in inches.
Returns id and bounds {min, max} so the caller can verify placement.`,
	}, func(_ context.Context, _ *mcp.CallToolRequest, in CreateComponentInput) (*mcp.CallToolResult, any, error) {
		return callSketchup(s, "create_component", in)
	})
}

func registerDeleteComponent(srv *mcp.Server, s Sender) {
	mcp.AddTool(srv, &mcp.Tool{
		Name: "delete_component",
		Description: `Delete a component by entity ID or top-level group name.

Provide exactly one of id (entity ID, as returned by create_*) or name (exact
match against a top-level Group's name). Name lookup errors if zero or
multiple groups match.`,
	}, func(_ context.Context, _ *mcp.CallToolRequest, in DeleteComponentInput) (*mcp.CallToolResult, any, error) {
		return callSketchup(s, "delete_component", in)
	})
}

func registerTransformComponent(srv *mcp.Server, s Sender) {
	mcp.AddTool(srv, &mcp.Tool{
		Name: "transform_component",
		Description: `Transform a component's placement.

Provide exactly one of id (entity ID) or name (exact match against a
top-level Group's name). move_to anchors bounds.min to absolute XYZ;
position is a relative translation; rotation is degrees about bounds-center
(X then Y then Z); scale is per-axis factors about bounds-center.`,
	}, func(_ context.Context, _ *mcp.CallToolRequest, in TransformComponentInput) (*mcp.CallToolResult, any, error) {
		return callSketchup(s, "transform_component", in)
	})
}

func registerBatchCreate(srv *mcp.Server, s Sender) {
	mcp.AddTool(srv, &mcp.Tool{
		Name: "batch_create",
		Description: `Run many create / mutate / delete operations as a single SketchUp transaction.

Each operations item is a dict with an "op" key. The whole batch is one
undo step. Any failure aborts the transaction — the model is unchanged.

Create ops:
  - cube/cylinder/sphere/cone: name, position [x,y,z], dimensions [w,d,h]
    (cube), or radius + height (cylinder/cone) or radius (sphere). Optional
    material.
  - extrusion: name, profile [[x,y],...], plus extrude_axis+extrude_from+
    extrude_to OR plane+extrude_depth. Optional holes, material.

Mutate/delete ops address a group by "id" (entityID) or "name" (group
name) — same as transform_component/delete_component elsewhere. Legacy
"id_or_name" is still accepted for backwards compatibility:
  - translate: id|name, position [dx,dy,dz] (relative).
  - move_to:   id|name, target [x,y,z] (absolute bounds.min).
  - delete:    id|name.
  - replace:   id|name, geometry dict (see replace_geometry).

Replicate/reflect ops chain with create ops to atomically produce
symmetric or repeating structures in one transaction:
  - pattern_linear: id|name, vector [dx,dy,dz], count N. Optional
    include_source, name_template. Same semantics as the standalone
    pattern_linear tool. Sources created earlier in the batch can be
    addressed by name.
  - mirror: id|name, plus a mirror plane. Either axis "x"|"y"|"z" +
    offset (axis-aligned shorthand) OR plane {origin, normal}. Optional
    include_source (default true; pass false to flip the source in
    place), name_template.`,
	}, func(_ context.Context, _ *mcp.CallToolRequest, in BatchCreateInput) (*mcp.CallToolResult, any, error) {
		if err := validateBatchOps(in.Operations); err != nil {
			return textResult(failureEnvelope(err.Error())), nil, nil
		}
		return callSketchup(s, "batch_create", in)
	})
}

// validateBatchOps applies the same Go-side pre-flight validation the
// standalone tools run, for ops that have a typed standalone counterpart.
// Without this, a malformed pattern_linear or mirror op inside batch_create
// would only fail Ruby-side — after start_operation has run — wasting a
// transaction round-trip. Ops without a standalone validator (cube,
// extrusion, translate, …) are left to the Ruby side as before.
func validateBatchOps(ops []map[string]any) error {
	for i, op := range ops {
		opName, _ := op["op"].(string)
		var err error
		switch opName {
		case "pattern_linear":
			err = validatePatternLinearOp(op)
		case "mirror":
			err = validateMirrorOp(op)
		}
		if err != nil {
			return fmt.Errorf("operation #%d (%q): %s", i, opName, err.Error())
		}
	}
	return nil
}

// validatePatternLinearOp checks the wire-shape of a pattern_linear op
// inside batch_create. Mirrors the rules registerPatternLinear enforces on
// the typed input struct: count >= 1, vector length 3, vector non-zero.
// JSON numbers arrive as float64 over the MCP transport.
func validatePatternLinearOp(op map[string]any) error {
	countAny, ok := op["count"]
	if !ok {
		return fmt.Errorf("count is required")
	}
	count, ok := countAny.(float64)
	if !ok {
		return fmt.Errorf("count must be a number, got %T", countAny)
	}
	if int(count) < 1 {
		return fmt.Errorf("count must be >= 1, got %v", count)
	}
	vec, ok := op["vector"].([]any)
	if !ok {
		return fmt.Errorf("vector must be [dx,dy,dz]")
	}
	if len(vec) != 3 {
		return fmt.Errorf("vector must have 3 elements [dx,dy,dz], got %d", len(vec))
	}
	var dx, dy, dz float64
	for i, v := range vec {
		f, ok := v.(float64)
		if !ok {
			return fmt.Errorf("vector[%d] must be a number, got %T", i, v)
		}
		switch i {
		case 0:
			dx = f
		case 1:
			dy = f
		case 2:
			dz = f
		}
	}
	if dx == 0 && dy == 0 && dz == 0 {
		return fmt.Errorf("vector must be non-zero; got [0,0,0]")
	}
	return nil
}

// validateMirrorOp checks the wire-shape of a mirror op inside batch_create.
// Mirrors validateMirrorPlane's rules on the typed input struct: exactly one
// of (axis+offset) or plane; axis ∈ {x,y,z}; plane.{origin,normal} length 3;
// plane.normal non-zero.
func validateMirrorOp(op map[string]any) error {
	_, hasAxis := op["axis"]
	_, hasPlane := op["plane"]
	if hasAxis && hasPlane {
		return fmt.Errorf("provide exactly one of axis+offset or plane, not both")
	}
	if !hasAxis && !hasPlane {
		return fmt.Errorf("provide a mirror plane: axis+offset or plane {origin, normal}")
	}
	if hasAxis {
		axis, ok := op["axis"].(string)
		if !ok {
			return fmt.Errorf("axis must be a string")
		}
		switch axis {
		case "x", "y", "z":
		default:
			return fmt.Errorf("axis must be \"x\", \"y\", or \"z\"; got %q", axis)
		}
		if _, ok := op["offset"].(float64); !ok {
			return fmt.Errorf("offset (numeric) is required with axis")
		}
	}
	if hasPlane {
		plane, ok := op["plane"].(map[string]any)
		if !ok {
			return fmt.Errorf("plane must be a {origin, normal} object")
		}
		for _, key := range []string{"origin", "normal"} {
			vec, ok := plane[key].([]any)
			if !ok {
				return fmt.Errorf("plane.%s must be [x,y,z] numerics", key)
			}
			if len(vec) != 3 {
				return fmt.Errorf("plane.%s must have 3 elements, got %d", key, len(vec))
			}
			for i, v := range vec {
				if _, ok := v.(float64); !ok {
					return fmt.Errorf("plane.%s[%d] must be a number, got %T", key, i, v)
				}
			}
		}
		nrm := plane["normal"].([]any)
		if nrm[0].(float64) == 0 && nrm[1].(float64) == 0 && nrm[2].(float64) == 0 {
			return fmt.Errorf("plane.normal must be non-zero; got [0,0,0]")
		}
	}
	return nil
}

func registerCreateExtrusion(srv *mcp.Server, s Sender) {
	mcp.AddTool(srv, &mcp.Tool{
		Name: "create_extrusion",
		Description: `Create a Group from a 2D profile extruded into a solid.

Two extrusion modes; pick one:
1) extrude_axis + extrude_from + extrude_to — axis-aligned.
2) plane + extrude_depth — arbitrary plane with origin + normal.

Vertex winding doesn't matter; the polygon is closed automatically.
Optional holes (each a 2D polygon) become through-holes.`,
	}, func(_ context.Context, _ *mcp.CallToolRequest, in CreateExtrusionInput) (*mcp.CallToolResult, any, error) {
		return callSketchup(s, "create_extrusion", in)
	})
}

func registerReplaceGeometry(srv *mcp.Server, s Sender) {
	mcp.AddTool(srv, &mcp.Tool{
		Name: "replace_geometry",
		Description: `Replace a Group's geometry in place, preserving name, material, and layer.

The entity ID changes (old group erased, new group created). Cache the
returned id if you address by ID rather than name. With recursive=true
(default) errors if the target has nested sub-Groups or ComponentInstances;
pass recursive=false to acknowledge children-loss.

geometry shape: accepts either {"op": "cube"|...} or {"type": "cube"|...}.
"type" matches create_component's vocabulary; "op" matches batch_create's.
Pick whichever is convenient — they're interchangeable.`,
	}, func(_ context.Context, _ *mcp.CallToolRequest, in ReplaceGeometryInput) (*mcp.CallToolResult, any, error) {
		return callSketchup(s, "replace_geometry", in)
	})
}

func registerInspectGeometry(srv *mcp.Server, s Sender) {
	mcp.AddTool(srv, &mcp.Tool{
		Name: "inspect_geometry",
		Description: `Return detailed geometry for a top-level Group.

Returns face_count, edge_count, is_solid, and per-face normal / area /
loops (outer + holes). Non-recursive: only faces in the target group's
own entities are returned. Set include_vertices=false to drop vertex
arrays for cheap summaries on large models.`,
	}, func(_ context.Context, _ *mcp.CallToolRequest, in InspectGeometryInput) (*mcp.CallToolResult, any, error) {
		return callSketchup(s, "inspect_geometry", in)
	})
}

func registerFindGroups(srv *mcp.Server, s Sender) {
	mcp.AddTool(srv, &mcp.Tool{
		Name: "find_groups",
		Description: `Query existing groups in the active model.

All filters combine with AND. Each match: {id, name, bounds, layer,
material}. truncated is true if the limit cap was hit.

By default only entities directly under the search root are scanned;
pass recursive=true to also descend into nested Groups and (when
include_components=true) ComponentInstance definitions — useful when
named groups live inside other groups rather than at the top level.`,
	}, func(_ context.Context, _ *mcp.CallToolRequest, in FindGroupsInput) (*mcp.CallToolResult, any, error) {
		return callSketchup(s, "find_groups", in)
	})
}

func registerGetSelection(srv *mcp.Server, s Sender) {
	mcp.AddTool(srv, &mcp.Tool{
		Name:        "get_selection",
		Description: "Get currently selected components",
	}, func(_ context.Context, _ *mcp.CallToolRequest, in GetSelectionInput) (*mcp.CallToolResult, any, error) {
		return callSketchup(s, "get_selection", in)
	})
}

func registerSetMaterial(srv *mcp.Server, s Sender) {
	mcp.AddTool(srv, &mcp.Tool{
		Name:        "set_material",
		Description: "Set material for a component",
	}, func(_ context.Context, _ *mcp.CallToolRequest, in SetMaterialInput) (*mcp.CallToolResult, any, error) {
		return callSketchup(s, "set_material", in)
	})
}

func registerExportScene(srv *mcp.Server, s Sender) {
	mcp.AddTool(srv, &mcp.Tool{
		Name: "export_scene",
		Description: `Export the current scene to a file. With format="png"
or "jpg" this is also the *visual snapshot* tool — use it to see the
model between edits instead of working blind. inspect_geometry +
validate_geometry give numeric truth, but a PNG closes the loop when
"does it look right?" matters (e.g. checking that rake lookouts land
at the gable peaks, that a roof slope reads correctly, that pieces
aren't visually interpenetrating). Writes under the system temp dir
and returns the path; cheap enough to call after each change.

format: skp (default) | obj | dae | stl | png | jpg.

width / height: pixel dimensions, image formats only. Default 1920×1080.
When the PNG is being read back into an agent context, prefer something
smaller (800×600 is usually plenty for a "did it land where I expected"
check); reserve the 1920×1080 default for renders the user will look at.

camera: optional, image formats only. {eye:[x,y,z], target:[x,y,z],
up?:[x,y,z] (default z-up), perspective?:bool, fov?:deg}. Without
camera you get whatever view the user has in SketchUp; with camera
you compose a specific shot. The Ruby handler snapshots the active
view's camera, applies the supplied one, writes the image, then
restores the previous camera — the user's view is not mutated.
Supplying camera with a non-image format is rejected.

Examples:

  # Quick lightweight snapshot of the user's current view
  {"format": "png", "width": 800, "height": 600}

  # Iso from upper-front-left, framing the front gable
  {"format": "png", "width": 1024, "height": 768,
   "camera": {"eye": [-30, -30, 160], "target": [0, 0, 100]}}

  # Plan-view (top-down) snapshot, parallel projection
  {"format": "png", "width": 800, "height": 800,
   "camera": {"eye": [0, 0, 500], "target": [0, 0, 0],
              "up": [0, 1, 0], "perspective": false}}`,
	}, func(_ context.Context, _ *mcp.CallToolRequest, in ExportSceneInput) (*mcp.CallToolResult, any, error) {
		return callSketchup(s, "export", in)
	})
}

func registerBooleanOp(srv *mcp.Server, s Sender) {
	mcp.AddTool(srv, &mcp.Tool{
		Name: "boolean_op",
		Description: `CSG via SketchUp Pro's Solid Tools — produces a manifold solid group.

operation: union | subtract | intersect | outer_shell. Both inputs must be
manifold solid Groups. delete_originals=true (default) consumes both inputs.`,
	}, func(_ context.Context, _ *mcp.CallToolRequest, in BooleanOpInput) (*mcp.CallToolResult, any, error) {
		switch in.Operation {
		case "union", "subtract", "intersect", "outer_shell":
			// ok
		default:
			return textResult(failureEnvelope(
				"invalid operation: " + in.Operation +
					" (expected union, subtract, intersect, or outer_shell)",
			)), nil, nil
		}
		return callSketchup(s, "boolean_operation", in)
	})
}

func registerPatternLinear(srv *mcp.Server, s Sender) {
	mcp.AddTool(srv, &mcp.Tool{
		Name: "pattern_linear",
		Description: `Replicate a Group along a vector — a linear array.

Address the source by exactly one of id (entityID) or name (exact match
against a top-level Group name). Nested groups are supported when
addressed by id; copies are placed in the source's parent entities.
vector is a [dx,dy,dz] world-space offset applied per copy; count is the
number of *additional* copies to make (count=3 produces 3 new groups at
offsets 1×, 2×, 3× along vector — the source is unchanged by default).
Pass include_source=false to erase the original after copying.

Copy names: by default, copies auto-suffix to stay unique. If the source
name ends with an integer (e.g. "Floor Joist 1"), copies continue the
sequence ("Floor Joist 2", "Floor Joist 3", …); otherwise copies append
" 2", " 3", …. Existing top-level group names are skipped. Override with
name_template, which supports placeholders {src} (full source name),
{base} (source name with trailing integer stripped), {n} (auto-incremented
sequence number) and {i} (1-based copy index, 1..count).

Returns ids of the new groups in order, plus the count actually created.`,
	}, func(_ context.Context, _ *mcp.CallToolRequest, in PatternLinearInput) (*mcp.CallToolResult, any, error) {
		if in.Count < 1 {
			return textResult(failureEnvelope(
				fmt.Sprintf("count must be >= 1, got %d", in.Count),
			)), nil, nil
		}
		if len(in.Vector) != 3 {
			return textResult(failureEnvelope(
				fmt.Sprintf("vector must have 3 elements [dx,dy,dz], got %d", len(in.Vector)),
			)), nil, nil
		}
		if in.Vector[0] == 0 && in.Vector[1] == 0 && in.Vector[2] == 0 {
			return textResult(failureEnvelope(
				"vector must be non-zero; got [0,0,0]",
			)), nil, nil
		}
		return callSketchup(s, "pattern_linear", in)
	})
}

func registerMirrorComponent(srv *mcp.Server, s Sender) {
	mcp.AddTool(srv, &mcp.Tool{
		Name: "mirror_component",
		Description: `Reflect a Group across a plane — the bilateral-symmetry counterpart to pattern_linear.

Address the source by exactly one of id (entityID) or name (exact match
against a top-level Group name).

Specify the mirror plane in exactly one of two forms:
1) Axis-aligned shorthand: axis="x"|"y"|"z" + offset=<coordinate>.
   E.g. axis="x", offset=60.5 mirrors across the plane x=60.5.
2) Arbitrary plane: plane={origin: [x,y,z], normal: [x,y,z]}. The normal
   is normalized internally; it does not need to be unit length.

include_source defaults true: the source is preserved and a mirrored
copy is created in the source's parent entities. Pass false to flip the
source in place (no copy made) — useful for orienting a single piece
rather than producing a symmetric pair.

Copy naming follows the same convention as pattern_linear: by default
the new group continues the source's trailing-integer sequence
("Rafter W 5" → "Rafter W 6"), or appends " 2" otherwise. Override with
name_template, which supports {src}/{base}/{n}/{i} placeholders. A
template with no placeholders works as a literal new name (e.g.
"Rafter E 1").

Returns id, name, and bounds {min, max} for the resulting group.`,
	}, func(_ context.Context, _ *mcp.CallToolRequest, in MirrorComponentInput) (*mcp.CallToolResult, any, error) {
		if err := validateMirrorPlane(in); err != nil {
			return textResult(failureEnvelope(err.Error())), nil, nil
		}
		return callSketchup(s, "mirror_component", in)
	})
}

// validateMirrorPlane enforces the axis-vs-plane mutual exclusion on the Go
// side so malformed calls are rejected before crossing the wire. Numeric
// content (offset, normal magnitude) is validated on the Ruby side.
func validateMirrorPlane(in MirrorComponentInput) error {
	hasAxis := in.Axis != nil
	hasPlane := in.Plane != nil
	if hasAxis && hasPlane {
		return fmt.Errorf("provide exactly one of axis+offset or plane, not both")
	}
	if !hasAxis && !hasPlane {
		return fmt.Errorf("provide a mirror plane: axis+offset or plane {origin, normal}")
	}
	if hasAxis {
		switch *in.Axis {
		case "x", "y", "z":
		default:
			return fmt.Errorf("axis must be \"x\", \"y\", or \"z\"; got %q", *in.Axis)
		}
		if in.Offset == nil {
			return fmt.Errorf("offset is required with axis")
		}
	}
	if hasPlane {
		if len(in.Plane.Origin) != 3 {
			return fmt.Errorf("plane.origin must have 3 elements [x,y,z], got %d", len(in.Plane.Origin))
		}
		if len(in.Plane.Normal) != 3 {
			return fmt.Errorf("plane.normal must have 3 elements [x,y,z], got %d", len(in.Plane.Normal))
		}
		if in.Plane.Normal[0] == 0 && in.Plane.Normal[1] == 0 && in.Plane.Normal[2] == 0 {
			return fmt.Errorf("plane.normal must be non-zero; got [0,0,0]")
		}
	}
	return nil
}

func registerValidateGeometry(srv *mcp.Server, s Sender) {
	mcp.AddTool(srv, &mcp.Tool{
		Name: "validate_geometry",
		Description: `Run a batch of read-only positional assertions against the active model.

Useful for guarding invariants in stick-framed assemblies: corner-post lap
contact, header heights, stud alignment, no-interference between pieces.
The tool only reads — no entities are created, mutated, or deleted — so it
is safe to call after every edit as a regression check.

assertions is a list of tagged-union dicts. Each carries a "kind" plus an
optional "name" (a human-readable label used in the result; auto-generated
when absent). Default tolerance is 0.0625" (1/16 inch). Targets are
addressed by exact group name (string) or entity ID (integer).

Kinds:

- {kind:"bounds", target, min:[x,y,z]|null, max:[x,y,z]|null, tolerance?}
  Group's bounds.min / bounds.max must match within tolerance. A null on
  either side skips that side.

- {kind:"contact", a, b, axis:"x"|"y"|"z", direction:"+"|"-", tolerance?}
  Group "a"'s face on the given axis/direction must touch group "b"'s
  opposing face. E.g. axis="z", direction="-": a.bounds.min.z ≈ b.bounds.max.z.

- {kind:"aligned", targets:[...], axis:"x"|"y"|"z",
   side:"min"|"max"|"center", value:float|null, tolerance?}
  All targets must share the same coordinate on the named axis/side.
  When value is given, the shared coordinate must equal it within tolerance.

- {kind:"no_overlap", targets:[...], tolerance?}
  No two listed groups may have overlapping interiors. Penetration up to
  tolerance on every axis is treated as a tight joint, not an overlap.

Returns {results: [...], failed: <int>} where each result is
{name, kind, passed, detail}. detail is short on pass and includes the
observed value + delta on failure.`,
	}, func(_ context.Context, _ *mcp.CallToolRequest, in ValidateGeometryInput) (*mcp.CallToolResult, any, error) {
		if err := validateAssertions(in.Assertions); err != nil {
			return textResult(failureEnvelope(err.Error())), nil, nil
		}
		return callSketchup(s, "validate_geometry", in)
	})
}

// validateAssertions sanity-checks the assertion list before crossing the
// wire. Per-kind shape validation runs Ruby-side where it can also surface
// resolution errors (target not found, etc.) as a failed assertion rather
// than aborting the whole batch.
func validateAssertions(assertions []map[string]any) error {
	for i, a := range assertions {
		kindAny, ok := a["kind"]
		if !ok || kindAny == nil {
			return fmt.Errorf("assertion #%d: kind is required", i)
		}
		kind, ok := kindAny.(string)
		if !ok {
			return fmt.Errorf("assertion #%d: kind must be a string, got %T", i, kindAny)
		}
		switch kind {
		case "bounds", "contact", "aligned", "no_overlap":
		default:
			return fmt.Errorf("assertion #%d: unknown kind %q (expected bounds, contact, aligned, or no_overlap)", i, kind)
		}
	}
	return nil
}

func registerEvalRuby(srv *mcp.Server, s Sender) {
	mcp.AddTool(srv, &mcp.Tool{
		Name:        "eval_ruby",
		Description: "Evaluate arbitrary Ruby code in Sketchup",
	}, func(_ context.Context, _ *mcp.CallToolRequest, in EvalRubyInput) (*mcp.CallToolResult, any, error) {
		return callSketchup(s, "eval_ruby", in)
	})
}
