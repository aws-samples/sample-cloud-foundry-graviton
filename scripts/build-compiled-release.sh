#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RELEASE_DIR=$(mktemp -d)
WORK_DIR=$(mktemp -d)

echo "Building pre-compiled BOSH release tarball..."

# Ensure the sample-app arm64 binary exists; build it from source if missing.
if [ ! -f "$REPO_ROOT/sample-release/src/sample-app/app" ]; then
    echo "sample-app binary not found — building from source..."
    bash "$SCRIPT_DIR/build-sample-app.sh"
fi

# Create compiled package tarball (already-compiled binary, no compilation needed)
mkdir -p "$RELEASE_DIR/compiled_packages"
mkdir -p "$WORK_DIR/pkg"
cp "$REPO_ROOT/sample-release/src/sample-app/app" "$WORK_DIR/pkg/app"
chmod +x "$WORK_DIR/pkg/app"
cd "$WORK_DIR/pkg"
tar czf "$RELEASE_DIR/compiled_packages/sample-app.tgz" .
PKG_SHA=$(shasum "$RELEASE_DIR/compiled_packages/sample-app.tgz" | awk '{print $1}')
PKG_FINGERPRINT=$(shasum -a 256 "$RELEASE_DIR/compiled_packages/sample-app.tgz" | awk '{print $1}' | head -c 40)
echo "Compiled package SHA: $PKG_SHA"

# Create job tarball with job.MF
mkdir -p "$WORK_DIR/sample-app"
cat >"$WORK_DIR/sample-app/job.MF" <<'JOBMF'
---
name: sample-app
templates:
  ctl.sh: bin/ctl
packages:
- sample-app
properties:
  port:
    description: "Port for the sample app to listen on"
    default: 8080
JOBMF

cp "$REPO_ROOT/sample-release/jobs/sample-app/monit" "$WORK_DIR/sample-app/monit"
cp -r "$REPO_ROOT/sample-release/jobs/sample-app/templates" "$WORK_DIR/sample-app/templates/"

mkdir -p "$RELEASE_DIR/jobs"
cd "$WORK_DIR/sample-app"
tar czf "$RELEASE_DIR/jobs/sample-app.tgz" job.MF monit templates/

JOB_SHA=$(shasum "$RELEASE_DIR/jobs/sample-app.tgz" | awk '{print $1}')
JOB_FINGERPRINT=$(shasum -a 256 "$RELEASE_DIR/jobs/sample-app.tgz" | awk '{print $1}' | head -c 40)
echo "Job SHA: $JOB_SHA"

# Create release manifest (compiled release format)
cat >"$RELEASE_DIR/release.MF" <<EOF
name: sample-app-release
version: "2"
commit_hash: arm64poc
uncommitted_changes: false
jobs:
- name: sample-app
  version: ${JOB_FINGERPRINT}
  fingerprint: ${JOB_FINGERPRINT}
  sha1: ${JOB_SHA}
compiled_packages:
- name: sample-app
  version: ${PKG_FINGERPRINT}
  fingerprint: ${PKG_FINGERPRINT}
  sha1: ${PKG_SHA}
  stemcell: ubuntu-noble/1.0-arm64
  dependencies: []
EOF

# Create final release tarball
cd "$RELEASE_DIR"
tar czf "$REPO_ROOT/sample-app-release-2.tgz" release.MF compiled_packages/ jobs/

echo ""
echo "Compiled release created:"
ls -lh "$REPO_ROOT/sample-app-release-2.tgz"
echo ""
echo "Manifest:"
cat "$RELEASE_DIR/release.MF"

rm -rf "$RELEASE_DIR" "$WORK_DIR"
