// Command sketchup-mcp is the MCP server that talks to the SketchUp Ruby
// extension on localhost:9876. It serves MCP over stdio.
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/lumberbarons/sketchup-mcp/internal/skpclient"
	"github.com/lumberbarons/sketchup-mcp/internal/tools"
)

// version is stamped at link time by GoReleaser; "dev" in local builds.
var version = "dev"

func main() {
	host := flag.String("host", "localhost", "SketchUp Ruby extension host")
	port := flag.Int("port", 9876, "SketchUp Ruby extension port")
	flag.Parse()

	// Logs must go to stderr — stdout is the MCP transport.
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr, nil)))
	slog.Info("SketchupMCP server starting", "version", version)

	client := skpclient.New(*host, *port)
	reachable := client.Probe()
	if !reachable {
		slog.Warn("SketchUp not reachable; make sure the extension is running and Start Server has been clicked")
	}

	server := mcp.NewServer(&mcp.Implementation{
		Name:    "SketchupMCP",
		Version: version,
	}, &mcp.ServerOptions{
		Instructions: buildInstructions(*host, *port, reachable),
	})
	tools.RegisterAll(server, client)

	ctx := context.Background()
	if err := server.Run(ctx, &mcp.StdioTransport{}); err != nil {
		fmt.Fprintln(os.Stderr, "server exited with error:", err)
		os.Exit(1)
	}
}

// buildInstructions returns the MCP Instructions string, appending a
// reachability advisory when the startup probe failed so the MCP client
// surfaces the diagnostic rather than only learning about it on the first
// failing tool call. Advisory-only — the extension can come up after the
// MCP server starts.
func buildInstructions(host string, port int, reachable bool) string {
	base := "Sketchup integration through the Model Context Protocol"
	if reachable {
		return base
	}
	return fmt.Sprintf(
		"%s\n\nNOTE: the SketchUp extension was not reachable on %s:%d at startup. Tool calls will fail until you open SketchUp, install the su_mcp extension, and click Extensions → MCP Server → Start Server.",
		base, host, port,
	)
}
