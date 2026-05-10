#!/usr/bin/env bash
# Build the SketchUp extension .rbz from su_mcp/.
# A .rbz is just a zip; SketchUp's Extension Manager reads it directly.
set -euo pipefail

cd "$(dirname "$0")/../su_mcp"

version=$(python3 -c 'import json; print(json.load(open("extension.json"))["version"])')
output="../su_mcp_v${version}.rbz"

rm -f "$output"
zip -r "$output" su_mcp.rb extension.json su_mcp/ -x '*.DS_Store' '*/__pycache__/*'

echo "Built $(cd .. && pwd)/$(basename "$output")"
