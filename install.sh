#!/bin/sh
set -e

# Caudata Installer
# Installs Caudata to /usr/local/bin or ~/.local/bin via curl | sh

GITHUB_OWNER="quaywin"
GITHUB_REPO="caudata"
BINARY_NAME="caudata"

# Helper for colorized messages
info() {
  echo "\033[1;32m=>\033[0m $1"
}

error() {
  echo "\033[1;31mError:\033[0m $1" >&2
  exit 1
}

# Detect OS
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$OS" in
  darwin)
    TARGET_OS="macos"
    ;;
  linux)
    TARGET_OS="linux"
    ;;
  *)
    error "Unsupported operating system: $OS. Caudata currently supports macOS and Linux."
    ;;
esac

# Detect Architecture
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64)
    TARGET_ARCH="x86_64"
    ;;
  arm64|aarch64)
    TARGET_ARCH="aarch64"
    ;;
  *)
    error "Unsupported architecture: $ARCH. Caudata currently supports x86_64 and aarch64."
    ;;
esac

# Combine to target suffix matching Burrito targets
# e.g., caudata_macos_aarch64, caudata_linux_x86_64
BURRITO_TARGET="${TARGET_OS}_${TARGET_ARCH}"
RELEASE_FILE_NAME="${BINARY_NAME}_${BURRITO_TARGET}"

# If target is linux_aarch64, make sure we have a fallback or warn
if [ "$BURRITO_TARGET" = "linux_aarch64" ]; then
  error "Linux ARM64/aarch64 is not currently defined in Burrito releases. Please build from source."
fi

# Determine version
if [ -z "$VERSION" ]; then
  info "Fetching latest version from GitHub..."
  LATEST_RELEASE_URL="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases/latest"
  # Fetch latest tag name using curl, with a fallback if curl fails or API rate limit hit
  VERSION=$(curl -sSL "$LATEST_RELEASE_URL" | grep '"tag_name":' | sed -E 's/.*"tag_name": "([^"]+)".*/\1/')
  if [ -z "$VERSION" ]; then
    error "Could not auto-detect the latest version from GitHub API (might be rate-limited). Please specify VERSION environment variable. (e.g. VERSION=v0.1.0 sh -c \"\$(curl ...)\")"
  fi
fi

# Clean up version formatting (e.g., v0.1.0 -> v0.1.0)
info "Selected version: $VERSION"

DOWNLOAD_URL="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/download/${VERSION}/${RELEASE_FILE_NAME}"

# Determine installation directory
if [ "$TARGET_OS" = "macos" ]; then
  INSTALL_DIR="$HOME/.local/bin"
  mkdir -p "$INSTALL_DIR"
  USE_SUDO=false
else
  INSTALL_DIR="/usr/local/bin"
  USE_SUDO=false

  if [ ! -w "$INSTALL_DIR" ]; then
    # Fallback to user-local directory if no write access to /usr/local/bin
    INSTALL_DIR="$HOME/.local/bin"
    mkdir -p "$INSTALL_DIR"
    info "No write permission for /usr/local/bin, installing to $INSTALL_DIR instead."
  else
    # Double check if we need sudo just in case
    if [ ! -w "$INSTALL_DIR" ]; then
      USE_SUDO=true
    fi
  fi
fi

TEMP_FILE=$(mktemp)

info "Downloading Caudata from $DOWNLOAD_URL ..."
if curl -sSL --fail -o "$TEMP_FILE" "$DOWNLOAD_URL"; then
  info "Download completed successfully."
else
  rm -f "$TEMP_FILE"
  error "Failed to download Caudata from $DOWNLOAD_URL. Please ensure the release tag and binary exist."
fi

# Install binary
DEST_PATH="${INSTALL_DIR}/${BINARY_NAME}"
info "Installing binary to $DEST_PATH..."

if [ "$USE_SUDO" = true ]; then
  sudo mv "$TEMP_FILE" "$DEST_PATH"
  sudo chmod +x "$DEST_PATH"
else
  mv "$TEMP_FILE" "$DEST_PATH"
  chmod +x "$DEST_PATH"
fi

# Pre-extract Burrito payload to avoid slow first start
info "Pre-extracting application payload (this may take a few seconds)..."
"$DEST_PATH" --version > /dev/null || true

info "Caudata $VERSION installed successfully at $DEST_PATH!"

# PATH check
case :$PATH: in
  *:"$INSTALL_DIR":*) ;;
  *)
    info "WARNING: $INSTALL_DIR is not in your PATH."
    info "You may need to add it to your shell config file (e.g., ~/.bashrc, ~/.zshrc):"
    echo "  export PATH=\"\$PATH:$INSTALL_DIR\""
    ;;
esac

info "Run 'caudata' to start the log streamer."
