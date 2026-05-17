package skpclient

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"reflect"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

func newClient() *Client {
	return &Client{Host: "localhost", Port: 9876, Timeout: time.Second}
}

// -- New constructor ---------------------------------------------------------

func TestNew_DefaultsAndAddress(t *testing.T) {
	c := New("h", 1)
	if c.Host != "h" {
		t.Errorf("Host: want %q, got %q", "h", c.Host)
	}
	if c.Port != 1 {
		t.Errorf("Port: want 1, got %d", c.Port)
	}
	if c.Timeout != 3*time.Second {
		t.Errorf("Timeout: want 3s, got %s", c.Timeout)
	}
	if c.CallTimeout != 120*time.Second {
		t.Errorf("CallTimeout: want 120s, got %s", c.CallTimeout)
	}
}

// -- unwrapResponse ----------------------------------------------------------

func TestUnwrap_ReturnsResultPayload(t *testing.T) {
	env := map[string]any{
		"jsonrpc": "2.0",
		"id":      float64(1),
		"result":  map[string]any{"a": float64(1), "b": []any{float64(2), float64(3)}},
	}
	got, err := unwrapResponse(env)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := map[string]any{"a": float64(1), "b": []any{float64(2), float64(3)}}
	if !jsonEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestUnwrap_EmptyMapWhenResultMissing(t *testing.T) {
	env := map[string]any{"jsonrpc": "2.0", "id": float64(1)}
	got, err := unwrapResponse(env)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if m, ok := got.(map[string]any); !ok || len(m) != 0 {
		t.Fatalf("got %v, want empty map", got)
	}
}

func TestUnwrap_RaisesWithErrorMessage(t *testing.T) {
	errVal := map[string]any{"message": "boom", "code": float64(-32000)}
	env := map[string]any{
		"jsonrpc": "2.0", "id": float64(1),
		"error": errVal,
	}
	_, err := unwrapResponse(env)
	if err == nil || !strings.Contains(err.Error(), "boom") {
		t.Fatalf("want error containing 'boom', got %v", err)
	}
	var se *SketchupError
	if !errors.As(err, &se) {
		t.Fatalf("want *SketchupError, got %T", err)
	}
	if !reflect.DeepEqual(se.Raw, errVal) {
		t.Fatalf("Raw: got %v, want %v", se.Raw, errVal)
	}
}

func TestUnwrap_NullErrorIsSuccess(t *testing.T) {
	env := map[string]any{
		"jsonrpc": "2.0", "id": float64(1),
		"result": "ok",
		"error":  nil,
	}
	got, err := unwrapResponse(env)
	if err != nil {
		t.Fatalf("want nil error for {error: null}, got %v", err)
	}
	if got != "ok" {
		t.Fatalf("want result 'ok', got %v", got)
	}
}

func TestUnwrap_UnknownWhenMessageMissing(t *testing.T) {
	env := map[string]any{"error": map[string]any{"code": float64(-1)}}
	_, err := unwrapResponse(env)
	if err == nil || !strings.Contains(err.Error(), "Unknown error from Sketchup") {
		t.Fatalf("want default error message, got %v", err)
	}
}

func TestUnwrap_PassesThroughNonDict(t *testing.T) {
	got, err := unwrapResponse("scalar")
	if err != nil || got != "scalar" {
		t.Fatalf("scalar: got %v err %v", got, err)
	}
	list := []any{float64(1), float64(2), float64(3)}
	got, err = unwrapResponse(list)
	if err != nil || !jsonEqual(got, list) {
		t.Fatalf("list: got %v err %v", got, err)
	}
}

// -- readResponse ------------------------------------------------------------

func TestRead_OneNewlineTerminatedJSON(t *testing.T) {
	c := newClient()
	server, client := net.Pipe()
	defer client.Close()

	go func() {
		_, _ = server.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":"ok"}` + "\n"))
		_ = server.Close()
	}()

	got, err := c.readResponse(client)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := map[string]any{"jsonrpc": "2.0", "id": float64(1), "result": "ok"}
	if !jsonEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestRead_StopsAtFirstNewline(t *testing.T) {
	c := newClient()
	server, client := net.Pipe()
	defer client.Close()

	go func() {
		_, _ = server.Write([]byte(`{"id":1,"result":"first"}` + "\n" + `{"id":2,"result":"second"}` + "\n"))
		// Leave server open — we only want one line.
	}()

	got, err := c.readResponse(client)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := map[string]any{"id": float64(1), "result": "first"}
	if !jsonEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestRead_RaisesOnImmediateEOF(t *testing.T) {
	c := newClient()
	server, client := net.Pipe()
	defer client.Close()

	go func() { _ = server.Close() }()

	_, err := c.readResponse(client)
	if err == nil || !strings.Contains(err.Error(), "connection closed before receiving any data") {
		t.Fatalf("want EOF error, got %v", err)
	}
}

func TestRead_RaisesOnMalformedJSON(t *testing.T) {
	c := newClient()
	server, client := net.Pipe()
	defer client.Close()

	go func() {
		_, _ = server.Write([]byte("not json\n"))
		_ = server.Close()
	}()

	_, err := c.readResponse(client)
	if err == nil {
		t.Fatalf("expected JSON error, got nil")
	}
	var syntaxErr *json.SyntaxError
	if !errors.As(err, &syntaxErr) {
		t.Fatalf("want *json.SyntaxError, got %T (%v)", err, err)
	}
}

func TestRead_ToleratesMissingTrailingNewline(t *testing.T) {
	c := newClient()
	server, client := net.Pipe()
	defer client.Close()

	go func() {
		// Valid, complete JSON but no trailing '\n' before close.
		_, _ = server.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":"ok"}`))
		_ = server.Close()
	}()

	got, err := c.readResponse(client)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := map[string]any{"jsonrpc": "2.0", "id": float64(1), "result": "ok"}
	if !jsonEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestRead_RaisesMidResponseEOF(t *testing.T) {
	c := newClient()
	server, client := net.Pipe()
	defer client.Close()

	go func() {
		_, _ = server.Write([]byte(`{"id":1,"result":"par`)) // truncated, no newline
		_ = server.Close()
	}()

	_, err := c.readResponse(client)
	if err == nil {
		t.Fatal("want mid-response error, got nil")
	}
	if !strings.Contains(err.Error(), "connection dropped mid-response") {
		t.Fatalf("want mid-response message, got %q", err.Error())
	}
}

// -- connectWithRetries ------------------------------------------------------

func TestConnect_SucceedsFirstAttempt(t *testing.T) {
	c := newClient()
	var attempts int32
	c.Dialer = func() (net.Conn, error) {
		atomic.AddInt32(&attempts, 1)
		return &nopConn{}, nil
	}
	conn, err := c.connectWithRetries(2)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	_ = conn.Close()
	if got := atomic.LoadInt32(&attempts); got != 1 {
		t.Fatalf("want 1 attempt, got %d", got)
	}
}

func TestConnect_RetriesThenSucceeds(t *testing.T) {
	c := newClient()
	var attempts int32
	c.Dialer = func() (net.Conn, error) {
		n := atomic.AddInt32(&attempts, 1)
		if n < 3 {
			return nil, errors.New("connection refused")
		}
		return &nopConn{}, nil
	}
	conn, err := c.connectWithRetries(2)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	_ = conn.Close()
	if got := atomic.LoadInt32(&attempts); got != 3 {
		t.Fatalf("want 3 attempts, got %d", got)
	}
}

func TestConnect_FailsFastOnConnRefused(t *testing.T) {
	c := newClient()
	var attempts int32
	c.Dialer = func() (net.Conn, error) {
		atomic.AddInt32(&attempts, 1)
		// Wrap ECONNREFUSED the way net.Dial would.
		return nil, &net.OpError{Op: "dial", Err: &os.SyscallError{Syscall: "connect", Err: syscall.ECONNREFUSED}}
	}
	_, err := c.connectWithRetries(2)
	if err == nil {
		t.Fatal("want error, got nil")
	}
	if got := atomic.LoadInt32(&attempts); got != 1 {
		t.Fatalf("ECONNREFUSED must skip retries; got %d attempts", got)
	}
	var ue *ExtensionUnreachableError
	if !errors.As(err, &ue) {
		t.Fatalf("want *ExtensionUnreachableError, got %T (%v)", err, err)
	}
	if !strings.Contains(ue.Error(), "extension not reachable") {
		t.Fatalf("want friendly message, got %q", ue.Error())
	}
}

func TestConnect_RaisesAfterExhaustingRetries(t *testing.T) {
	c := newClient()
	var attempts int32
	c.Dialer = func() (net.Conn, error) {
		atomic.AddInt32(&attempts, 1)
		return nil, errors.New("nope")
	}
	_, err := c.connectWithRetries(2)
	if err == nil || !strings.Contains(err.Error(), "after 3 attempts") {
		t.Fatalf("want 'after 3 attempts', got %v", err)
	}
	if got := atomic.LoadInt32(&attempts); got != 3 {
		t.Fatalf("want 3 attempts, got %d", got)
	}
}

// -- SendCommand retry policy ------------------------------------------------

// The retry policy is the central safety contract: connect failures are
// retried (idempotent), but any failure after the connect succeeds must NOT
// be retried, since a partial send may already have reached SketchUp.

func TestSend_DoesNotRetryAfterSuccessfulConnect(t *testing.T) {
	c := newClient()
	var dials int32
	fakeConn := &recordingConn{writeErr: errors.New("send failed mid-flight")}
	c.Dialer = func() (net.Conn, error) {
		atomic.AddInt32(&dials, 1)
		return fakeConn, nil
	}

	_, err := c.SendCommand("anything", nil, nil)
	if err == nil || !strings.Contains(err.Error(), "send failed mid-flight") {
		t.Fatalf("want send-failure, got %v", err)
	}
	if got := atomic.LoadInt32(&dials); got != 1 {
		t.Fatalf("send-failure must not trigger reconnect; got %d dials", got)
	}
	if fakeConn.writeCalls != 1 {
		t.Fatalf("want 1 write call, got %d", fakeConn.writeCalls)
	}
}

func TestSend_RetriesOnlyOnConnectFailures(t *testing.T) {
	c := newClient()
	var attempts int32

	// net.Pipe is synchronous, so the server side must read the request
	// before writing the response (otherwise the writer would deadlock).
	server, client := net.Pipe()
	go func() {
		defer server.Close()
		reader := bufio.NewReader(server)
		_, _ = reader.ReadBytes('\n')
		_, _ = server.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":{"ok":true}}` + "\n"))
	}()

	c.Dialer = func() (net.Conn, error) {
		n := atomic.AddInt32(&attempts, 1)
		if n == 1 {
			return nil, errors.New("first attempt fails at connect")
		}
		return client, nil
	}

	got, err := c.SendCommand("noop", map[string]any{"x": float64(1)}, float64(42))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := map[string]any{"ok": true}
	if !jsonEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	if n := atomic.LoadInt32(&attempts); n != 2 {
		t.Fatalf("want 2 attempts, got %d", n)
	}
}

// TestSend_RetriesUpToBudgetThenFails pins the retry budget at the public
// API boundary so it'd fail if SendCommand silently dropped retries below 2.
func TestSend_RetriesUpToBudgetThenFails(t *testing.T) {
	c := newClient()
	var attempts int32
	c.Dialer = func() (net.Conn, error) {
		atomic.AddInt32(&attempts, 1)
		return nil, errors.New("dial refused")
	}
	_, err := c.SendCommand("noop", nil, nil)
	if err == nil {
		t.Fatal("want error after exhausted retries, got nil")
	}
	if got := atomic.LoadInt32(&attempts); got != 3 {
		t.Fatalf("want 3 dial attempts (budget=2 retries), got %d", got)
	}
}

// -- SendCommand happy path --------------------------------------------------

func TestSend_SerialisesRequestAndUnwrapsResult(t *testing.T) {
	c := newClient()
	server, client := net.Pipe()

	// Drain whatever the client writes into a buffer that the test inspects.
	type drained struct {
		bytes []byte
		err   error
	}
	drainCh := make(chan drained, 1)
	go func() {
		defer server.Close()
		reader := bufio.NewReader(server)
		line, err := reader.ReadBytes('\n')
		drainCh <- drained{bytes: line, err: err}
		_, _ = server.Write([]byte(`{"jsonrpc":"2.0","id":7,"result":{"id":"comp-1"}}` + "\n"))
	}()

	c.Dialer = func() (net.Conn, error) { return client, nil }
	got, err := c.SendCommand(
		"tools/call",
		map[string]any{"name": "create_component", "arguments": map[string]any{"type": "cube"}},
		float64(7),
	)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := map[string]any{"id": "comp-1"}
	if !jsonEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}

	// Inspect bytes the client wrote: single newline-terminated JSON-RPC envelope.
	d := <-drainCh
	if d.err != nil && d.err != io.EOF {
		t.Fatalf("read error: %v", d.err)
	}
	if len(d.bytes) == 0 || d.bytes[len(d.bytes)-1] != '\n' {
		t.Fatalf("expected newline-terminated payload, got %q", d.bytes)
	}
	var decoded map[string]any
	if err := json.Unmarshal(d.bytes[:len(d.bytes)-1], &decoded); err != nil {
		t.Fatalf("decode: %v", err)
	}
	wantReq := map[string]any{
		"jsonrpc": "2.0",
		"method":  "tools/call",
		"params": map[string]any{
			"name":      "create_component",
			"arguments": map[string]any{"type": "cube"},
		},
		"id": float64(7),
	}
	if !jsonEqual(decoded, wantReq) {
		t.Fatalf("request envelope mismatch:\n got %v\nwant %v", decoded, wantReq)
	}
}

func TestSend_NilParamsSerializesAsEmptyObject(t *testing.T) {
	c := newClient()
	server, client := net.Pipe()
	drainCh := make(chan []byte, 1)
	go func() {
		defer server.Close()
		reader := bufio.NewReader(server)
		line, _ := reader.ReadBytes('\n')
		drainCh <- line
		_, _ = server.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":"ok"}` + "\n"))
	}()
	c.Dialer = func() (net.Conn, error) { return client, nil }

	if _, err := c.SendCommand("noop", nil, float64(1)); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	line := <-drainCh
	if len(line) == 0 || line[len(line)-1] != '\n' {
		t.Fatalf("expected newline-terminated payload, got %q", line)
	}
	var decoded map[string]any
	if err := json.Unmarshal(line[:len(line)-1], &decoded); err != nil {
		t.Fatalf("decode: %v", err)
	}
	params, ok := decoded["params"]
	if !ok {
		t.Fatal("envelope must include params key for nil-params call")
	}
	m, ok := params.(map[string]any)
	if !ok {
		t.Fatalf("params must be a JSON object, got %T", params)
	}
	if len(m) != 0 {
		t.Fatalf("params must be {}, got %v", m)
	}
}

func TestSend_PropagatesSketchupErrorEnvelope(t *testing.T) {
	c := newClient()
	server, client := net.Pipe()
	go func() {
		defer server.Close()
		reader := bufio.NewReader(server)
		_, _ = reader.ReadBytes('\n')
		_, _ = server.Write([]byte(`{"jsonrpc":"2.0","id":1,"error":{"message":"ruby boom"}}` + "\n"))
	}()
	c.Dialer = func() (net.Conn, error) { return client, nil }

	_, err := c.SendCommand("tools/call", nil, nil)
	if err == nil || !strings.Contains(err.Error(), "ruby boom") {
		t.Fatalf("want 'ruby boom', got %v", err)
	}
}

// -- CallTimeout / SketchupTimeoutError --------------------------------------

func TestSend_TimesOutWhenSocketStalls(t *testing.T) {
	c := newClient()
	c.CallTimeout = 50 * time.Millisecond

	server, client := net.Pipe()
	defer server.Close()
	// Server reads but never replies — simulates SketchUp accepting the
	// connection then hanging on a modal dialog.
	go func() {
		reader := bufio.NewReader(server)
		_, _ = reader.ReadBytes('\n')
		// hold the socket open without responding
		select {}
	}()

	c.Dialer = func() (net.Conn, error) { return client, nil }

	_, err := c.SendCommand("noop", nil, nil)
	if err == nil {
		t.Fatal("want timeout error, got nil")
	}
	var te *SketchupTimeoutError
	if !errors.As(err, &te) {
		t.Fatalf("want *SketchupTimeoutError, got %T (%v)", err, err)
	}
	if te.Budget != 50*time.Millisecond {
		t.Fatalf("want Budget=50ms, got %s", te.Budget)
	}
	if !strings.Contains(te.Error(), "SketchUp did not respond") {
		t.Fatalf("want user-facing message, got %q", te.Error())
	}
}

// -- Probe -------------------------------------------------------------------

func TestProbe_TrueWhenSocketOpens(t *testing.T) {
	c := newClient()
	conn := &nopConn{}
	c.Dialer = func() (net.Conn, error) { return conn, nil }
	if !c.Probe() {
		t.Fatal("want true")
	}
	if !conn.closed {
		t.Fatal("probe must close the connection")
	}
}

func TestProbe_FalseWhenSocketFails(t *testing.T) {
	c := newClient()
	c.Dialer = func() (net.Conn, error) { return nil, errors.New("refused") }
	if c.Probe() {
		t.Fatal("want false")
	}
}

// -- helpers -----------------------------------------------------------------

func jsonEqual(a, b any) bool {
	ja, err1 := json.Marshal(a)
	jb, err2 := json.Marshal(b)
	if err1 != nil || err2 != nil {
		return false
	}
	return string(ja) == string(jb)
}

type nopConn struct {
	closed bool
}

func (n *nopConn) Read(_ []byte) (int, error)         { return 0, io.EOF }
func (n *nopConn) Write(b []byte) (int, error)        { return len(b), nil }
func (n *nopConn) Close() error                       { n.closed = true; return nil }
func (n *nopConn) LocalAddr() net.Addr                { return dummyAddr{} }
func (n *nopConn) RemoteAddr() net.Addr               { return dummyAddr{} }
func (n *nopConn) SetDeadline(_ time.Time) error      { return nil }
func (n *nopConn) SetReadDeadline(_ time.Time) error  { return nil }
func (n *nopConn) SetWriteDeadline(_ time.Time) error { return nil }

type recordingConn struct {
	nopConn
	writeErr   error
	writeCalls int
}

func (r *recordingConn) Write(b []byte) (int, error) {
	r.writeCalls++
	if r.writeErr != nil {
		return 0, r.writeErr
	}
	return len(b), nil
}

type dummyAddr struct{}

func (dummyAddr) Network() string { return "test" }
func (dummyAddr) String() string  { return "test" }
