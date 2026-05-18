package tools

import (
	"context"
	"encoding/json"
	"sort"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// stubSender satisfies Sender for registration smoke-testing. The full
// FakeSender + handler matrix lives in Phase 3.
type stubSender struct{}

func (stubSender) SendCommand(string, map[string]any, any) (any, error) {
	return map[string]any{}, nil
}

func TestRegisterAll_ExposesExpectedToolNames(t *testing.T) {
	srv := mcp.NewServer(&mcp.Implementation{Name: "test", Version: "0"}, nil)
	RegisterAll(srv, stubSender{})

	clientT, serverT := mcp.NewInMemoryTransports()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sess, err := srv.Connect(ctx, serverT, nil)
	if err != nil {
		t.Fatalf("server connect: %v", err)
	}
	defer sess.Close()

	client := mcp.NewClient(&mcp.Implementation{Name: "tester", Version: "0"}, nil)
	cs, err := client.Connect(ctx, clientT, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	defer cs.Close()

	resp, err := cs.ListTools(ctx, &mcp.ListToolsParams{})
	if err != nil {
		t.Fatalf("list tools: %v", err)
	}
	got := make([]string, 0, len(resp.Tools))
	for _, tool := range resp.Tools {
		got = append(got, tool.Name)
	}
	sort.Strings(got)

	want := []string{
		"batch_create",
		"boolean_op",
		"closest_points",
		"create_component",
		"create_extrusion",
		"delete_component",
		"eval_ruby",
		"export_scene",
		"find_groups",
		"get_selection",
		"inspect_geometry",
		"intersect_ray",
		"mirror_component",
		"pattern_linear",
		"replace_geometry",
		"set_material",
		"transform_component",
		"validate_geometry",
	}

	if len(got) != len(want) {
		t.Fatalf("tool count: got %d (%v), want %d (%v)", len(got), got, len(want), want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("tool[%d]: got %q, want %q (full got=%v)", i, got[i], want[i], got)
		}
	}

	// Every registered tool needs a Description and a non-empty InputSchema
	// (both surface in the MCP client's tool picker / arg prompt).
	for _, tool := range resp.Tools {
		if tool.Description == "" {
			t.Errorf("tool %q: Description is empty", tool.Name)
		}
		if tool.InputSchema == nil {
			t.Errorf("tool %q: InputSchema is nil", tool.Name)
			continue
		}
		schema := toSchemaMap(t, tool.InputSchema)
		if schema["type"] == nil && schema["properties"] == nil {
			t.Errorf("tool %q: InputSchema has no type or properties", tool.Name)
		}
	}

	// Spot-check create_component carries its expected struct-derived fields.
	for _, tool := range resp.Tools {
		if tool.Name != "create_component" {
			continue
		}
		schema := toSchemaMap(t, tool.InputSchema)
		props, _ := schema["properties"].(map[string]any)
		if props == nil {
			t.Fatalf("create_component InputSchema has no properties")
		}
		for _, name := range []string{"type", "name", "position", "dimensions"} {
			if _, ok := props[name]; !ok {
				t.Errorf("create_component InputSchema missing property %q", name)
			}
		}
	}
}

// TestIntersectRaySchemaTargetIsTypedUnion guards the inputSchema for the
// intersect_ray tool's `target` field against the regression where it
// surfaces as the bare boolean schema `true`. JSON Schema 2020-12 permits
// that — `true` matches anything — but Zod-based MCP clients (including
// Claude Code) reject boolean property schemas, which then fails the whole
// tools/list call. Target should advertise a typed string|integer(|null)
// union instead.
func TestIntersectRaySchemaTargetIsTypedUnion(t *testing.T) {
	srv := mcp.NewServer(&mcp.Implementation{Name: "test", Version: "0"}, nil)
	RegisterAll(srv, stubSender{})

	clientT, serverT := mcp.NewInMemoryTransports()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sess, err := srv.Connect(ctx, serverT, nil)
	if err != nil {
		t.Fatalf("server connect: %v", err)
	}
	defer sess.Close()

	client := mcp.NewClient(&mcp.Implementation{Name: "tester", Version: "0"}, nil)
	cs, err := client.Connect(ctx, clientT, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	defer cs.Close()

	resp, err := cs.ListTools(ctx, &mcp.ListToolsParams{})
	if err != nil {
		t.Fatalf("list tools: %v", err)
	}

	var found bool
	for _, tool := range resp.Tools {
		if tool.Name != "intersect_ray" {
			continue
		}
		found = true
		// Marshal then re-parse so we see exactly what goes on the wire —
		// `true` as a JSON value would land here as a bool, not a map.
		b, err := json.Marshal(tool.InputSchema)
		if err != nil {
			t.Fatalf("marshal schema: %v", err)
		}
		var s struct {
			Properties map[string]json.RawMessage `json:"properties"`
		}
		if err := json.Unmarshal(b, &s); err != nil {
			t.Fatalf("unmarshal schema: %v", err)
		}
		raw, ok := s.Properties["target"]
		if !ok {
			t.Fatalf("intersect_ray.properties.target missing; properties=%v", s.Properties)
		}
		// Reject the boolean-schema form, which is what jsonschema-go emits
		// for an `any`-typed field and what Zod-based clients refuse.
		if string(raw) == "true" || string(raw) == "false" {
			t.Fatalf("intersect_ray.target: schema is bare bool %s; want object with type union", string(raw))
		}
		var prop map[string]any
		if err := json.Unmarshal(raw, &prop); err != nil {
			t.Fatalf("intersect_ray.target: schema not an object: %v (raw=%s)", err, string(raw))
		}
		types, _ := prop["type"].([]any)
		if len(types) == 0 {
			t.Fatalf("intersect_ray.target: schema has no type union; got %v", prop)
		}
		seen := map[string]bool{}
		for _, x := range types {
			if s, ok := x.(string); ok {
				seen[s] = true
			}
		}
		for _, want := range []string{"string", "integer"} {
			if !seen[want] {
				t.Errorf("intersect_ray.target.type: missing %q; got %v", want, types)
			}
		}
	}
	if !found {
		t.Fatal("intersect_ray tool not registered")
	}
}

// TestClosestPointsSchemaTargetsAreTypedUnion mirrors the intersect_ray
// regression guard for closest_points: the a / b target fields are `any`
// (string OR int) and would otherwise surface as bare boolean schemas that
// Zod-based MCP clients reject.
func TestClosestPointsSchemaTargetsAreTypedUnion(t *testing.T) {
	srv := mcp.NewServer(&mcp.Implementation{Name: "test", Version: "0"}, nil)
	RegisterAll(srv, stubSender{})

	clientT, serverT := mcp.NewInMemoryTransports()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sess, err := srv.Connect(ctx, serverT, nil)
	if err != nil {
		t.Fatalf("server connect: %v", err)
	}
	defer sess.Close()

	client := mcp.NewClient(&mcp.Implementation{Name: "tester", Version: "0"}, nil)
	cs, err := client.Connect(ctx, clientT, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	defer cs.Close()

	resp, err := cs.ListTools(ctx, &mcp.ListToolsParams{})
	if err != nil {
		t.Fatalf("list tools: %v", err)
	}

	var found bool
	for _, tool := range resp.Tools {
		if tool.Name != "closest_points" {
			continue
		}
		found = true
		b, err := json.Marshal(tool.InputSchema)
		if err != nil {
			t.Fatalf("marshal schema: %v", err)
		}
		var s struct {
			Properties map[string]json.RawMessage `json:"properties"`
		}
		if err := json.Unmarshal(b, &s); err != nil {
			t.Fatalf("unmarshal schema: %v", err)
		}
		for _, key := range []string{"a", "b"} {
			raw, ok := s.Properties[key]
			if !ok {
				t.Fatalf("closest_points.properties.%s missing; properties=%v", key, s.Properties)
			}
			if string(raw) == "true" || string(raw) == "false" {
				t.Fatalf("closest_points.%s: schema is bare bool %s; want object with type union", key, string(raw))
			}
			var prop map[string]any
			if err := json.Unmarshal(raw, &prop); err != nil {
				t.Fatalf("closest_points.%s: schema not an object: %v (raw=%s)", key, err, string(raw))
			}
			types, _ := prop["type"].([]any)
			if len(types) == 0 {
				t.Fatalf("closest_points.%s: schema has no type union; got %v", key, prop)
			}
			seen := map[string]bool{}
			for _, x := range types {
				if s, ok := x.(string); ok {
					seen[s] = true
				}
			}
			for _, want := range []string{"string", "integer"} {
				if !seen[want] {
					t.Errorf("closest_points.%s.type: missing %q; got %v", key, want, types)
				}
			}
		}
	}
	if !found {
		t.Fatal("closest_points tool not registered")
	}
}

func toSchemaMap(t *testing.T, raw any) map[string]any {
	t.Helper()
	b, err := json.Marshal(raw)
	if err != nil {
		t.Fatalf("marshal schema: %v", err)
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatalf("unmarshal schema: %v", err)
	}
	return m
}
