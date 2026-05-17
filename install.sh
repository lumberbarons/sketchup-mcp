#!/usr/bin/env bash
# Install the sketchup-mcp binary and download the matching SketchUp
# extension (.rbz). Run via:
#
#   curl -fsSL https://raw.githubusercontent.com/lumberbarons/sketchup-mcp/main/install.sh | bash
#
# Environment overrides:
#   SKETCHUP_MCP_VERSION   Pin to a specific release tag (e.g. v2.0.0). Default: latest.
#   INSTALL_DIR            Where to place the binary. Default: /usr/local/bin if writable, else ~/.local/bin.
#   RBZ_DIR                Where to drop the .rbz. Default: ~/Downloads.
set -euo pipefail

REPO="lumberbarons/sketchup-mcp"
BIN_NAME="sketchup-mcp"

msg()  { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }
need curl
need tar
need uname

detect_os() {
  case "$(uname -s)" in
    Darwin) echo darwin ;;
    Linux)  echo linux ;;
    *) die "unsupported OS: $(uname -s). Windows users: download the zip from https://github.com/${REPO}/releases/latest" ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    arm64|aarch64) echo arm64 ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}

resolve_version() {
  if [ -n "${SKETCHUP_MCP_VERSION:-}" ]; then
    echo "$SKETCHUP_MCP_VERSION"
    return
  fi
  # Follow the /releases/latest redirect to discover the tag without hitting
  # the rate-limited API. GitHub only redirects when a non-prerelease "latest"
  # exists; otherwise the URL stays on /releases and we ask the user to pin.
  local url tag
  url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/${REPO}/releases/latest") \
    || die "could not resolve latest release"
  tag=$(basename "$url")
  case "$tag" in
    v*) echo "$tag" ;;
    *)  die "no latest release found. Pin a version with SKETCHUP_MCP_VERSION=vX.Y.Z (see https://github.com/${REPO}/releases)" ;;
  esac
}

pick_install_dir() {
  if [ -n "${INSTALL_DIR:-}" ]; then
    echo "$INSTALL_DIR"
    return
  fi
  if [ -w /usr/local/bin ] 2>/dev/null; then
    echo /usr/local/bin
  else
    echo "$HOME/.local/bin"
  fi
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

verify_checksum() {
  local file="$1" expected_line
  expected_line=$(grep " $(basename "$file")\$" checksums.txt) \
    || die "no checksum entry for $(basename "$file")"
  local expected actual
  expected=${expected_line%% *}
  actual=$(sha256_of "$file")
  [ "$expected" = "$actual" ] || die "checksum mismatch for $(basename "$file")"
}

main() {
  local os arch tag version
  os=$(detect_os)
  arch=$(detect_arch)
  tag=$(resolve_version)
  version=${tag#v}

  local install_dir rbz_dir
  install_dir=$(pick_install_dir)
  rbz_dir=${RBZ_DIR:-$HOME/Downloads}

  msg "installing sketchup-mcp $tag for ${os}/${arch}"

  local archive="${BIN_NAME}_${version}_${os}_${arch}.tar.gz"
  local rbz="su_mcp_v${version}.rbz"
  local base="https://github.com/${REPO}/releases/download/${tag}"

  local tmp=""
  tmp=$(mktemp -d)
  trap 'rm -rf "${tmp:-}"' EXIT

  (
    cd "$tmp"
    msg "downloading $archive"
    curl -fsSL -o "$archive" "${base}/${archive}"
    msg "downloading $rbz"
    curl -fsSL -o "$rbz" "${base}/${rbz}"
    msg "downloading checksums.txt"
    curl -fsSL -o checksums.txt "${base}/checksums.txt"

    msg "verifying $archive"
    verify_checksum "$archive"
    msg ".rbz sha256: $(sha256_of "$rbz")"

    tar -xzf "$archive"
  )

  mkdir -p "$install_dir" "$rbz_dir"
  install -m 0755 "$tmp/$BIN_NAME" "$install_dir/$BIN_NAME"
  cp "$tmp/$rbz" "$rbz_dir/$rbz"

  msg "installed $install_dir/$BIN_NAME"
  msg "saved    $rbz_dir/$rbz"

  case ":$PATH:" in
    *":$install_dir:"*) ;;
    *) warn "$install_dir is not on your PATH. Add it with: export PATH=\"$install_dir:\$PATH\"" ;;
  esac

  cat <<EOF

Next steps — install the SketchUp extension:

  1. Open SketchUp
  2. Window → Extension Manager → Install Extension…
  3. Select: $rbz_dir/$rbz
  4. Restart SketchUp

Then point your MCP client at: $install_dir/$BIN_NAME
EOF
}

main "$@"
