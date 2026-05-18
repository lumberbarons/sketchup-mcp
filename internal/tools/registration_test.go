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
		"create_component",
		"create_extrusion",
		"delete_component",
		"eval_ruby",
		"export_scene",
		"find_groups",
		"get_selection",
		"inspect_geometry",
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
