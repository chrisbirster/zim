#!/usr/bin/env sh
set -eu

REPO="chrisbirster/zim"
INSTALL_DIR="${ZIM_INSTALL_DIR:-$HOME/.local/bin}"
VERSION="${ZIM_VERSION:-latest}"

case "$(uname -s)" in
  Darwin) OS="macos" ;;
  Linux) OS="linux" ;;
  *) echo "zim: unsupported operating system: $(uname -s)" >&2; exit 1 ;;
esac

case "$(uname -m)" in
  x86_64|amd64) ARCH="x86_64" ;;
  arm64|aarch64) ARCH="aarch64" ;;
  *) echo "zim: unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

ASSET="zim-${OS}-${ARCH}.tar.gz"
if [ "$VERSION" = "latest" ]; then
  URL="https://github.com/${REPO}/releases/latest/download/${ASSET}"
else
  case "$VERSION" in v*) TAG="$VERSION" ;; *) TAG="v$VERSION" ;; esac
  URL="https://github.com/${REPO}/releases/download/${TAG}/${ASSET}"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

echo "Installing Zim from $URL"
curl -fL --retry 3 "$URL" -o "$TMP/$ASSET"
tar -xzf "$TMP/$ASSET" -C "$TMP"
mkdir -p "$INSTALL_DIR"
cp "$TMP/zim-${OS}-${ARCH}/zim" "$INSTALL_DIR/zim"
chmod +x "$INSTALL_DIR/zim"
"$INSTALL_DIR/zim" --version

echo "Installed $INSTALL_DIR/zim"
