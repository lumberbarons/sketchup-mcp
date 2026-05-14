// Package skpclient is the stateless TCP client that talks to the SketchUp
// Ruby server. SketchUp closes the client socket after each request, so every
// SendCommand opens a fresh connection.
package skpclient

import (
	"bufio"
	"encoding/json"
	"fmt"
	"log/slog"
	"net"
	"strconv"
	"time"
)

// Client is the stateless JSON-RPC client.
type Client struct {
	Host    string
	Port    int
	Timeout time.Duration

	// Dialer is an optional hook for tests. When nil, SendCommand dials TCP
	// to Host:Port with Timeout.
	Dialer func() (net.Conn, error)

	// Logger is used for diagnostics; defaults to slog.Default().
	Logger *slog.Logger
}

// New returns a Client with a 15-second timeout, matching the Python default.
func New(host string, port int) *Client {
	return &Client{Host: host, Port: port, Timeout: 15 * time.Second}
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

	if err := c.sendRequest(conn, request); err != nil {
		return nil, err
	}
	response, err := c.readResponse(conn)
	if err != nil {
		return nil, err
	}
	return unwrapResponse(response)
}

func (c *Client) connectWithRetries(maxRetries int) (net.Conn, error) {
	var lastErr error
	for attempt := 0; attempt <= maxRetries; attempt++ {
		conn, err := c.openSocket()
		if err == nil {
			return conn, nil
		}
		lastErr = err
		c.logger().Warn("connect failed",
			"attempt", attempt+1,
			"of", maxRetries+1,
			"err", err)
	}
	return nil, fmt.Errorf("could not connect to SketchUp at %s:%d after %d attempts: %w",
		c.Host, c.Port, maxRetries+1, lastErr)
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
	line, err := reader.ReadBytes('\n')
	if len(line) == 0 {
		if err != nil {
			return nil, fmt.Errorf("connection closed before receiving any data: %w", err)
		}
		return nil, fmt.Errorf("connection closed before receiving any data")
	}
	// Trim trailing newline if present; tolerate missing newline at EOF.
	if line[len(line)-1] == '\n' {
		line = line[:len(line)-1]
	}
	var parsed any
	if err := json.Unmarshal(line, &parsed); err != nil {
		return nil, fmt.Errorf("parse response: %w", err)
	}
	return parsed, nil
}

// unwrapResponse mirrors the Python _unwrap_response:
//   - non-dict responses are returned as-is
//   - presence of an "error" key (even with null value, mirroring Python's
//     `in` check) raises with the error.message or a default string
//   - otherwise returns result["result"] or an empty map if missing
func unwrapResponse(response any) (any, error) {
	m, ok := response.(map[string]any)
	if !ok {
		return response, nil
	}
	if errVal, present := m["error"]; present {
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
