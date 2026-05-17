.PHONY: help test-ruby test-go lint-go format build rbz tidy
.DEFAULT_GOAL := help

help:  ## Show this help message
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build:  ## Build the Go MCP server binary into ./bin/sketchup-mcp
	@mkdir -p bin
	go build -trimpath -ldflags "-s -w -X main.version=dev" -o bin/sketchup-mcp ./cmd/sketchup-mcp

test-go:  ## Run the Go test suite
	go test ./... -count=1

test-ruby:  ## Run the Ruby minitest suite (no SketchUp required)
	@find su_mcp/test -name 'test_*.rb' ! -name 'test_helper.rb' -print0 \
		| xargs -0 -n1 ruby -Isu_mcp/test

lint-go:  ## Run gofmt and go vet on the Go sources
	@unformatted=$$(gofmt -l . | grep -v '^\.claude/' || true); \
	if [ -n "$$unformatted" ]; then \
		echo "gofmt: files need formatting:"; echo "$$unformatted"; exit 1; \
	fi
	go vet ./...

format:  ## Apply gofmt to the Go sources
	gofmt -w $$(find . -name '*.go' -not -path './.claude/*')

tidy:  ## Run go mod tidy
	go mod tidy

rbz:  ## Build the SketchUp extension .rbz from su_mcp/
	./scripts/build_rbz.sh
