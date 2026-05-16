// Package tools wires every MCP tool to the SketchUp Ruby server.
//
// Each tool has an input struct that produces the JSON schema the MCP client
// sees; handlers translate that struct into a Ruby-side `arguments` map and
// forward it through a Sender. Optional fields use pointer types or omitempty
// so unset fields are dropped from the forwarded map — the Ruby side treats
// "key absent" and "key=null" differently for several tools (notably
// delete_component, which decides id-vs-name lookup by key presence).
package tools

// CreateComponentInput backs the create_component tool.
//
// position / dimensions are forwarded as defaults when omitted (the Python
// server substitutes [0,0,0] and [1,1,1] respectively).
type CreateComponentInput struct {
	Type       string    `json:"type,omitempty"`
	Name       string    `json:"name,omitempty"`
	Position   []float64 `json:"position,omitempty"`
	Dimensions []float64 `json:"dimensions,omitempty"`
}

// DeleteComponentInput backs the delete_component tool.
//
// Exactly one of Id or Name should be supplied; the Ruby side errors on
// ambiguous targets.
type DeleteComponentInput struct {
	ID   *string `json:"id,omitempty"`
	Name *string `json:"name,omitempty"`
}

// TransformComponentInput backs the transform_component tool.
type TransformComponentInput struct {
	ID       *string    `json:"id,omitempty"`
	Name     *string    `json:"name,omitempty"`
	MoveTo   *[]float64 `json:"move_to,omitempty"`
	Position *[]float64 `json:"position,omitempty"`
	Rotation *[]float64 `json:"rotation,omitempty"`
	Scale    *[]float64 `json:"scale,omitempty"`
}

// BatchCreateInput backs the batch_create tool.
type BatchCreateInput struct {
	Operations      []map[string]any `json:"operations"`
	TransactionName string           `json:"transaction_name,omitempty"`
}

// CreateExtrusionInput backs the create_extrusion tool.
type CreateExtrusionInput struct {
	Name         string               `json:"name"`
	Profile      [][]float64          `json:"profile"`
	ExtrudeAxis  *string              `json:"extrude_axis,omitempty"`
	ExtrudeFrom  *float64             `json:"extrude_from,omitempty"`
	ExtrudeTo    *float64             `json:"extrude_to,omitempty"`
	Holes        [][][]float64        `json:"holes,omitempty"`
	Plane        map[string][]float64 `json:"plane,omitempty"`
	ExtrudeDepth *float64             `json:"extrude_depth,omitempty"`
	Material     *string              `json:"material,omitempty"`
}

// ReplaceGeometryInput backs the replace_geometry tool.
type ReplaceGeometryInput struct {
	Geometry  map[string]any `json:"geometry"`
	ID        *string        `json:"id,omitempty"`
	Name      *string        `json:"name,omitempty"`
	Recursive *bool          `json:"recursive,omitempty"`
}

// InspectGeometryInput backs the inspect_geometry tool.
type InspectGeometryInput struct {
	ID              *string `json:"id,omitempty"`
	Name            *string `json:"name,omitempty"`
	IncludeVertices *bool   `json:"include_vertices,omitempty"`
}

// FindGroupsInput backs the find_groups tool.
type FindGroupsInput struct {
	NamePrefix        *string              `json:"name_prefix,omitempty"`
	NamePattern       *string              `json:"name_pattern,omitempty"`
	InBounds          map[string][]float64 `json:"in_bounds,omitempty"`
	ParentID          *int64               `json:"parent_id,omitempty"`
	Limit             *int                 `json:"limit,omitempty"`
	IncludeComponents *bool                `json:"include_components,omitempty"`
	Recursive         *bool                `json:"recursive,omitempty"`
}

// GetSelectionInput is the (empty) input for the get_selection tool.
type GetSelectionInput struct{}

// SetMaterialInput backs the set_material tool.
type SetMaterialInput struct {
	ID       string `json:"id"`
	Material string `json:"material"`
}

// ExportSceneInput backs the export_scene tool.
type ExportSceneInput struct {
	Format string `json:"format,omitempty"`
}

// BooleanOpInput backs the boolean_op tool.
type BooleanOpInput struct {
	Operation       string `json:"operation"`
	TargetID        int64  `json:"target_id"`
	ToolID          int64  `json:"tool_id"`
	DeleteOriginals *bool  `json:"delete_originals,omitempty"`
}

// CreateMortiseTenonInput backs the create_mortise_tenon tool. Numeric fields
// use omitempty so the generated schema marks them optional; the handler
// substitutes the same defaults the Python wrapper used.
type CreateMortiseTenonInput struct {
	MortiseID string  `json:"mortise_id"`
	TenonID   string  `json:"tenon_id"`
	Width     float64 `json:"width,omitempty"`
	Height    float64 `json:"height,omitempty"`
	Depth     float64 `json:"depth,omitempty"`
	OffsetX   float64 `json:"offset_x,omitempty"`
	OffsetY   float64 `json:"offset_y,omitempty"`
	OffsetZ   float64 `json:"offset_z,omitempty"`
}

// CreateDovetailInput backs the create_dovetail tool.
type CreateDovetailInput struct {
	TailID   string  `json:"tail_id"`
	PinID    string  `json:"pin_id"`
	Width    float64 `json:"width,omitempty"`
	Height   float64 `json:"height,omitempty"`
	Depth    float64 `json:"depth,omitempty"`
	Angle    float64 `json:"angle,omitempty"`
	NumTails int     `json:"num_tails,omitempty"`
	OffsetX  float64 `json:"offset_x,omitempty"`
	OffsetY  float64 `json:"offset_y,omitempty"`
	OffsetZ  float64 `json:"offset_z,omitempty"`
}

// CreateFingerJointInput backs the create_finger_joint tool.
type CreateFingerJointInput struct {
	Board1ID   string  `json:"board1_id"`
	Board2ID   string  `json:"board2_id"`
	Width      float64 `json:"width,omitempty"`
	Height     float64 `json:"height,omitempty"`
	Depth      float64 `json:"depth,omitempty"`
	NumFingers int     `json:"num_fingers,omitempty"`
	OffsetX    float64 `json:"offset_x,omitempty"`
	OffsetY    float64 `json:"offset_y,omitempty"`
	OffsetZ    float64 `json:"offset_z,omitempty"`
}

// EvalRubyInput backs the eval_ruby tool.
type EvalRubyInput struct {
	Code string `json:"code"`
}
