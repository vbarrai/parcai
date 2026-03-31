#!/bin/bash
set -euo pipefail

# parcai installer
# Usage: curl -sSL https://raw.githubusercontent.com/vbarrai/parcai/main/install.sh | bash

REPO="vbarrai/parcai"
INSTALL_DIR="${PARCAI_INSTALL_DIR:-$HOME/.local/share/parcai}"
BIN_DIR="${PARCAI_BIN_DIR:-$HOME/.local/bin}"

# Colors (disabled if not a terminal)
if [ -t 1 ]; then
  BOLD="\033[1m"
  GREEN="\033[32m"
  RED="\033[31m"
  YELLOW="\033[33m"
  RESET="\033[0m"
else
  BOLD="" GREEN="" RED="" YELLOW="" RESET=""
fi

info()  { printf "${GREEN}▸${RESET} %s\n" "$*"; }
warn()  { printf "${YELLOW}▸${RESET} %s\n" "$*"; }
error() { printf "${RED}✗${RESET} %s\n" "$*" >&2; exit 1; }

# --- Checks ---

[ "$(uname -s)" = "Darwin" ] || error "parcai requires macOS (sandbox-exec + APFS)"

command -v curl >/dev/null 2>&1 || error "curl is required"

# --- Determine version ---

if [ -n "${PARCAI_VERSION:-}" ]; then
  TAG="$PARCAI_VERSION"
  info "Installing parcai $TAG"
else
  # Try latest release, fall back to main branch
  TAG=$(curl -sSL -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
    | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4) || true

  if [ -n "$TAG" ]; then
    info "Installing parcai $TAG (latest release)"
  else
    TAG="main"
    info "Installing parcai from main branch"
  fi
fi

# --- Download ---

TMPDIR_INSTALL=$(mktemp -d)
trap 'rm -rf "$TMPDIR_INSTALL"' EXIT

if [ "$TAG" = "main" ]; then
  TARBALL_URL="https://github.com/$REPO/archive/refs/heads/main.tar.gz"
else
  TARBALL_URL="https://github.com/$REPO/archive/refs/tags/$TAG.tar.gz"
fi

info "Downloading from $TARBALL_URL"
curl -sSL "$TARBALL_URL" | tar xz -C "$TMPDIR_INSTALL"

# GitHub archives extract to repo-name-tag/ or repo-name-branch/
EXTRACTED=$(find "$TMPDIR_INSTALL" -mindepth 1 -maxdepth 1 -type d | head -1)
[ -d "$EXTRACTED" ] || error "Failed to extract archive"
[ -f "$EXTRACTED/parcai" ] || error "Archive does not contain parcai script"

# --- Install ---

PREVIOUS_VERSION=""
if [ -d "$INSTALL_DIR" ] && [ -f "$INSTALL_DIR/parcai" ]; then
  PREVIOUS_VERSION=$("$INSTALL_DIR/parcai" --version 2>/dev/null | head -1) || true
  info "Upgrading from ${PREVIOUS_VERSION:-unknown version}"
  rm -rf "$INSTALL_DIR"
fi

mkdir -p "$(dirname "$INSTALL_DIR")"
mkdir -p "$BIN_DIR"

# Copy only what's needed
mkdir -p "$INSTALL_DIR/profiles" "$INSTALL_DIR/proxy"
cp "$EXTRACTED/parcai"                "$INSTALL_DIR/parcai"
cp "$EXTRACTED/profiles/macos.sb.tpl" "$INSTALL_DIR/profiles/macos.sb.tpl"
cp "$EXTRACTED/proxy/parcai-proxy"    "$INSTALL_DIR/proxy/parcai-proxy"
chmod +x "$INSTALL_DIR/parcai" "$INSTALL_DIR/proxy/parcai-proxy"

# Symlink
ln -sf "$INSTALL_DIR/parcai" "$BIN_DIR/parcai"

info "Installed to $INSTALL_DIR"
info "Symlinked $BIN_DIR/parcai"

# --- PATH check ---

if ! echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
  warn "$BIN_DIR is not in your PATH"
  echo ""
  SHELL_NAME=$(basename "$SHELL")
  case "$SHELL_NAME" in
    zsh)  RC_FILE="~/.zshrc" ;;
    bash) RC_FILE="~/.bashrc" ;;
    *)    RC_FILE="your shell config" ;;
  esac
  printf "  Add this to ${BOLD}%s${RESET}:\n\n" "$RC_FILE"
  printf "    export PATH=\"\$HOME/.local/bin:\$PATH\"\n\n"
  printf "  Then restart your shell or run:\n\n"
  printf "    source %s\n\n" "$RC_FILE"
fi

# --- Verify ---

NEW_VERSION=$("$INSTALL_DIR/parcai" --version 2>/dev/null | head -1) || true
if [ -n "$PREVIOUS_VERSION" ] && [ -n "$NEW_VERSION" ]; then
  info "Upgraded: $PREVIOUS_VERSION → $NEW_VERSION"
elif [ -n "$NEW_VERSION" ]; then
  info "$NEW_VERSION installed"
else
  info "Installation complete"
fi

if ! command -v parcai >/dev/null 2>&1; then
  warn "Restart your shell to use parcai."
fi

echo ""
printf "${BOLD}Usage:${RESET}\n"
echo "  cd my-project"
echo "  parcai            # launch claude in a sandbox"
echo ""
