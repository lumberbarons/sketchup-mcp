.PHONY: test lint format install rbz

install:
	uv sync --extra test --extra lint

test:
	uv run pytest

lint:
	uv run ruff check .
	uv run ruff format --check .

format:
	uv run ruff check --fix .
	uv run ruff format .

rbz:
	./scripts/build_rbz.sh
