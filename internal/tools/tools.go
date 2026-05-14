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
	return textResult(successEnvelope(result)), nil, nil
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
	registerCreateMortiseTenon(server, s)
	registerCreateDovetail(server, s)
	registerCreateFingerJoint(server, s)
	registerEvalRuby(server, s)
}

// --- tool handlers ----------------------------------------------------------

func registerCreateComponent(srv *mcp.Server, s Sender) {
	mcp.AddTool(srv, &mcp.Tool{
		Name: "create_component",
		Description: `Create a new component in Sketchup.

type: one of "cube", "cylinder", "sphere", "cone".
position: XYZ (inches) of the bounding-box minimum corner. Z extrusion is
    always +z, so a cube at position=[0,0,0] dimensions=[w,d,h] occupies
    z=[0, h] (no whim).
dimensions: [width_x, depth_y, height_z] in inches.
Returns id and bounds {min, max} so the caller can verify placement.`,
	}, func(_ context.Context, _ *mcp.CallToolRequest, in CreateComponentInput) (*mcp.CallToolResult, any, error) {
		t := in.Type
		if t == "" {
			t = "cube"
		}
		pos := in.Position
		if pos == nil {
			pos = []float64{0, 0, 0}
		}
		dim := in.Dimensions
		if dim == nil {
			dim = []float64{1, 1, 1}
		}
		return callSketchup(s, "create_component", map[string]any{
			"type": t, "position": pos, "dimensions": dim,
		})
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
		tx := in.TransactionName
		if tx == "" {
			tx = "MCP batch"
		}
		return callSketchup(s, "batch_create", map[string]any{
			"transaction_name": tx,
			"operations":       in.Operations,
		})
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
pass recursive=false to acknowledge children-loss.`,
	}, func(_ context.Context, _ *mcp.CallToolRequest, in ReplaceGeometryInput) (*mcp.CallToolResult, any, error) {
		recursive := true
		if in.Recursive != nil {
			recursive = *in.Recursive
		}
		args := map[string]any{"geometry": in.Geometry, "recursive": recursive}
		if in.ID != nil {
			args["id"] = *in.ID
		}
		if in.Name != nil {
			args["name"] = *in.Name
		}
		return callSketchup(s, "replace_geometry", args)
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
		incl := true
		if in.IncludeVertices != nil {
			incl = *in.IncludeVertices
		}
		args := map[string]any{"include_vertices": incl}
		if in.ID != nil {
			args["id"] = *in.ID
		}
		if in.Name != nil {
			args["name"] = *in.Name
		}
		return callSketchup(s, "inspect_geometry", args)
	})
}

func registerFindGroups(srv *mcp.Server, s Sender) {
	mcp.AddTool(srv, &mcp.Tool{
		Name: "find_groups",
		Description: `Query existing groups in the active model.

All filters combine with AND. Each match: {id, name, bounds, layer,
material}. truncated is true if the limit cap was hit.`,
	}, func(_ context.Context, _ *mcp.CallToolRequest, in FindGroupsInput) (*mcp.CallToolResult, any, error) {
		limit := 200
		if in.Limit != nil {
			limit = *in.Limit
		}
		includeComponents := false
		if in.IncludeComponents != nil {
			includeComponents = *in.IncludeComponents
		}
		args := map[string]any{"limit": limit, "include_components": includeComponents}
		if in.NamePrefix != nil {
			args["name_prefix"] = *in.NamePrefix
		}
		if in.NamePattern != nil {
			args["name_pattern"] = *in.NamePattern
		}
		if in.InBounds != nil {
			args["in_bounds"] = in.InBounds
		}
		if in.ParentID != nil {
			args["parent_id"] = *in.ParentID
		}
		result, _, _ := callSketchup(s, "find_groups", args)
		return slimFindGroupsEnvelope(result), nil, nil
	})
}

// slimFindGroupsEnvelope re-emits the find_groups envelope keeping only
// `groups` and `truncated`, matching the Python's post-processing.
func slimFindGroupsEnvelope(result *mcp.CallToolResult) *mcp.CallToolResult {
	if result == nil || len(result.Content) == 0 {
		return result
	}
	text, ok := result.Content[0].(*mcp.TextContent)
	if !ok {
		return result
	}
	var env envelope
	if err := json.Unmarshal([]byte(text.Text), &env); err != nil {
		return result
	}
	if !env.Success {
		return result
	}
	inner, ok := env.Result.(map[string]any)
	if !ok {
		inner = map[string]any{}
	}
	slim := map[string]any{
		"groups":    inner["groups"],
		"truncated": inner["truncated"],
	}
	if slim["groups"] == nil {
		slim["groups"] = []any{}
	}
	if slim["truncated"] == nil {
		slim["truncated"] = false
	}
	return textResult(successEnvelope(slim))
}

func registerGetSelection(srv *mcp.Server, s Sender) {
	mcp.AddTool(srv, &mcp.Tool{
		Name:        "get_selection",
		Description: "Get currently selected components",
	}, func(_ context.Context, _ *mcp.CallToolRequest, _ GetSelectionInput) (*mcp.CallToolResult, any, error) {
		return callSketchup(s, "get_selection", map[string]any{})
	})
}

func registerSetMaterial(srv *mcp.Server, s Sender) {
	mcp.AddTool(srv, &mcp.Tool{
		Name:        "set_material",
		Description: "Set material for a component",
	}, func(_ context.Context, _ *mcp.CallToolRequest, in SetMaterialInput) (*mcp.CallToolResult, any, error) {
		return callSketchup(s, "set_material", map[string]any{
			"id": in.ID, "material": in.Material,
		})
	})
}

func registerExportScene(srv *mcp.Server, s Sender) {
	mcp.AddTool(srv, &mcp.Tool{
		Name:        "export_scene",
		Description: "Export the current scene",
	}, func(_ context.Context, _ *mcp.CallToolRequest, in ExportSceneInput) (*mcp.CallToolResult, any, error) {
		format := in.Format
		if format == "" {
			format = "skp"
		}
		return callSketchup(s, "export", map[string]any{"format": format})
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
		deleteOriginals := true
		if in.DeleteOriginals != nil {
			deleteOriginals = *in.DeleteOriginals
		}
		return callSketchup(s, "boolean_operation", map[string]any{
			"operation":        in.Operation,
			"target_id":        in.TargetID,
			"tool_id":          in.ToolID,
			"delete_originals": deleteOriginals,
		})
	})
}

func registerCreateMortiseTenon(srv *mcp.Server, s Sender) {
	mcp.AddTool(srv, &mcp.Tool{
		Name:        "create_mortise_tenon",
		Description: "Create a mortise and tenon joint between two components",
	}, func(_ context.Context, _ *mcp.CallToolRequest, in CreateMortiseTenonInput) (*mcp.CallToolResult, any, error) {
		// Match Python defaults (width=height=depth=1.0, offsets=0.0): the
		// inbound zero-value floats already encode "default". Forward as-is.
		return callSketchup(s, "create_mortise_tenon", map[string]any{
			"mortise_id": in.MortiseID,
			"tenon_id":   in.TenonID,
			"width":      defaultFloat(in.Width, 1.0),
			"height":     defaultFloat(in.Height, 1.0),
			"depth":      defaultFloat(in.Depth, 1.0),
			"offset_x":   in.OffsetX,
			"offset_y":   in.OffsetY,
			"offset_z":   in.OffsetZ,
		})
	})
}

func registerCreateDovetail(srv *mcp.Server, s Sender) {
	mcp.AddTool(srv, &mcp.Tool{
		Name:        "create_dovetail",
		Description: "Create a dovetail joint between two components",
	}, func(_ context.Context, _ *mcp.CallToolRequest, in CreateDovetailInput) (*mcp.CallToolResult, any, error) {
		return callSketchup(s, "create_dovetail", map[string]any{
			"tail_id":   in.TailID,
			"pin_id":    in.PinID,
			"width":     defaultFloat(in.Width, 1.0),
			"height":    defaultFloat(in.Height, 1.0),
			"depth":     defaultFloat(in.Depth, 1.0),
			"angle":     defaultFloat(in.Angle, 15.0),
			"num_tails": defaultInt(in.NumTails, 3),
			"offset_x":  in.OffsetX,
			"offset_y":  in.OffsetY,
			"offset_z":  in.OffsetZ,
		})
	})
}

func registerCreateFingerJoint(srv *mcp.Server, s Sender) {
	mcp.AddTool(srv, &mcp.Tool{
		Name:        "create_finger_joint",
		Description: "Create a finger joint (box joint) between two components",
	}, func(_ context.Context, _ *mcp.CallToolRequest, in CreateFingerJointInput) (*mcp.CallToolResult, any, error) {
		return callSketchup(s, "create_finger_joint", map[string]any{
			"board1_id":   in.Board1ID,
			"board2_id":   in.Board2ID,
			"width":       defaultFloat(in.Width, 1.0),
			"height":      defaultFloat(in.Height, 1.0),
			"depth":       defaultFloat(in.Depth, 1.0),
			"num_fingers": defaultInt(in.NumFingers, 5),
			"offset_x":    in.OffsetX,
			"offset_y":    in.OffsetY,
			"offset_z":    in.OffsetZ,
		})
	})
}

func registerEvalRuby(srv *mcp.Server, s Sender) {
	mcp.AddTool(srv, &mcp.Tool{
		Name:        "eval_ruby",
		Description: "Evaluate arbitrary Ruby code in Sketchup",
	}, func(_ context.Context, _ *mcp.CallToolRequest, in EvalRubyInput) (*mcp.CallToolResult, any, error) {
		return callSketchup(s, "eval_ruby", map[string]any{"code": in.Code})
	})
}

func defaultFloat(v, fallback float64) float64 {
	if v == 0 {
		return fallback
	}
	return v
}

func defaultInt(v, fallback int) int {
	if v == 0 {
		return fallback
	}
	return v
}
