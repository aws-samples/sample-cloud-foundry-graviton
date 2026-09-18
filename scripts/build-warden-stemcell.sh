#!/bin/bash
# pipefail matters here: the rootfs is produced by `docker export | gzip`, and
# with a bare `set -e` a failed export still yields a "successfully built"
# stemcell wrapping a truncated filesystem.
set -euo pipefail

echo "Building ARM64 Warden Stemcell for BOSH-lite"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$REPO_ROOT/output"
mkdir -p "$OUTPUT_DIR"

# Ensure prerequisite binaries exist in bin/ (built by build-binaries.sh).
# The Dockerfile COPYs them from bin/ at image-build time.
if [ ! -f "$REPO_ROOT/bin/bosh-agent-arm64" ] || [ ! -f "$REPO_ROOT/bin/bosh-blobstore-dav" ]; then
    echo "Prerequisite binaries missing in bin/ - building them..."
    bash "$SCRIPT_DIR/build-binaries.sh"
fi

# Fail fast if the agent in bin/ is not the patched build.
#
# This guards the single worst failure mode in this repo. An unpatched or stale
# bosh-agent-arm64 produces a stemcell that builds and imports cleanly, but whose
# agent never subscribes to its NATS mbus — so the deploy runs for ten minutes and
# then dies with "Timed out pinging VM ... after 600 seconds", an error that points
# at NATS rather than at this binary. bin/ is git-ignored, so a tree can easily
# carry a stale agent from an earlier checkout with nothing to indicate it.
#
# The patch gates the insecure-NATS path on BOSH_AGENT_DEV_INSECURE_NATS, so a
# correctly patched build always contains that name as a string literal.
AGENT_BIN="$REPO_ROOT/bin/bosh-agent-arm64"
if ! grep -aq BOSH_AGENT_DEV_INSECURE_NATS "$AGENT_BIN"; then
    echo "Error: $AGENT_BIN is missing the required dev-workaround patch." >&2
    echo "  A stemcell built from it would deploy, then fail after ~10 minutes with" >&2
    echo "  \"Timed out pinging VM ... after 600 seconds\"." >&2
    echo "  Rebuild the prerequisite binaries:  ./scripts/build-binaries.sh" >&2
    exit 1
fi

echo ""
echo "Step 1: Building ARM64 stemcell Docker image..."
# Build context is the repo root so the Dockerfile's COPY bin/... paths resolve.
docker build --platform linux/arm64 \
    -t bosh-stemcell-arm64:latest \
    -f "$REPO_ROOT/Dockerfile.stemcell" \
    "$REPO_ROOT"

echo ""
echo "Step 2: Verifying image architecture..."
docker inspect bosh-stemcell-arm64:latest --format '{{.Architecture}}'

echo ""
echo "Step 3: Exporting image as rootfs tarball..."
# Docker CPI uses ImageImport (docker import) which expects a raw filesystem tarball
# We must use 'docker export' (from a running container) NOT 'docker save' (image archive)
TEMP_CONTAINER=$(docker create --platform linux/arm64 bosh-stemcell-arm64:latest /bin/true)
docker export "$TEMP_CONTAINER" | gzip >"$OUTPUT_DIR/image"
docker rm "$TEMP_CONTAINER" >/dev/null

echo ""
echo "Step 4: Creating stemcell manifest..."
# `shasum -a 1` rather than `sha1sum`: shasum ships with macOS (the documented
# host platform for this sample) on every release, sha1sum does not.
IMAGE_SHA1=$(shasum -a 1 "$OUTPUT_DIR/image" | awk '{print $1}')
cat >"$OUTPUT_DIR/stemcell.MF" <<EOF
---
name: bosh-warden-boshlite-ubuntu-noble-go_agent
version: '1.0-arm64'
sha1: ${IMAGE_SHA1}
api_version: 3
operating_system: ubuntu-noble
cloud_properties:
  infrastructure: docker
  architecture: arm64
EOF

echo ""
echo "Step 5: Packaging stemcell tarball..."
cd "$OUTPUT_DIR"
tar czf "$REPO_ROOT/bosh-stemcell-1.0-warden-boshlite-ubuntu-noble-arm64.tgz" \
    stemcell.MF image

echo ""
echo "Step 6: Cleanup..."
rm -f "$OUTPUT_DIR/image" "$OUTPUT_DIR/stemcell.MF"
rmdir "$OUTPUT_DIR" 2>/dev/null || true

STEMCELL_FILE="$REPO_ROOT/bosh-stemcell-1.0-warden-boshlite-ubuntu-noble-arm64.tgz"
echo ""
echo "ARM64 Warden Stemcell built"
echo ""
echo "  File: $STEMCELL_FILE"
echo "  Size: $(du -h "$STEMCELL_FILE" | awk '{print $1}')"
echo "  Arch: arm64 (aarch64)"
echo "  OS:   Ubuntu Noble (24.04)"
echo ""
echo "To use with BOSH-lite:"
echo "  bosh upload-stemcell $STEMCELL_FILE"
