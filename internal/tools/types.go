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
// All fields use omitempty so unset values are absent on the wire; the Ruby
// server supplies the canonical defaults (type="cube", position=[0,0,0],
// dimensions=[1,1,1]).
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

// EvalRubyInput backs the eval_ruby tool.
type EvalRubyInput struct {
	Code string `json:"code"`
}
