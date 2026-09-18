#!/bin/bash
set -e

# build-sample-app.sh - Rebuilds the sample-app ARM64 Linux binary from source.
#
# Run after editing sample-release/src/sample-app/main.go. Produces the
# statically linked arm64 binary that build-compiled-release.sh packages into
# the BOSH release. Requires the Go toolchain (https://go.dev/dl/).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_DIR="$REPO_ROOT/sample-release/src/sample-app"

if ! command -v go >/dev/null 2>&1; then
    echo "Error: Go toolchain not found. Install from https://go.dev/dl/ and retry."
    exit 1
fi

echo "Building sample-app for linux/arm64..."
cd "$SRC_DIR"
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o app ./...

echo ""
echo "Built: $SRC_DIR/app"
file "$SRC_DIR/app" 2>/dev/null || true
echo ""
echo "Next: ./scripts/build-compiled-release.sh   (packages the binary into the BOSH release)"
echo "Then: ./scripts/deploy-sample.sh            (deploys to the Director)"
