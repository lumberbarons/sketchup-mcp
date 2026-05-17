// Package skpclient is the stateless TCP client that talks to the SketchUp
// Ruby server. SketchUp closes the client socket after each request, so every
// SendCommand opens a fresh connection.
package skpclient

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"strconv"
	"syscall"
	"time"
)

// Client is the stateless JSON-RPC client.
type Client struct {
	Host    string
	Port    int
	Timeout time.Duration

	// CallTimeout bounds an entire request/response cycle on an open socket.
	// Once the TCP connection is established, the read+write must complete
	// within this budget — otherwise SetDeadline trips and the call returns
	// a timeout error. Zero means no per-call deadline.
	//
	// Defaulted generously by New() because some tools (large boolean_op,
	// batch_create on big models, eval_ruby) are legitimately slow.
	CallTimeout time.Duration

	// Dialer is an optional hook for tests. When nil, SendCommand dials TCP
	// to Host:Port with Timeout.
	Dialer func() (net.Conn, error)

	// Logger is used for diagnostics; defaults to slog.Default().
	Logger *slog.Logger
}

// New returns a Client with a 3-second dial timeout (localhost: extension
// running = connect is near-instant; extension not running = we want a
// fast failure) and a 120-second per-call timeout.
func New(host string, port int) *Client {
	return &Client{
		Host:        host,
		Port:        port,
		Timeout:     3 * time.Second,
		CallTimeout: 120 * time.Second,
	}
}

func (c *Client) logger() *slog.Logger {
	if c.Logger != nil {
		return c.Logger
	}
	return slog.Default()
}

func (c *Client) openSocket() (net.Conn, error) {
	if c.Dialer != nil {
		return c.Dialer()
	}
	addr := net.JoinHostPort(c.Host, strconv.Itoa(c.Port))
	return net.DialTimeout("tcp", addr, c.Timeout)
}

// Probe is a one-shot reachability check for startup diagnostics.
func (c *Client) Probe() bool {
	conn, err := c.openSocket()
	if err != nil {
		c.logger().Warn("SketchUp not reachable", "host", c.Host, "port", c.Port, "err", err)
		return false
	}
	_ = conn.Close()
	c.logger().Info("SketchUp reachable", "host", c.Host, "port", c.Port)
	return true
}

// SendCommand sends a JSON-RPC request and returns the unwrapped result.
//
// Retries are limited to connect-time failures so we never replay a request
// that may have already reached SketchUp. Once the socket is open, send/recv
// failures bubble up.
func (c *Client) SendCommand(method string, params map[string]any, requestID any) (any, error) {
	if params == nil {
		params = map[string]any{}
	}
	request := map[string]any{
		"jsonrpc": "2.0",
		"method":  method,
		"params":  params,
		"id":      requestID,
	}

	conn, err := c.connectWithRetries(2)
	if err != nil {
		return nil, err
	}
	defer conn.Close()

	if c.CallTimeout > 0 {
		_ = conn.SetDeadline(time.Now().Add(c.CallTimeout))
	}

	if err := c.sendRequest(conn, request); err != nil {
		return nil, wrapTimeoutErr(err, c.CallTimeout)
	}
	response, err := c.readResponse(conn)
	if err != nil {
		return nil, wrapTimeoutErr(err, c.CallTimeout)
	}
	return unwrapResponse(response)
}

// wrapTimeoutErr replaces a net-timeout error with a user-facing
// SketchupTimeoutError. Non-timeout errors pass through unchanged.
func wrapTimeoutErr(err error, budget time.Duration) error {
	if err == nil {
		return nil
	}
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() {
		return &SketchupTimeoutError{Budget: budget, Cause: err}
	}
	return err
}

func (c *Client) connectWithRetries(maxRetries int) (net.Conn, error) {
	var lastErr error
	attempts := 0
	for attempt := 0; attempt <= maxRetries; attempt++ {
		attempts++
		conn, err := c.openSocket()
		if err == nil {
			return conn, nil
		}
		lastErr = err
		c.logger().Warn("connect failed",
			"attempt", attempt+1,
			"of", maxRetries+1,
			"err", err)
		// Connection-refused = extension is not running; retrying won't
		// help and just delays the user-visible failure. Fail fast.
		if isConnRefused(err) {
			break
		}
	}
	if isExtensionUnreachable(lastErr) {
		return nil, &ExtensionUnreachableError{Host: c.Host, Port: c.Port, Cause: lastErr}
	}
	return nil, fmt.Errorf("could not connect to SketchUp at %s:%d after %d attempts: %w",
		c.Host, c.Port, attempts, lastErr)
}

// isConnRefused reports whether err is a "connection refused" dial error.
func isConnRefused(err error) bool {
	return errors.Is(err, syscall.ECONNREFUSED)
}

// isExtensionUnreachable matches the dial-class failures that indicate the
// extension is not running or unreachable on the network.
func isExtensionUnreachable(err error) bool {
	if err == nil {
		return false
	}
	if isConnRefused(err) {
		return true
	}
	if errors.Is(err, syscall.EHOSTUNREACH) || errors.Is(err, syscall.ENETUNREACH) {
		return true
	}
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() {
		var opErr *net.OpError
		if errors.As(err, &opErr) && opErr.Op == "dial" {
			return true
		}
	}
	return false
}

func (c *Client) sendRequest(conn net.Conn, request map[string]any) error {
	payload, err := json.Marshal(request)
	if err != nil {
		return fmt.Errorf("marshal request: %w", err)
	}
	payload = append(payload, '\n')

	toolName := request["method"]
	if p, ok := request["params"].(map[string]any); ok {
		if n, ok := p["name"]; ok {
			toolName = n
		}
	}
	c.logger().Info("calling tool", "name", toolName, "bytes", len(payload))

	if _, err := conn.Write(payload); err != nil {
		return fmt.Errorf("send: %w", err)
	}
	return nil
}

func (c *Client) readResponse(conn net.Conn) (any, error) {
	// Both sides terminate JSON messages with '\n', so one ReadBytes = one message.
	reader := bufio.NewReader(conn)
	line, readErr := reader.ReadBytes('\n')
	if len(line) == 0 {
		if readErr != nil {
			return nil, fmt.Errorf("connection closed before receiving any data: %w", readErr)
		}
		return nil, fmt.Errorf("connection closed before receiving any data")
	}
	// Trim trailing newline if present; tolerate missing newline at EOF.
	hadNewline := line[len(line)-1] == '\n'
	if hadNewline {
		line = line[:len(line)-1]
	}
	var parsed any
	if err := json.Unmarshal(line, &parsed); err != nil {
		// A connection dropped mid-message will return bytes without a
		// trailing newline plus io.EOF / io.ErrUnexpectedEOF. Distinguish
		// that from genuinely malformed JSON the server sent.
		if !hadNewline && (errors.Is(readErr, io.EOF) || errors.Is(readErr, io.ErrUnexpectedEOF)) {
			return nil, fmt.Errorf("connection dropped mid-response (extension likely crashed or SketchUp quit) — partial bytes: %d", len(line))
		}
		return nil, fmt.Errorf("parse response: %w", err)
	}
	return parsed, nil
}

// unwrapResponse extracts the result from a JSON-RPC envelope:
//   - non-dict responses are returned as-is
//   - a non-null "error" value raises with error.message or a default string;
//     {"error": null} is treated as success (this diverges intentionally from
//     the Python _unwrap_response, whose `in` check treats key presence —
//     even with null value — as failure, and would silently discard the real
//     result for standard JSON-RPC 2.0 envelopes that include error=null on
//     success)
//   - otherwise returns result["result"] or an empty map if missing
func unwrapResponse(response any) (any, error) {
	m, ok := response.(map[string]any)
	if !ok {
		return response, nil
	}
	if errVal, present := m["error"]; present && errVal != nil {
		msg := "Unknown error from Sketchup"
		if errMap, ok := errVal.(map[string]any); ok {
			if s, ok := errMap["message"].(string); ok && s != "" {
				msg = s
			}
		}
		return nil, &SketchupError{Message: msg, Raw: errVal}
	}
	if result, ok := m["result"]; ok {
		return result, nil
	}
	return map[string]any{}, nil
}

// SketchupError wraps a JSON-RPC error returned by the SketchUp Ruby server.
type SketchupError struct {
	Message string
	Raw     any
}

func (e *SketchupError) Error() string { return e.Message }

// ExtensionUnreachableError signals that the SketchUp Ruby extension could
// not be reached over TCP — the extension is probably not running.
type ExtensionUnreachableError struct {
	Host  string
	Port  int
	Cause error
}

func (e *ExtensionUnreachableError) Error() string {
	return fmt.Sprintf(
		"SketchUp extension not reachable on %s:%d — open SketchUp, install the su_mcp extension, and click Extensions → MCP Server → Start Server",
		e.Host, e.Port,
	)
}

func (e *ExtensionUnreachableError) Unwrap() error { return e.Cause }

// SketchupTimeoutError signals that the per-call deadline tripped while
// waiting on the SketchUp extension. SketchUp may be stuck on a modal
// dialog or a long-running operation.
type SketchupTimeoutError struct {
	Budget time.Duration
	Cause  error
}

func (e *SketchupTimeoutError) Error() string {
	return fmt.Sprintf(
		"SketchUp did not respond within %s — the extension may be stuck on a modal dialog or a long operation",
		e.Budget,
	)
}

func (e *SketchupTimeoutError) Unwrap() error { return e.Cause }
