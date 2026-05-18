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

// CameraInput composes a SketchUp camera for export_scene image renders.
// Eye and Target are world-space [x,y,z] positions. Up is an optional
// [x,y,z] vector that defaults to z-up [0,0,1] on the Ruby side. Perspective
// and FOV (degrees) are optional camera-mode overrides.
type CameraInput struct {
	Eye         []float64 `json:"eye"`
	Target      []float64 `json:"target"`
	Up          []float64 `json:"up,omitempty"`
	Perspective *bool     `json:"perspective,omitempty"`
	FOV         *float64  `json:"fov,omitempty"`
}

// ExportSceneInput backs the export_scene tool.
//
// Width and Height are pixel dimensions, image formats only. The Ruby side
// defaults to 1920×1080 when omitted; callers feeding the PNG back into an
// LLM context window will usually want something smaller (e.g. 800×600).
//
// Camera is only honored for image formats (png/jpg/jpeg); supplying it with
// a non-image format is an error. When set, the Ruby handler snapshots the
// current view camera, applies the requested one, writes the image, then
// restores the previous camera so the user's view is unaffected.
type ExportSceneInput struct {
	Format string       `json:"format,omitempty"`
	Width  *int         `json:"width,omitempty"`
	Height *int         `json:"height,omitempty"`
	Camera *CameraInput `json:"camera,omitempty"`
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

// PatternLinearInput backs the pattern_linear tool.
//
// Address the source group by exactly one of ID or Name (same convention as
// transform_component / delete_component). Vector is a [dx,dy,dz] world-space
// translation applied per copy; Count is the number of *additional* copies to
// create (so a count of 3 produces 3 new groups at offsets 1×, 2×, 3×).
// IncludeSource defaults true on the Ruby side; pass false to erase the
// original after the copies are made. NameTemplate optionally overrides the
// auto-suffix naming default; see the tool description for placeholders.
type PatternLinearInput struct {
	ID            *string   `json:"id,omitempty"`
	Name          *string   `json:"name,omitempty"`
	Vector        []float64 `json:"vector"`
	Count         int       `json:"count"`
	IncludeSource *bool     `json:"include_source,omitempty"`
	NameTemplate  *string   `json:"name_template,omitempty"`
}

// MirrorPlane is the {origin, normal} form of the mirror plane.
type MirrorPlane struct {
	Origin []float64 `json:"origin"`
	Normal []float64 `json:"normal"`
}

// ValidateGeometryInput backs the validate_geometry tool.
//
// Each assertion is a tagged-union dict keyed by "kind" (bounds, contact,
// aligned, no_overlap). The remaining keys are kind-specific; Go-side checks
// the kind enum and lets the Ruby handler validate per-kind shape. Read-only —
// no entities are mutated.
type ValidateGeometryInput struct {
	Assertions []map[string]any `json:"assertions"`
}

// IntersectRayInput backs the intersect_ray tool.
//
// Origin and Direction are world-space [x,y,z]. Direction need not be unit
// length but must be non-zero. Target optionally restricts the hit to
// geometry inside a named group (string) or a specific group entity ID
// (numeric); when omitted, any visible geometry can match. MaxDistance caps
// the search distance in inches. IncludeBackFaces controls whether a hit
// where the ray strikes a face from behind (ray · face_normal_world > 0)
// counts; default false so callers get the usual "first front face" answer.
type IntersectRayInput struct {
	Origin           []float64 `json:"origin"`
	Direction        []float64 `json:"direction"`
	Target           any       `json:"target,omitempty"`
	MaxDistance      *float64  `json:"max_distance,omitempty"`
	IncludeBackFaces *bool     `json:"include_back_faces,omitempty"`
}

// ClosestPointsInput backs the closest_points tool.
//
// A and B address two groups by exact name (string) or entity ID (integer);
// the Ruby side resolves either form through resolve_validate_target, the
// same helper validate_geometry uses. Tolerance (inches) is the threshold
// for the "contact" classification — a surface gap within tolerance is
// treated as touching; default 0.0625" (1/16"), set by the Ruby side when
// the field is omitted.
type ClosestPointsInput struct {
	A         any      `json:"a,omitempty"`
	B         any      `json:"b,omitempty"`
	Tolerance *float64 `json:"tolerance,omitempty"`
}

// MirrorComponentInput backs the mirror_component tool.
//
// Address the source by exactly one of ID or Name. The mirror plane is given
// in one of two mutually exclusive forms: (1) axis-aligned shorthand —
// Axis="x"|"y"|"z" plus Offset, meaning "the plane perpendicular to that axis
// at that coordinate" (e.g. Axis="x", Offset=60.5 → x=60.5); or (2) arbitrary
// — Plane with origin + normal. IncludeSource defaults true; pass false to
// reflect the source in place (flip it) rather than producing a symmetric
// pair. NameTemplate uses the same {src}/{base}/{n}/{i} placeholders as
// pattern_linear — a template with no placeholders behaves as a literal new
// name for the mirrored copy.
type MirrorComponentInput struct {
	ID            *string      `json:"id,omitempty"`
	Name          *string      `json:"name,omitempty"`
	Axis          *string      `json:"axis,omitempty"`
	Offset        *float64     `json:"offset,omitempty"`
	Plane         *MirrorPlane `json:"plane,omitempty"`
	IncludeSource *bool        `json:"include_source,omitempty"`
	NameTemplate  *string      `json:"name_template,omitempty"`
}
