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
  BASE_URL="https://github.com/${REPO}/releases/latest/download"
else
  case "$VERSION" in v*) TAG="$VERSION" ;; *) TAG="v$VERSION" ;; esac
  BASE_URL="https://github.com/${REPO}/releases/download/${TAG}"
fi
URL="${BASE_URL}/${ASSET}"
CHECKSUM_URL="${BASE_URL}/SHA256SUMS.txt"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

echo "Installing Zim from $URL"
curl -fL --retry 3 "$URL" -o "$TMP/$ASSET"
curl -fL --retry 3 "$CHECKSUM_URL" -o "$TMP/SHA256SUMS.txt"

EXPECTED="$(awk -v asset="$ASSET" '$2 == asset { print $1 }' "$TMP/SHA256SUMS.txt")"
if [ -z "$EXPECTED" ]; then
  echo "zim: checksum for $ASSET not found in release" >&2
  exit 1
fi
if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL="$(sha256sum "$TMP/$ASSET" | awk '{ print $1 }')"
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL="$(shasum -a 256 "$TMP/$ASSET" | awk '{ print $1 }')"
else
  echo "zim: sha256sum or shasum is required to verify the release" >&2
  exit 1
fi
if [ "$EXPECTED" != "$ACTUAL" ]; then
  echo "zim: SHA-256 verification failed for $ASSET" >&2
  exit 1
fi

tar -xzf "$TMP/$ASSET" -C "$TMP"
mkdir -p "$INSTALL_DIR"
cp "$TMP/zim-${OS}-${ARCH}/zim" "$INSTALL_DIR/zim"
chmod +x "$INSTALL_DIR/zim"
"$INSTALL_DIR/zim" --version

echo "Installed $INSTALL_DIR/zim"
