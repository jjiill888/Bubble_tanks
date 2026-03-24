#!/usr/bin/env sh
set -eu

PACKAGE_PATH="$1"
INSTALL_DIR="$2"
EXECUTABLE_NAME="$3"
EXPECTED_SHA256="${4:-}"

if [ ! -f "$PACKAGE_PATH" ]; then
  echo "Missing update package: $PACKAGE_PATH" >&2
  exit 1
fi

if [ ! -d "$INSTALL_DIR" ]; then
  echo "Missing install dir: $INSTALL_DIR" >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/bubble-tanks-update.XXXXXX")"
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

sleep 1

if [ -n "$EXPECTED_SHA256" ]; then
  ACTUAL_SHA256="$(sha256sum "$PACKAGE_PATH" | awk '{print $1}')"
  if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
    echo "SHA256 mismatch" >&2
    exit 1
  fi
fi

EXTRACT_DIR="$TMP_ROOT/payload"
mkdir -p "$EXTRACT_DIR"
tar -xzf "$PACKAGE_PATH" -C "$EXTRACT_DIR"

if [ -f "$EXTRACT_DIR/$EXECUTABLE_NAME" ]; then
  chmod +x "$EXTRACT_DIR/$EXECUTABLE_NAME"
fi

if [ -f "$EXTRACT_DIR/updater/install_update.sh" ]; then
  chmod +x "$EXTRACT_DIR/updater/install_update.sh"
fi

cp -a "$EXTRACT_DIR/." "$INSTALL_DIR/"
rm -f "$PACKAGE_PATH"
nohup "$INSTALL_DIR/$EXECUTABLE_NAME" >/dev/null 2>&1 &