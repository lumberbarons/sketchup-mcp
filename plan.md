# SketchUp MCP Roadmap

A roadmap for a generic 3D-modeling MCP server on top of SketchUp.

Two motivating use cases shape the priorities:

- **Design-to-build** — sheds, framing, fixtures, layouts. Architectural
  scale, lots of repeated parts, joinery, dimensioned plans.
- **Design-to-print** — parametric parts, organic shapes, fittings,
  enclosures. Manifold solids exported to STL for slicing.

Both lean on the same core primitives; the divergence is mostly in
output (DAE/SKP for buildable plans vs. STL for printables) and in the
helpers layered on top.

## 1. Core primitives

The unit of work is a solid Group. Every primitive returns
`{id, name, bounds, manifold}` so callers can chain calls without a
follow-up inspect.

Status legend: ✅ shipped, 🔨 in progress (see beads), ⏳ planned.

- ✅ `create_component` — cube, cylinder, sphere, cone
- ✅ `create_extrusion` — extrude a 2D profile (with optional holes)
- ⏳ Torus / wedge / pyramid — common shapes that currently require
  `eval_ruby`
- ⏳ Parametric primitives (rounded box, hex prism)

## 2. Curves & sweeps

Solid generators driven by a profile and a path. These are the escape
hatch for shapes that don't fit a parametric primitive.

- 🔨 [sch-ufo] `create_revolution` — lathe primitive (vases, balusters,
  columns, finials)
- 🔨 [sch-vql] `create_sweep` — sweep a 2D profile along a 3D path
  (mug handles, moldings, pipes, cable routes)
- 🔨 [sch-eug] `create_polygon_mesh` — explicit vertex/face escape hatch
  for organic/parametric shapes that don't fit any other primitive

## 3. CSG

Constructive solid geometry on manifold Groups. SketchUp Pro's Solid
Tools back the core operations.

- ✅ `boolean_op` — union / subtract / intersect / outer_shell
- ⏳ Split along a plane
- ⏳ Shell (hollow with wall thickness)
- ⏳ Offset surface, chamfer, fillet

## 4. Patterns

Repetition via `Geom::Transformation` — saves callers from manual loops
through `eval_ruby`.

- 🔨 [sch-rla] `pattern_linear`, `pattern_circular`, `mirror`

## 5. Queries & inspection

Reading the model is just as important as writing it. Used to chain
operations: find the part, inspect its bounds, then call a follow-up.

- ✅ `find_groups` — search by name prefix / pattern / criteria
- ✅ `inspect_geometry` — geometry summary for a Group
- ✅ `get_selection` — what the user currently has selected
- ⏳ Volume / surface area / center of mass

## 6. Editing

- ✅ `transform_component` — move / rotate / scale
- ✅ `replace_geometry` — swap out a Group's contents
- ✅ `delete_component`
- ✅ `batch_create` — many primitives in a single Ruby transaction

## 7. Materials & appearance

- ✅ `set_material` — basic named colors
- ⏳ Textures and material libraries (wood species, metals, plastics)
- ⏳ Material properties (reflectivity, transparency)

## 8. Export

- ✅ `export_scene` — DAE / SKP / OBJ
- 🔨 [sch-bma] STL export verified sliceable end-to-end with a real
  slicer (PrusaSlicer / Cura / Orca)
- ⏳ DXF / 3MF / STEP

## 9. Escape hatch

- ✅ `eval_ruby` — trusted-client-only access to the full SketchUp Ruby
  API + filesystem. Used to prototype features before they get a
  dedicated tool.

## Domain-specific examples

Domain-specific helpers (joinery, lumber libraries, hardware,
dimensioning, plywood-sheet optimization) belong in `examples/` rather
than the core tool surface. They compose the primitives above. See
[sch-tjm] for the in-progress demotion of the upstream woodworking
tools.

## Non-goals (for now)

- Realistic rendering / animation — SketchUp's V-Ray, Twinmotion, and
  the LayOut documentation pipeline already cover this; we don't try to
  replicate it through MCP.
- Cost / weight / structural analysis — out of scope; the MCP exposes
  geometry, not engineering models.
