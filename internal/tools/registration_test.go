package tools

import (
	"context"
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

func TestRegisterAll_ExposesTheSixteenToolNames(t *testing.T) {
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
		"create_dovetail",
		"create_extrusion",
		"create_finger_joint",
		"create_mortise_tenon",
		"delete_component",
		"eval_ruby",
		"export_scene",
		"find_groups",
		"get_selection",
		"inspect_geometry",
		"replace_geometry",
		"set_material",
		"transform_component",
	}

	if len(got) != len(want) {
		t.Fatalf("tool count: got %d (%v), want %d (%v)", len(got), got, len(want), want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("tool[%d]: got %q, want %q (full got=%v)", i, got[i], want[i], got)
		}
	}
}
