#!/bin/bash
set -euo pipefail

# build-binaries.sh - fetch/build the ARM64 prerequisite binaries into bin/.
#
# bin/ is git-ignored, so the repo carries no committed binaries. Produces
# (all linux/arm64):
#   bosh-agent-arm64    built from cloudfoundry/bosh-agent (pinned tag + patch)
#   bosh-blobstore-dav  davcli, built from cloudfoundry/bosh-davcli (pinned tag)
#   nats-server-arm64   official nats-io/nats-server release binary (sha256-checked)
#
# Requires: git, curl, tar, shasum (or sha256sum), and Go. Re-running overwrites
# existing outputs.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN_DIR="$REPO_ROOT/bin"

# Pinned upstream versions. Bump deliberately and re-validate a deploy; keep in
# sync with the README. Commit SHAs pin the Go sources to an exact tree (a tag
# alone is mutable); NATS_SHA256 pins the downloaded release binary.
#
# bosh-agent is held at v2.824.0 and patched (AGENT_PATCH). The patch is
# required: it makes the agent's NATS connection use no TLS when
# BOSH_AGENT_DEV_INSECURE_NATS is set (the dev stemcell sets it), matching this
# setup's plaintext NATS, and adapts monit/systemd supervision for the
# containerized stemcell. By default the agent keeps upstream mutual TLS.
BOSH_AGENT_REF="v2.824.0"
BOSH_AGENT_COMMIT="fe4a5bd9b8abc4fb290087cb259a29d04794a1ed"
DAVCLI_REF="v0.0.489"
DAVCLI_COMMIT="07c080fd4faab5e8c9f028767f70a29b2c245d3c"
NATS_VERSION="v2.10.24"
NATS_SHA256="a4ae6c46ef545a13a3214bc35696b2806e05b60742f7ed5b2082d3c2f5af854f"

AGENT_PATCH="$SCRIPT_DIR/patches/bosh-agent-dev-workarounds.patch"

export GOOS="linux"
export GOARCH="arm64"
export CGO_ENABLED="0"
# Let Go fetch the toolchain each upstream module requires.
export GOTOOLCHAIN="auto"

if ! command -v go >/dev/null 2>&1; then
    echo "Error: Go toolchain not found. Install from https://go.dev/dl/ and retry." >&2
    exit 1
fi

# sha256_verify FILE EXPECTED - fail if FILE's sha256 does not match EXPECTED.
sha256_verify() {
    local file="$1" expected="$2" actual
    if command -v sha256sum >/dev/null 2>&1; then
        actual="$(sha256sum "$file" | awk '{print $1}')"
    else
        actual="$(shasum -a 256 "$file" | awk '{print $1}')"
    fi
    if [ "$actual" != "$expected" ]; then
        echo "Error: sha256 mismatch for $file" >&2
        echo "  expected: $expected" >&2
        echo "  actual:   $actual" >&2
        exit 1
    fi
}

mkdir -p "$BIN_DIR"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/build-binaries.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "Building ARM64 prerequisite binaries into $BIN_DIR ($GOOS/$GOARCH)"

# bosh-agent (pinned commit + required dev patch).
echo "bosh-agent $BOSH_AGENT_REF ($BOSH_AGENT_COMMIT), patched"
if [ ! -f "$AGENT_PATCH" ]; then
    echo "Error: required bosh-agent patch not found: $AGENT_PATCH" >&2
    exit 1
fi
git clone --quiet --depth 1 --branch "$BOSH_AGENT_REF" \
    https://github.com/cloudfoundry/bosh-agent.git "$WORK_DIR/bosh-agent"
(
    cd "$WORK_DIR/bosh-agent"
    # Verify the checked-out tag resolves to the expected commit, so a moved
    # tag is caught rather than silently built.
    actual_commit="$(git rev-parse HEAD)"
    if [ "$actual_commit" != "$BOSH_AGENT_COMMIT" ]; then
        echo "Error: bosh-agent $BOSH_AGENT_REF resolved to $actual_commit, expected $BOSH_AGENT_COMMIT" >&2
        exit 1
    fi
    # Check the patch applies before mutating the tree, so upstream drift fails
    # with a clear message instead of building an unpatched (non-working) agent.
    if ! git apply --check "$AGENT_PATCH" 2>"$WORK_DIR/patch-check.err"; then
        echo "Error: bosh-agent patch does not apply to $BOSH_AGENT_REF:" >&2
        sed 's/^/  /' "$WORK_DIR/patch-check.err" >&2
        echo "  Regenerate scripts/patches/$(basename "$AGENT_PATCH") and re-validate a deploy." >&2
        exit 1
    fi
    git apply "$AGENT_PATCH"
    go build -o "$BIN_DIR/bosh-agent-arm64" ./main/
)

# davcli (bosh-blobstore-dav).
echo "bosh-davcli $DAVCLI_REF"
git clone --quiet --depth 1 --branch "$DAVCLI_REF" \
    https://github.com/cloudfoundry/bosh-davcli.git "$WORK_DIR/bosh-davcli"
(
    cd "$WORK_DIR/bosh-davcli"
    actual_commit="$(git rev-parse HEAD)"
    if [ "$actual_commit" != "$DAVCLI_COMMIT" ]; then
        echo "Error: bosh-davcli $DAVCLI_REF resolved to $actual_commit, expected $DAVCLI_COMMIT" >&2
        exit 1
    fi
    go build -o "$BIN_DIR/bosh-blobstore-dav" ./main/
)

# nats-server (official release binary, sha256-verified).
echo "nats-server $NATS_VERSION"
NATS_TARBALL="nats-server-${NATS_VERSION}-linux-arm64.tar.gz"
NATS_URL="https://github.com/nats-io/nats-server/releases/download/${NATS_VERSION}/${NATS_TARBALL}"
curl -fsSL "$NATS_URL" -o "$WORK_DIR/$NATS_TARBALL"
sha256_verify "$WORK_DIR/$NATS_TARBALL" "$NATS_SHA256"
tar -xzf "$WORK_DIR/$NATS_TARBALL" -C "$WORK_DIR"
cp "$WORK_DIR/nats-server-${NATS_VERSION}-linux-arm64/nats-server" "$BIN_DIR/nats-server-arm64"

chmod +x "$BIN_DIR/bosh-agent-arm64" "$BIN_DIR/bosh-blobstore-dav" "$BIN_DIR/nats-server-arm64"

echo "Done. Binaries in $BIN_DIR:"
ls -lh "$BIN_DIR"
