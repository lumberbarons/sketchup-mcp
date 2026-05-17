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

Each operations item is a dict with an "op" key; see README for the
full op vocabulary (cube, cylinder, sphere, cone, extrusion, translate,
move_to, delete, replace). The whole batch is one undo step. Any failure
aborts the transaction — the model is unchanged.`,
	}, func(_ context.Context, _ *mcp.CallToolRequest, in BatchCreateInput) (*mcp.CallToolResult, any, error) {
		return callSketchup(s, "batch_create", in)
	})
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
		Name:        "export_scene",
		Description: "Export the current scene",
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

func registerEvalRuby(srv *mcp.Server, s Sender) {
	mcp.AddTool(srv, &mcp.Tool{
		Name:        "eval_ruby",
		Description: "Evaluate arbitrary Ruby code in Sketchup",
	}, func(_ context.Context, _ *mcp.CallToolRequest, in EvalRubyInput) (*mcp.CallToolResult, any, error) {
		return callSketchup(s, "eval_ruby", in)
	})
}
