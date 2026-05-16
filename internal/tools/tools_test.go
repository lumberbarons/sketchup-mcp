// End-to-end tests for the @AddTool registrations. Each test drives the
// MCP server through an in-memory transport (no sockets, no SketchUp) and
// asserts both:
//
//  1. The exact arguments the tool forwards to Sender.SendCommand — this
//     catches typos in argument names, missing default substitutions, and
//     dropped-vs-omitted keys.
//  2. The {success, result, error} JSON envelope returned to the MCP client.
package tools

import (
	"context"
	"encoding/json"
	"errors"
	"maps"
	"strings"
	"sync"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// FakeSender records every send_command call instead of opening a socket.
// Tests configure NextResult / NextError before invoking a tool.
type FakeSender struct {
	mu         sync.Mutex
	Calls      []FakeCall
	NextResult any
	NextError  error
}

type FakeCall struct {
	Method    string
	Params    map[string]any
	RequestID any
}

func (f *FakeSender) SendCommand(method string, params map[string]any, requestID any) (any, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.Calls = append(f.Calls, FakeCall{Method: method, Params: params, RequestID: requestID})
	if f.NextError != nil {
		return nil, f.NextError
	}
	if f.NextResult == nil {
		return map[string]any{}, nil
	}
	return f.NextResult, nil
}

func (f *FakeSender) lastCall(t *testing.T) FakeCall {
	t.Helper()
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.Calls) == 0 {
		t.Fatal("no SendCommand calls recorded")
	}
	return f.Calls[len(f.Calls)-1]
}

func (f *FakeSender) lastToolName(t *testing.T) string {
	t.Helper()
	name, _ := f.lastCall(t).Params["name"].(string)
	return name
}

func (f *FakeSender) lastArguments(t *testing.T) map[string]any {
	t.Helper()
	args, ok := f.lastCall(t).Params["arguments"].(map[string]any)
	if !ok {
		t.Fatalf("arguments missing or wrong type: %v", f.lastCall(t).Params)
	}
	return args
}

// session wires a FakeSender to an in-memory MCP server + client pair.
type session struct {
	ctx    context.Context
	client *mcp.ClientSession
	fake   *FakeSender
	cancel func()
}

func newSession(t *testing.T) *session {
	t.Helper()
	fake := &FakeSender{}
	srv := mcp.NewServer(&mcp.Implementation{Name: "test", Version: "0"}, nil)
	RegisterAll(srv, fake)

	clientT, serverT := mcp.NewInMemoryTransports()
	ctx, cancel := context.WithCancel(context.Background())

	ss, err := srv.Connect(ctx, serverT, nil)
	if err != nil {
		t.Fatalf("server connect: %v", err)
	}
	client := mcp.NewClient(&mcp.Implementation{Name: "tester", Version: "0"}, nil)
	cs, err := client.Connect(ctx, clientT, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}

	t.Cleanup(func() {
		_ = cs.Close()
		_ = ss.Close()
		cancel()
	})

	return &session{ctx: ctx, client: cs, fake: fake, cancel: cancel}
}

func (s *session) call(t *testing.T, tool string, args any) *mcp.CallToolResult {
	t.Helper()
	res, err := s.client.CallTool(s.ctx, &mcp.CallToolParams{Name: tool, Arguments: args})
	if err != nil {
		t.Fatalf("call %s: %v", tool, err)
	}
	return res
}

type respEnvelope struct {
	Success bool `json:"success"`
	Result  any  `json:"result"`
	Error   any  `json:"error"`
}

func envelopeOf(t *testing.T, result *mcp.CallToolResult) respEnvelope {
	t.Helper()
	if len(result.Content) == 0 {
		t.Fatal("result content empty")
	}
	text, ok := result.Content[0].(*mcp.TextContent)
	if !ok {
		t.Fatalf("content[0] type %T (want TextContent)", result.Content[0])
	}
	var env respEnvelope
	if err := json.Unmarshal([]byte(text.Text), &env); err != nil {
		t.Fatalf("decode envelope: %v\nraw=%s", err, text.Text)
	}
	return env
}

// jsonEqual compares two values via marshaled JSON — robust to map ordering
// and to int/float64 mismatches from JSON round-trips.
func jsonEqual(a, b any) bool {
	ja, err1 := json.Marshal(a)
	jb, err2 := json.Marshal(b)
	if err1 != nil || err2 != nil {
		return false
	}
	return string(ja) == string(jb)
}

func mustHave(t *testing.T, m map[string]any, key string, want any) {
	t.Helper()
	v, ok := m[key]
	if !ok {
		t.Fatalf("missing key %q in %v", key, m)
	}
	if !jsonEqual(v, want) {
		t.Fatalf("key %q: got %v, want %v", key, v, want)
	}
}

func mustNotHave(t *testing.T, m map[string]any, key string) {
	t.Helper()
	if _, ok := m[key]; ok {
		t.Fatalf("key %q must be omitted, got %v", key, m[key])
	}
}

// --- envelope shape ---------------------------------------------------------

func TestSuccessEnvelopeWrapsSendCommandResult(t *testing.T) {
	s := newSession(t)
	s.fake.NextResult = map[string]any{"id": "comp-1", "type": "cube"}
	got := envelopeOf(t, s.call(t, "create_component", map[string]any{}))
	want := respEnvelope{
		Success: true,
		Result:  map[string]any{"id": "comp-1", "type": "cube"},
		Error:   nil,
	}
	if !jsonEqual(got, want) {
		t.Fatalf("envelope: got %v, want %v", got, want)
	}
}

func TestFailureEnvelopeCapturesExceptionMessage(t *testing.T) {
	s := newSession(t)
	s.fake.NextError = errors.New("ruby barfed")
	got := envelopeOf(t, s.call(t, "create_component", map[string]any{}))
	if got.Success || got.Result != nil {
		t.Fatalf("want failure envelope, got %v", got)
	}
	errStr, _ := got.Error.(string)
	if errStr != "ruby barfed" {
		t.Fatalf("want error 'ruby barfed', got %v", got.Error)
	}
}

func TestRequestIDIsThreadedThrough(t *testing.T) {
	s := newSession(t)
	_ = s.call(t, "get_selection", map[string]any{})
	id := s.fake.lastCall(t).RequestID
	if id == nil {
		t.Fatal("request_id must be threaded through to SendCommand")
	}
}

// --- create_component -------------------------------------------------------

func TestCreateComponentSubstitutesDefaultsWhenOmitted(t *testing.T) {
	s := newSession(t)
	_ = s.call(t, "create_component", map[string]any{})
	if name := s.fake.lastToolName(t); name != "create_component" {
		t.Fatalf("ruby tool name: %q", name)
	}
	args := s.fake.lastArguments(t)
	want := map[string]any{
		"type":       "cube",
		"position":   []float64{0, 0, 0},
		"dimensions": []float64{1, 1, 1},
	}
	if !jsonEqual(args, want) {
		t.Fatalf("args: got %v, want %v", args, want)
	}
}

func TestCreateComponentPassesExplicitArgsThrough(t *testing.T) {
	s := newSession(t)
	_ = s.call(t, "create_component", map[string]any{
		"type":       "sphere",
		"position":   []float64{1, 2, 3},
		"dimensions": []float64{4, 5, 6},
	})
	want := map[string]any{
		"type":       "sphere",
		"position":   []float64{1, 2, 3},
		"dimensions": []float64{4, 5, 6},
	}
	if !jsonEqual(s.fake.lastArguments(t), want) {
		t.Fatalf("args: %v", s.fake.lastArguments(t))
	}
}

func TestCreateComponentForwardsName(t *testing.T) {
	s := newSession(t)
	_ = s.call(t, "create_component", map[string]any{
		"type":       "cube",
		"name":       "Floor Joist 3",
		"position":   []float64{0, 0, 0},
		"dimensions": []float64{1, 1, 1},
	})
	args := s.fake.lastArguments(t)
	mustHave(t, args, "name", "Floor Joist 3")
}

func TestCreateComponentOmitsUnsetName(t *testing.T) {
	s := newSession(t)
	_ = s.call(t, "create_component", map[string]any{
		"type": "cube",
	})
	mustNotHave(t, s.fake.lastArguments(t), "name")
}

// --- transform_component — None args must be OMITTED, not passed as null ----

func TestTransformComponentOmitsUnsetArgs(t *testing.T) {
	s := newSession(t)
	_ = s.call(t, "transform_component", map[string]any{
		"id":       "abc",
		"position": []float64{1, 2, 3},
	})
	args := s.fake.lastArguments(t)
	mustHave(t, args, "id", "abc")
	mustHave(t, args, "position", []float64{1, 2, 3})
	for _, k := range []string{"move_to", "rotation", "scale", "name"} {
		mustNotHave(t, args, k)
	}
}

func TestTransformComponentIncludesAllProvidedArguments(t *testing.T) {
	s := newSession(t)
	_ = s.call(t, "transform_component", map[string]any{
		"id":       "abc",
		"move_to":  []float64{10, 20, 30},
		"position": []float64{1, 2, 3},
		"rotation": []float64{0, 90, 0},
		"scale":    []float64{2, 2, 2},
	})
	want := map[string]any{
		"id":       "abc",
		"move_to":  []float64{10, 20, 30},
		"position": []float64{1, 2, 3},
		"rotation": []float64{0, 90, 0},
		"scale":    []float64{2, 2, 2},
	}
	if !jsonEqual(s.fake.lastArguments(t), want) {
		t.Fatalf("args: %v", s.fake.lastArguments(t))
	}
}

func TestTransformComponentForwardsMoveToAlone(t *testing.T) {
	s := newSession(t)
	_ = s.call(t, "transform_component", map[string]any{
		"id":      "abc",
		"move_to": []float64{10, 20, 30},
	})
	args := s.fake.lastArguments(t)
	mustHave(t, args, "id", "abc")
	mustHave(t, args, "move_to", []float64{10, 20, 30})
	mustNotHave(t, args, "position")
}

// --- name-based addressing --------------------------------------------------

func TestDeleteComponentForwardsName(t *testing.T) {
	s := newSession(t)
	_ = s.call(t, "delete_component", map[string]any{"name": "Rafter W 5"})
	if s.fake.lastToolName(t) != "delete_component" {
		t.Fatal("ruby tool name")
	}
	args := s.fake.lastArguments(t)
	mustHave(t, args, "name", "Rafter W 5")
	mustNotHave(t, args, "id")
}

func TestTransformComponentForwardsName(t *testing.T) {
	s := newSession(t)
	_ = s.call(t, "transform_component", map[string]any{
		"name":    "Ridge",
		"move_to": []float64{0, 0, 5},
	})
	args := s.fake.lastArguments(t)
	mustHave(t, args, "name", "Ridge")
	mustHave(t, args, "move_to", []float64{0, 0, 5})
	mustNotHave(t, args, "id")
}

func TestDeleteComponentForwardsNeitherWhenOmitted(t *testing.T) {
	s := newSession(t)
	_ = s.call(t, "delete_component", map[string]any{})
	if !jsonEqual(s.fake.lastArguments(t), map[string]any{}) {
		t.Fatalf("want empty args, got %v", s.fake.lastArguments(t))
	}
}

func TestTransformComponentForwardsBothWhenBothGiven(t *testing.T) {
	s := newSession(t)
	_ = s.call(t, "transform_component", map[string]any{
		"id":   "5",
		"name": "Ridge",
	})
	args := s.fake.lastArguments(t)
	mustHave(t, args, "id", "5")
	mustHave(t, args, "name", "Ridge")
}

// --- argument-name parity for every tool ------------------------------------

func TestToolForwardsExpectedArguments(t *testing.T) {
	cases := []struct {
		toolName           string
		mcpArgs            map[string]any
		expectedRubyMethod string
		expectedRubyArgs   map[string]any
	}{
		{
			toolName:           "delete_component",
			mcpArgs:            map[string]any{"id": "x"},
			expectedRubyMethod: "delete_component",
			expectedRubyArgs:   map[string]any{"id": "x"},
		},
		{
			toolName:           "get_selection",
			mcpArgs:            map[string]any{},
			expectedRubyMethod: "get_selection",
			expectedRubyArgs:   map[string]any{},
		},
		{
			toolName:           "set_material",
			mcpArgs:            map[string]any{"id": "x", "material": "wood"},
			expectedRubyMethod: "set_material",
			expectedRubyArgs:   map[string]any{"id": "x", "material": "wood"},
		},
		{
			toolName:           "export_scene",
			mcpArgs:            map[string]any{"format": "obj"},
			expectedRubyMethod: "export",
			expectedRubyArgs:   map[string]any{"format": "obj"},
		},
		{
			toolName:           "export_scene",
			mcpArgs:            map[string]any{},
			expectedRubyMethod: "export",
			expectedRubyArgs:   map[string]any{"format": "skp"},
		},
		{
			toolName:           "create_mortise_tenon",
			mcpArgs:            map[string]any{"mortise_id": "m", "tenon_id": "t"},
			expectedRubyMethod: "create_mortise_tenon",
			expectedRubyArgs: map[string]any{
				"mortise_id": "m", "tenon_id": "t",
				"width": 1.0, "height": 1.0, "depth": 1.0,
				"offset_x": 0.0, "offset_y": 0.0, "offset_z": 0.0,
			},
		},
		{
			toolName:           "create_dovetail",
			mcpArgs:            map[string]any{"tail_id": "t", "pin_id": "p"},
			expectedRubyMethod: "create_dovetail",
			expectedRubyArgs: map[string]any{
				"tail_id": "t", "pin_id": "p",
				"width": 2.0, "height": 2.0, "depth": 0.25,
				"angle": 15.0, "num_tails": 3,
				"offset_x": 0.0, "offset_y": 0.0, "offset_z": 0.0,
			},
		},
		{
			toolName:           "create_finger_joint",
			mcpArgs:            map[string]any{"board1_id": "a", "board2_id": "b"},
			expectedRubyMethod: "create_finger_joint",
			expectedRubyArgs: map[string]any{
				"board1_id": "a", "board2_id": "b",
				"width": 2.0, "height": 2.0, "depth": 1.0,
				"num_fingers": 5,
				"offset_x":    0.0, "offset_y": 0.0, "offset_z": 0.0,
			},
		},
		{
			toolName:           "eval_ruby",
			mcpArgs:            map[string]any{"code": "1+1"},
			expectedRubyMethod: "eval_ruby",
			expectedRubyArgs:   map[string]any{"code": "1+1"},
		},
		{
			toolName:           "find_groups",
			mcpArgs:            map[string]any{},
			expectedRubyMethod: "find_groups",
			expectedRubyArgs:   map[string]any{"limit": 200, "include_components": false, "recursive": false},
		},
	}

	for _, tc := range cases {
		t.Run(tc.toolName+"/"+previewArgs(tc.mcpArgs), func(t *testing.T) {
			s := newSession(t)
			_ = s.call(t, tc.toolName, tc.mcpArgs)
			if got := s.fake.lastToolName(t); got != tc.expectedRubyMethod {
				t.Fatalf("ruby method: got %q, want %q", got, tc.expectedRubyMethod)
			}
			if !jsonEqual(s.fake.lastArguments(t), tc.expectedRubyArgs) {
				t.Fatalf("args mismatch:\n got  %v\n want %v",
					s.fake.lastArguments(t), tc.expectedRubyArgs)
			}
		})
	}
}

func previewArgs(m map[string]any) string {
	if len(m) == 0 {
		return "empty"
	}
	b, _ := json.Marshal(m)
	if len(b) > 30 {
		return string(b[:30])
	}
	return string(b)
}

// --- eval_ruby — central use case ------------------------------------------

func TestEvalRubyRoundTrip(t *testing.T) {
	s := newSession(t)
	s.fake.NextResult = "42"
	result := s.call(t, "eval_ruby", map[string]any{"code": "6 * 7"})

	if s.fake.lastCall(t).Method != "tools/call" {
		t.Fatalf("method: %q", s.fake.lastCall(t).Method)
	}
	if s.fake.lastToolName(t) != "eval_ruby" {
		t.Fatal("tool name")
	}
	if !jsonEqual(s.fake.lastArguments(t), map[string]any{"code": "6 * 7"}) {
		t.Fatalf("args: %v", s.fake.lastArguments(t))
	}
	env := envelopeOf(t, result)
	if !env.Success || env.Result != "42" || env.Error != nil {
		t.Fatalf("envelope: %v", env)
	}
}

// --- find_groups — wire-shape ------------------------------------------------

func TestFindGroupsForwardsNamePrefix(t *testing.T) {
	s := newSession(t)
	_ = s.call(t, "find_groups", map[string]any{"name_prefix": "WA "})
	if s.fake.lastToolName(t) != "find_groups" {
		t.Fatal("tool name")
	}
	want := map[string]any{
		"name_prefix":        "WA ",
		"limit":              200,
		"include_components": false,
		"recursive":          false,
	}
	if !jsonEqual(s.fake.lastArguments(t), want) {
		t.Fatalf("args: %v", s.fake.lastArguments(t))
	}
}

func TestFindGroupsForwardsNamePattern(t *testing.T) {
	s := newSession(t)
	pattern := `^Rafter [WE] \d+$`
	_ = s.call(t, "find_groups", map[string]any{"name_pattern": pattern})
	want := map[string]any{
		"name_pattern":       pattern,
		"limit":              200,
		"include_components": false,
		"recursive":          false,
	}
	if !jsonEqual(s.fake.lastArguments(t), want) {
		t.Fatalf("args: %v", s.fake.lastArguments(t))
	}
}

func TestFindGroupsForwardsInBoundsPositive(t *testing.T) {
	s := newSession(t)
	_ = s.call(t, "find_groups", map[string]any{
		"in_bounds": map[string][]float64{
			"min": {38, 0, 0},
			"max": {82, 3.5, 95},
		},
	})
	want := map[string]any{
		"in_bounds": map[string]any{
			"min": []float64{38, 0, 0},
			"max": []float64{82, 3.5, 95},
		},
		"limit":              200,
		"include_components": false,
		"recursive":          false,
	}
	if !jsonEqual(s.fake.lastArguments(t), want) {
		t.Fatalf("args: %v", s.fake.lastArguments(t))
	}
}

func TestFindGroupsForwardsInBoundsNegativeAABB(t *testing.T) {
	s := newSession(t)
	_ = s.call(t, "find_groups", map[string]any{
		"in_bounds": map[string][]float64{
			"min": {-10, -10, -10},
			"max": {-1, -1, -1},
		},
	})
	got := s.fake.lastArguments(t)["in_bounds"]
	want := map[string]any{
		"min": []float64{-10, -10, -10},
		"max": []float64{-1, -1, -1},
	}
	if !jsonEqual(got, want) {
		t.Fatalf("in_bounds: %v", got)
	}
}

func TestFindGroupsForwardsCombinedFilters(t *testing.T) {
	s := newSession(t)
	_ = s.call(t, "find_groups", map[string]any{
		"name_prefix": "WA ",
		"in_bounds": map[string][]float64{
			"min": {0, 0, 0}, "max": {100, 100, 100},
		},
		"parent_id":          42,
		"limit":              10,
		"include_components": true,
	})
	want := map[string]any{
		"name_prefix": "WA ",
		"in_bounds": map[string]any{
			"min": []float64{0, 0, 0}, "max": []float64{100, 100, 100},
		},
		"parent_id":          42,
		"limit":              10,
		"include_components": true,
		"recursive":          false,
	}
	if !jsonEqual(s.fake.lastArguments(t), want) {
		t.Fatalf("args: %v", s.fake.lastArguments(t))
	}
}

func TestFindGroupsForwardsTruncationLimit(t *testing.T) {
	s := newSession(t)
	_ = s.call(t, "find_groups", map[string]any{"limit": 5})
	if !jsonEqual(s.fake.lastArguments(t)["limit"], 5) {
		t.Fatalf("limit: %v", s.fake.lastArguments(t)["limit"])
	}
}

func TestFindGroupsForwardsIncludeComponents(t *testing.T) {
	s := newSession(t)
	_ = s.call(t, "find_groups", map[string]any{"include_components": true})
	if s.fake.lastArguments(t)["include_components"] != true {
		t.Fatalf("include_components: %v", s.fake.lastArguments(t)["include_components"])
	}
}

func TestFindGroupsForwardsRecursive(t *testing.T) {
	s := newSession(t)
	_ = s.call(t, "find_groups", map[string]any{"recursive": true})
	if s.fake.lastArguments(t)["recursive"] != true {
		t.Fatalf("recursive: %v", s.fake.lastArguments(t)["recursive"])
	}
}

func TestFindGroupsOmitsUnsetFilters(t *testing.T) {
	s := newSession(t)
	_ = s.call(t, "find_groups", map[string]any{})
	args := s.fake.lastArguments(t)
	want := map[string]any{"limit": 200, "include_components": false, "recursive": false}
	if !jsonEqual(args, want) {
		t.Fatalf("args: %v", args)
	}
	for _, k := range []string{"name_prefix", "name_pattern", "in_bounds", "parent_id"} {
		mustNotHave(t, args, k)
	}
}

func TestFindGroupsReturnsStructuredPayload(t *testing.T) {
	s := newSession(t)
	sample := []any{
		map[string]any{
			"id":       float64(101),
			"name":     "Rafter W 1",
			"bounds":   map[string]any{"min": []any{0.0, 0.0, 0.0}, "max": []any{1.5, 96.0, 5.5}},
			"layer":    "Layer0",
			"material": nil,
		},
		map[string]any{
			"id":       float64(102),
			"name":     "Rafter W 2",
			"bounds":   map[string]any{"min": []any{16.0, 0.0, 0.0}, "max": []any{17.5, 96.0, 5.5}},
			"layer":    "Layer0",
			"material": "Cherry",
		},
	}
	s.fake.NextResult = map[string]any{
		"content":    []any{map[string]any{"type": "text", "text": "Success"}},
		"isError":    false,
		"success":    true,
		"resourceId": nil,
		"groups":     sample,
		"truncated":  false,
	}
	env := envelopeOf(t, s.call(t, "find_groups", map[string]any{"name_prefix": "Rafter W"}))
	want := map[string]any{"groups": sample, "truncated": false}
	if !env.Success || env.Error != nil {
		t.Fatalf("envelope: %v", env)
	}
	if !jsonEqual(env.Result, want) {
		t.Fatalf("result mismatch:\n got %v\nwant %v", env.Result, want)
	}
}

func TestFindGroupsReturnsEmptyListWhenNoMatches(t *testing.T) {
	s := newSession(t)
	s.fake.NextResult = map[string]any{
		"content":    []any{map[string]any{"type": "text", "text": "Success"}},
		"isError":    false,
		"success":    true,
		"resourceId": nil,
		"groups":     []any{},
		"truncated":  false,
	}
	env := envelopeOf(t, s.call(t, "find_groups", map[string]any{}))
	want := map[string]any{"groups": []any{}, "truncated": false}
	if !jsonEqual(env.Result, want) {
		t.Fatalf("result: %v", env.Result)
	}
}

// --- boolean_op -------------------------------------------------------------

func TestBooleanOpForwardsSubtract(t *testing.T) {
	s := newSession(t)
	_ = s.call(t, "boolean_op", map[string]any{
		"operation": "subtract", "target_id": 101, "tool_id": 202,
	})
	if s.fake.lastToolName(t) != "boolean_operation" {
		t.Fatalf("tool name: %q", s.fake.lastToolName(t))
	}
	want := map[string]any{
		"operation":        "subtract",
		"target_id":        101,
		"tool_id":          202,
		"delete_originals": true,
	}
	if !jsonEqual(s.fake.lastArguments(t), want) {
		t.Fatalf("args: %v", s.fake.lastArguments(t))
	}
}

func TestBooleanOpForwardsKeepOriginals(t *testing.T) {
	s := newSession(t)
	_ = s.call(t, "boolean_op", map[string]any{
		"operation": "union", "target_id": 1, "tool_id": 2,
		"delete_originals": false,
	})
	if s.fake.lastArguments(t)["delete_originals"] != false {
		t.Fatalf("delete_originals: %v", s.fake.lastArguments(t)["delete_originals"])
	}
}

func TestBooleanOpRejectsUnknownOperation(t *testing.T) {
	s := newSession(t)
	result := s.call(t, "boolean_op", map[string]any{
		"operation": "merge", "target_id": 1, "tool_id": 2,
	})
	// Handler must reject before calling Ruby.
	if len(s.fake.Calls) != 0 {
		t.Fatalf("Ruby must not have been called; got %v", s.fake.Calls)
	}
	env := envelopeOf(t, result)
	if env.Success {
		t.Fatalf("expected failure envelope, got %v", env)
	}
	errStr, _ := env.Error.(string)
	if !strings.Contains(errStr, "merge") {
		t.Fatalf("error must mention the offending op; got %q", errStr)
	}
}

// --- MCP-frame slimming: structured payloads reach callers ------------------
//
// Production Ruby wraps every successful result in an MCP frame
// ({content, isError, success, resourceId, ...extras}). The Go layer
// strips the wrapper so callers see the extras directly, with resourceId
// promoted to "id".

func mcpFrame(extras map[string]any, resourceID any) map[string]any {
	out := map[string]any{
		"content":    []any{map[string]any{"type": "text", "text": "Success"}},
		"isError":    false,
		"success":    true,
		"resourceId": resourceID,
	}
	maps.Copy(out, extras)
	return out
}

func TestCreateComponentSurfacesBoundsPayload(t *testing.T) {
	s := newSession(t)
	s.fake.NextResult = mcpFrame(map[string]any{
		"bounds": map[string]any{
			"min": []any{0.0, 0.0, 0.0},
			"max": []any{4.0, 4.0, 4.0},
		},
	}, float64(123))
	env := envelopeOf(t, s.call(t, "create_component", map[string]any{
		"type": "cube", "position": []float64{0, 0, 0}, "dimensions": []float64{4, 4, 4},
	}))
	if !env.Success {
		t.Fatalf("envelope: %v", env)
	}
	want := map[string]any{
		"bounds": map[string]any{
			"min": []any{0.0, 0.0, 0.0},
			"max": []any{4.0, 4.0, 4.0},
		},
		"id": float64(123),
	}
	if !jsonEqual(env.Result, want) {
		t.Fatalf("result: got %v, want %v", env.Result, want)
	}
}

func TestTransformComponentSurfacesBoundsPayload(t *testing.T) {
	s := newSession(t)
	s.fake.NextResult = mcpFrame(map[string]any{
		"bounds": map[string]any{
			"min": []any{1.0, 2.0, 3.0},
			"max": []any{5.0, 6.0, 7.0},
		},
	}, float64(42))
	env := envelopeOf(t, s.call(t, "transform_component", map[string]any{
		"id": "42", "move_to": []float64{1, 2, 3},
	}))
	result := env.Result.(map[string]any)
	bounds := result["bounds"].(map[string]any)
	if !jsonEqual(bounds["min"], []any{1.0, 2.0, 3.0}) {
		t.Fatalf("bounds.min: %v", bounds["min"])
	}
	if !jsonEqual(bounds["max"], []any{5.0, 6.0, 7.0}) {
		t.Fatalf("bounds.max: %v", bounds["max"])
	}
}

func TestInspectGeometrySurfacesFacesPayload(t *testing.T) {
	s := newSession(t)
	faces := []any{
		map[string]any{"area": 16.0, "normal": []any{0.0, 0.0, 1.0}},
	}
	s.fake.NextResult = mcpFrame(map[string]any{
		"name":       "Slab",
		"face_count": float64(6),
		"edge_count": float64(12),
		"is_solid":   true,
		"faces":      faces,
	}, float64(123))
	env := envelopeOf(t, s.call(t, "inspect_geometry", map[string]any{"id": "123"}))
	result := env.Result.(map[string]any)
	for _, k := range []string{"name", "face_count", "edge_count", "is_solid", "faces", "id"} {
		if _, ok := result[k]; !ok {
			t.Fatalf("missing %q in result: %v", k, result)
		}
	}
	if !jsonEqual(result["faces"], faces) {
		t.Fatalf("faces: %v", result["faces"])
	}
}

func TestGetSelectionSurfacesEntitiesPayload(t *testing.T) {
	s := newSession(t)
	entities := []any{
		map[string]any{"id": float64(101), "type": "group"},
		map[string]any{"id": float64(102), "type": "edge"},
	}
	s.fake.NextResult = mcpFrame(map[string]any{"entities": entities}, nil)
	env := envelopeOf(t, s.call(t, "get_selection", map[string]any{}))
	result := env.Result.(map[string]any)
	if !jsonEqual(result["entities"], entities) {
		t.Fatalf("entities: %v", result["entities"])
	}
}

func TestExportSceneSurfacesPathPayload(t *testing.T) {
	s := newSession(t)
	s.fake.NextResult = mcpFrame(map[string]any{
		"path":   "/tmp/sketchup_export_20260101_120000.png",
		"format": "png",
	}, nil)
	env := envelopeOf(t, s.call(t, "export_scene", map[string]any{"format": "png"}))
	result := env.Result.(map[string]any)
	if result["path"] != "/tmp/sketchup_export_20260101_120000.png" {
		t.Fatalf("path: %v", result["path"])
	}
	if result["format"] != "png" {
		t.Fatalf("format: %v", result["format"])
	}
}

func TestBooleanOpSurfacesIDAndManifoldPayload(t *testing.T) {
	s := newSession(t)
	s.fake.NextResult = mcpFrame(map[string]any{"manifold": true}, float64(555))
	env := envelopeOf(t, s.call(t, "boolean_op", map[string]any{
		"operation": "union", "target_id": 1, "tool_id": 2,
	}))
	result := env.Result.(map[string]any)
	if result["id"] != float64(555) {
		t.Fatalf("id: %v", result["id"])
	}
	if result["manifold"] != true {
		t.Fatalf("manifold: %v", result["manifold"])
	}
}

func TestEvalRubyMCPFrameFallsBackToContentText(t *testing.T) {
	s := newSession(t)
	s.fake.NextResult = mcpFrame(nil, nil)
	// MCP frame with no extras and resourceId=nil falls back to content text.
	env := envelopeOf(t, s.call(t, "eval_ruby", map[string]any{"code": "1+1"}))
	if env.Result != "Success" {
		t.Fatalf("result: %v", env.Result)
	}
}

// --- create_extrusion -------------------------------------------------------

var rafterProfile = [][]float64{
	{-12, 89.625},
	{59.25, 125.25},
	{59.25, 131.399},
	{-12, 95.774},
}

func TestCreateExtrusionYAxisRafter(t *testing.T) {
	s := newSession(t)
	_ = s.call(t, "create_extrusion", map[string]any{
		"name":         "Rafter W 5",
		"profile":      rafterProfile,
		"extrude_axis": "y",
		"extrude_from": 15.25,
		"extrude_to":   16.75,
	})
	if s.fake.lastToolName(t) != "create_extrusion" {
		t.Fatal("tool name")
	}
	want := map[string]any{
		"name":         "Rafter W 5",
		"profile":      rafterProfile,
		"extrude_axis": "y",
		"extrude_from": 15.25,
		"extrude_to":   16.75,
	}
	if !jsonEqual(s.fake.lastArguments(t), want) {
		t.Fatalf("args:\n got  %v\n want %v", s.fake.lastArguments(t), want)
	}
	mustNotHave(t, s.fake.lastArguments(t), "material")
	mustNotHave(t, s.fake.lastArguments(t), "holes")
	mustNotHave(t, s.fake.lastArguments(t), "plane")
	mustNotHave(t, s.fake.lastArguments(t), "extrude_depth")
}

func TestCreateExtrusionXAxis(t *testing.T) {
	s := newSession(t)
	_ = s.call(t, "create_extrusion", map[string]any{
		"name":         "Header A",
		"profile":      rafterProfile,
		"extrude_axis": "x",
		"extrude_from": 0.0,
		"extrude_to":   3.5,
	})
	mustHave(t, s.fake.lastArguments(t), "extrude_axis", "x")
	mustHave(t, s.fake.lastArguments(t), "profile", rafterProfile)
}

func TestCreateExtrusionZAxis(t *testing.T) {
	s := newSession(t)
	_ = s.call(t, "create_extrusion", map[string]any{
		"name":         "Post 1",
		"profile":      rafterProfile,
		"extrude_axis": "z",
		"extrude_from": 0.0,
		"extrude_to":   96.0,
	})
	mustHave(t, s.fake.lastArguments(t), "extrude_axis", "z")
}

func TestCreateExtrusionReverseDirection(t *testing.T) {
	s := newSession(t)
	_ = s.call(t, "create_extrusion", map[string]any{
		"name":         "Sloped Stud",
		"profile":      rafterProfile,
		"extrude_axis": "z",
		"extrude_from": 96.0,
		"extrude_to":   0.0,
	})
	mustHave(t, s.fake.lastArguments(t), "extrude_from", 96.0)
	mustHave(t, s.fake.lastArguments(t), "extrude_to", 0.0)
}

func TestCreateExtrusionForwardsMaterial(t *testing.T) {
	s := newSession(t)
	_ = s.call(t, "create_extrusion", map[string]any{
		"name":         "Fascia",
		"profile":      [][]float64{{0, 0}, {1, 0}, {1, 1}, {0, 1}},
		"extrude_axis": "y",
		"extrude_from": 0,
		"extrude_to":   100,
		"material":     "#8B4513",
	})
	mustHave(t, s.fake.lastArguments(t), "material", "#8B4513")
}

func TestCreateExtrusionOmitsUnsetMaterial(t *testing.T) {
	s := newSession(t)
	_ = s.call(t, "create_extrusion", map[string]any{
		"name":         "Fascia",
		"profile":      [][]float64{{0, 0}, {1, 0}, {1, 1}, {0, 1}},
		"extrude_axis": "y",
		"extrude_from": 0,
		"extrude_to":   100,
	})
	mustNotHave(t, s.fake.lastArguments(t), "material")
}

func TestCreateExtrusionForwardsHoles(t *testing.T) {
	s := newSession(t)
	holes := [][][]float64{
		{{8.25, 36}, {33.25, 36}, {33.25, 61}, {8.25, 61}},
		{{40, 40}, {44, 40}, {44, 44}, {40, 44}},
	}
	_ = s.call(t, "create_extrusion", map[string]any{
		"name":         "Siding 1",
		"profile":      [][]float64{{0, 0}, {38, 0}, {38, 96}, {0, 96}},
		"extrude_axis": "y",
		"extrude_from": 0,
		"extrude_to":   0.5,
		"holes":        holes,
	})
	mustHave(t, s.fake.lastArguments(t), "holes", holes)
}

func TestCreateExtrusionOmitsUnsetHoles(t *testing.T) {
	s := newSession(t)
	_ = s.call(t, "create_extrusion", map[string]any{
		"name":         "Siding 1",
		"profile":      [][]float64{{0, 0}, {38, 0}, {38, 96}, {0, 96}},
		"extrude_axis": "y",
		"extrude_from": 0,
		"extrude_to":   0.5,
	})
	mustNotHave(t, s.fake.lastArguments(t), "holes")
}

func TestCreateExtrusionForwardsPlaneAndDepth(t *testing.T) {
	s := newSession(t)
	plane := map[string][]float64{
		"origin": {0, 0, 0},
		"normal": {0, -0.4472, 0.8944},
	}
	_ = s.call(t, "create_extrusion", map[string]any{
		"name":          "Roof Sheathing 1",
		"profile":       [][]float64{{0, 0}, {48, 0}, {48, 96}, {0, 96}},
		"plane":         plane,
		"extrude_depth": 0.625,
	})
	want := map[string]any{
		"name":          "Roof Sheathing 1",
		"profile":       [][]float64{{0, 0}, {48, 0}, {48, 96}, {0, 96}},
		"plane":         plane,
		"extrude_depth": 0.625,
	}
	if !jsonEqual(s.fake.lastArguments(t), want) {
		t.Fatalf("args: %v", s.fake.lastArguments(t))
	}
	mustNotHave(t, s.fake.lastArguments(t), "extrude_axis")
}

func TestCreateExtrusionOmitsAxisKeysWhenUnset(t *testing.T) {
	s := newSession(t)
	_ = s.call(t, "create_extrusion", map[string]any{
		"name":          "Slab",
		"profile":       [][]float64{{0, 0}, {1, 0}, {1, 1}, {0, 1}},
		"plane":         map[string][]float64{"origin": {0, 0, 0}, "normal": {0, 0, 1}},
		"extrude_depth": 1.0,
	})
	for _, k := range []string{"extrude_axis", "extrude_from", "extrude_to"} {
		mustNotHave(t, s.fake.lastArguments(t), k)
	}
}

func TestCreateExtrusionNegativeExtrudeDepthRoundTrips(t *testing.T) {
	s := newSession(t)
	_ = s.call(t, "create_extrusion", map[string]any{
		"name":          "Slab Down",
		"profile":       [][]float64{{0, 0}, {1, 0}, {1, 1}, {0, 1}},
		"plane":         map[string][]float64{"origin": {0, 0, 0}, "normal": {0, 0, 1}},
		"extrude_depth": -2.5,
	})
	mustHave(t, s.fake.lastArguments(t), "extrude_depth", -2.5)
}

// --- replace_geometry -------------------------------------------------------

func TestReplaceGeometryForwardsIDAndGeometry(t *testing.T) {
	s := newSession(t)
	geometry := map[string]any{
		"op": "cube", "position": []float64{0, 0, 0}, "dimensions": []float64{16, 16, 8},
	}
	_ = s.call(t, "replace_geometry", map[string]any{
		"id": "123", "geometry": geometry,
	})
	if s.fake.lastToolName(t) != "replace_geometry" {
		t.Fatal("tool name")
	}
	want := map[string]any{
		"id":        "123",
		"geometry":  geometry,
		"recursive": true,
	}
	if !jsonEqual(s.fake.lastArguments(t), want) {
		t.Fatalf("args: %v", s.fake.lastArguments(t))
	}
	mustNotHave(t, s.fake.lastArguments(t), "name")
}

func TestReplaceGeometryForwardsName(t *testing.T) {
	s := newSession(t)
	geometry := map[string]any{
		"op": "cylinder", "position": []float64{0, 0, 0}, "radius": 1.5, "height": 96,
	}
	_ = s.call(t, "replace_geometry", map[string]any{
		"name": "Post 1", "geometry": geometry,
	})
	want := map[string]any{"name": "Post 1", "geometry": geometry, "recursive": true}
	if !jsonEqual(s.fake.lastArguments(t), want) {
		t.Fatalf("args: %v", s.fake.lastArguments(t))
	}
	mustNotHave(t, s.fake.lastArguments(t), "id")
}

func TestReplaceGeometryForwardsRecursiveFalse(t *testing.T) {
	s := newSession(t)
	geometry := map[string]any{
		"op": "cube", "position": []float64{0, 0, 0}, "dimensions": []float64{1, 1, 1},
	}
	_ = s.call(t, "replace_geometry", map[string]any{
		"id": "5", "geometry": geometry, "recursive": false,
	})
	if s.fake.lastArguments(t)["recursive"] != false {
		t.Fatalf("recursive: %v", s.fake.lastArguments(t)["recursive"])
	}
}

func TestReplaceGeometryForwardsExtrusionGeometry(t *testing.T) {
	s := newSession(t)
	geometry := map[string]any{
		"op":           "extrusion",
		"profile":      [][]float64{{0, 0}, {38, 0}, {38, 96}, {0, 96}},
		"extrude_axis": "y",
		"extrude_from": 0,
		"extrude_to":   0.5,
		"holes":        [][][]float64{{{8.25, 36}, {33.25, 36}, {33.25, 61}, {8.25, 61}}},
	}
	_ = s.call(t, "replace_geometry", map[string]any{
		"name": "Siding W1", "geometry": geometry,
	})
	mustHave(t, s.fake.lastArguments(t), "geometry", geometry)
}

// --- inspect_geometry -------------------------------------------------------

func TestInspectGeometryForwardsID(t *testing.T) {
	s := newSession(t)
	_ = s.call(t, "inspect_geometry", map[string]any{"id": "123"})
	if s.fake.lastToolName(t) != "inspect_geometry" {
		t.Fatal("tool name")
	}
	want := map[string]any{"id": "123", "include_vertices": true}
	if !jsonEqual(s.fake.lastArguments(t), want) {
		t.Fatalf("args: %v", s.fake.lastArguments(t))
	}
	mustNotHave(t, s.fake.lastArguments(t), "name")
}

func TestInspectGeometryForwardsName(t *testing.T) {
	s := newSession(t)
	_ = s.call(t, "inspect_geometry", map[string]any{"name": "WA Siding 1"})
	want := map[string]any{"name": "WA Siding 1", "include_vertices": true}
	if !jsonEqual(s.fake.lastArguments(t), want) {
		t.Fatalf("args: %v", s.fake.lastArguments(t))
	}
	mustNotHave(t, s.fake.lastArguments(t), "id")
}

func TestInspectGeometryForwardsIncludeVerticesFalse(t *testing.T) {
	s := newSession(t)
	_ = s.call(t, "inspect_geometry", map[string]any{
		"id": "123", "include_vertices": false,
	})
	want := map[string]any{"id": "123", "include_vertices": false}
	if !jsonEqual(s.fake.lastArguments(t), want) {
		t.Fatalf("args: %v", s.fake.lastArguments(t))
	}
}

func TestInspectGeometryOmitsUnsetIDAndName(t *testing.T) {
	s := newSession(t)
	_ = s.call(t, "inspect_geometry", map[string]any{})
	want := map[string]any{"include_vertices": true}
	if !jsonEqual(s.fake.lastArguments(t), want) {
		t.Fatalf("args: %v", s.fake.lastArguments(t))
	}
}

// --- batch_create -----------------------------------------------------------

func TestBatchCreateForwardsMixedOps(t *testing.T) {
	s := newSession(t)
	ops := []map[string]any{
		{"op": "cube", "name": "Foundation Block 1", "position": []float64{0, 0, 0}, "dimensions": []float64{16, 16, 8}},
		{"op": "cylinder", "name": "Post 1", "position": []float64{10, 10, 0}, "radius": 1.75, "height": 96},
		{"op": "translate", "id_or_name": 42, "delta": []float64{0, 0, 1.5}},
		{"op": "move_to", "id_or_name": "Ridge", "target": []float64{0, 0, 96}},
		{"op": "delete", "id_or_name": 99},
	}
	_ = s.call(t, "batch_create", map[string]any{
		"operations":       ops,
		"transaction_name": "Foundation pass",
	})
	if s.fake.lastToolName(t) != "batch_create" {
		t.Fatal("tool name")
	}
	want := map[string]any{
		"transaction_name": "Foundation pass",
		"operations":       ops,
	}
	if !jsonEqual(s.fake.lastArguments(t), want) {
		t.Fatalf("args: %v", s.fake.lastArguments(t))
	}
}

func TestBatchCreateDefaultsTransactionName(t *testing.T) {
	s := newSession(t)
	_ = s.call(t, "batch_create", map[string]any{
		"operations": []map[string]any{
			{"op": "sphere", "name": "Ball", "position": []float64{0, 0, 0}, "radius": 1},
		},
	})
	mustHave(t, s.fake.lastArguments(t), "transaction_name", "MCP batch")
}

func TestBatchCreateNameBasedMutatesRoundTrip(t *testing.T) {
	s := newSession(t)
	ops := []map[string]any{
		{"op": "translate", "id_or_name": "Rafter W 5", "delta": []float64{0, 0, 0.5}},
		{"op": "delete", "id_or_name": "Old Rafter"},
	}
	_ = s.call(t, "batch_create", map[string]any{"operations": ops})
	forwarded, _ := s.fake.lastArguments(t)["operations"].([]any)
	if len(forwarded) != 2 {
		t.Fatalf("ops: %v", forwarded)
	}
	op0 := forwarded[0].(map[string]any)
	op1 := forwarded[1].(map[string]any)
	if op0["id_or_name"] != "Rafter W 5" {
		t.Fatalf("op0 id_or_name: %v (type %T)", op0["id_or_name"], op0["id_or_name"])
	}
	if op1["id_or_name"] != "Old Rafter" {
		t.Fatalf("op1 id_or_name: %v", op1["id_or_name"])
	}
}

func TestBatchCreateForwardsExtrusionOp(t *testing.T) {
	s := newSession(t)
	extrusionOp := map[string]any{
		"op":           "extrusion",
		"name":         "Rafter W 1",
		"profile":      rafterProfile,
		"extrude_axis": "y",
		"extrude_from": 0.0,
		"extrude_to":   1.5,
	}
	_ = s.call(t, "batch_create", map[string]any{
		"operations": []map[string]any{extrusionOp},
	})
	forwarded, _ := s.fake.lastArguments(t)["operations"].([]any)
	if !jsonEqual(forwarded[0], extrusionOp) {
		t.Fatalf("op: %v", forwarded[0])
	}
}

func TestBatchCreateForwardsReplaceOp(t *testing.T) {
	s := newSession(t)
	ops := []map[string]any{
		{
			"op":         "replace",
			"id_or_name": "Siding W1",
			"geometry": map[string]any{
				"op":           "extrusion",
				"profile":      [][]float64{{0, 0}, {38, 0}, {38, 96}, {0, 96}},
				"extrude_axis": "y",
				"extrude_from": 0,
				"extrude_to":   0.5,
			},
			"recursive": false,
		},
	}
	_ = s.call(t, "batch_create", map[string]any{"operations": ops})
	mustHave(t, s.fake.lastArguments(t), "operations", ops)
}

func TestBatchCreateFailureEnvelopeRoundTrip(t *testing.T) {
	s := newSession(t)
	msg := `batch_create operation #2 ("cube") failed: bad face. Aborted; 2 prior op(s) rolled back.`
	s.fake.NextError = errors.New(msg)
	result := s.call(t, "batch_create", map[string]any{
		"operations": []map[string]any{
			{"op": "cube", "name": "A", "position": []float64{0, 0, 0}, "dimensions": []float64{1, 1, 1}},
			{"op": "cube", "name": "B", "position": []float64{2, 0, 0}, "dimensions": []float64{1, 1, 1}},
			{"op": "cube", "name": "C", "position": []float64{4, 0, 0}, "dimensions": []float64{1, 1, 1}},
		},
	})
	env := envelopeOf(t, result)
	if env.Success || env.Result != nil {
		t.Fatalf("envelope: %v", env)
	}
	errStr, _ := env.Error.(string)
	if !strings.Contains(errStr, "operation #2") || !strings.Contains(errStr, "rolled back") {
		t.Fatalf("error message: %q", errStr)
	}
}

func TestBatchCreatePreservesOpOrder(t *testing.T) {
	s := newSession(t)
	ops := []map[string]any{
		{"op": "cube", "name": "First", "position": []float64{0, 0, 0}, "dimensions": []float64{1, 1, 1}},
		{"op": "cube", "name": "Second", "position": []float64{2, 0, 0}, "dimensions": []float64{1, 1, 1}},
		{"op": "cube", "name": "Third", "position": []float64{4, 0, 0}, "dimensions": []float64{1, 1, 1}},
	}
	_ = s.call(t, "batch_create", map[string]any{"operations": ops})
	forwarded, _ := s.fake.lastArguments(t)["operations"].([]any)
	if len(forwarded) != 3 {
		t.Fatalf("len: %d", len(forwarded))
	}
	gotNames := []string{}
	for _, op := range forwarded {
		gotNames = append(gotNames, op.(map[string]any)["name"].(string))
	}
	wantNames := []string{"First", "Second", "Third"}
	if !jsonEqual(gotNames, wantNames) {
		t.Fatalf("order: got %v, want %v", gotNames, wantNames)
	}
}
