.PHONY: help test lint format install rbz
.DEFAULT_GOAL := help

help:  ## Show this help message
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

install:  ## Sync dependencies (test + lint extras)
	uv sync --extra test --extra lint

test:  ## Run the pytest suite
	uv run pytest

lint:  ## Check style (ruff check + ruff format --check)
	uv run ruff check .
	uv run ruff format --check .

format:  ## Apply style fixes (ruff check --fix + ruff format)
	uv run ruff check --fix .
	uv run ruff format .

rbz:  ## Build the SketchUp extension .rbz from su_mcp/
	./scripts/build_rbz.sh
