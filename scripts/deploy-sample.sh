#!/bin/bash
set -e

# deploy-sample.sh - Deploys a sample ARM64 app via BOSH on Apple Silicon
# Prerequisites: Director container must be running (see README.md)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIRECTOR_URL="http://127.0.0.1:25555"

# --- Browser access (optional) --------------------------------------------
# After a successful deploy, the app runs on port 8080 inside the BOSH-created
# VM container, which is on the internal "bosh-default" Docker network and is
# NOT reachable from the host browser. To make it browsable, this script can
# start a tiny socat forwarder container that publishes a host port and pipes
# it to the VM's IP:8080. Configure via environment variables:
#   BROWSER_FORWARD=0   -> skip starting the forwarder (default: 1 = start it)
#   APP_PORT=8080       -> host port to publish (default: 8080)
BROWSER_FORWARD="${BROWSER_FORWARD:-1}"
APP_PORT="${APP_PORT:-8080}"
FWD_CONTAINER="sample-app-fwd"
FWD_NETWORK="bosh-default"
# Pinned by digest. This is the only image pulled from a registry at deploy time
# (everything else is built locally from digest-pinned bases), so leaving it on a
# floating tag would be the one unpinned input to an otherwise reproducible run.
FWD_IMAGE="alpine/socat@sha256:c5a091e1e735a90aa941a5828529dbe6c6157407a8047a9aa473faa133361b82"

# Read the Director admin credentials generated at container startup. They are
# persisted inside the container at /var/vcap/bosh/etc/director-creds.env and
# are not a fixed/known value, so we fetch them at runtime rather than hardcode.
CREDS_FILE="/var/vcap/bosh/etc/director-creds.env"

echo "ARM64 BOSH-lite - Sample App Deployment"
echo ""

# Check Director is running
if ! docker ps --format '{{.Names}}' | grep -q bosh-director; then
    echo "Error: Director container not running. Start it first:"
    echo "   docker run -d --name bosh-director --privileged \\"
    echo "     -v /var/run/docker.sock:/var/run/docker.sock \\"
    echo "     --network bosh-default \\"
    echo "     -p 127.0.0.1:25555:25555 -p 127.0.0.1:25250:25250 \\"
    echo "     bosh-director-arm64:latest"
    exit 1
fi

# Fetch generated Director credentials from inside the container
echo "Reading Director credentials from container..."
AUTH=""
for i in $(seq 1 30); do
    if docker exec bosh-director test -f "$CREDS_FILE" 2>/dev/null; then
        ADMIN_USER=$(docker exec bosh-director sh -c ". $CREDS_FILE && printf %s \"\$BOSH_ADMIN_USER\"")
        ADMIN_PASS=$(docker exec bosh-director sh -c ". $CREDS_FILE && printf %s \"\$BOSH_ADMIN_PASSWORD\"")
        if [ -n "$ADMIN_USER" ] && [ -n "$ADMIN_PASS" ]; then
            AUTH="${ADMIN_USER}:${ADMIN_PASS}"
            break
        fi
    fi
    sleep 2
done
if [ -z "$AUTH" ]; then
    echo "Error: Could not read Director credentials from $CREDS_FILE"
    echo "   Check: docker logs bosh-director"
    exit 1
fi
echo "Credentials loaded"

# Wait for Director API
echo "Waiting for Director API..."
for i in $(seq 1 30); do
    if docker exec bosh-director curl -sf -u "$AUTH" "$DIRECTOR_URL/info" >/dev/null 2>&1; then
        echo "Director ready"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "Error: Director not ready after 60s. Check: docker logs bosh-director"
        exit 1
    fi
    sleep 2
done

# Build stemcell tarball if not present
STEMCELL="$REPO_ROOT/bosh-stemcell-1.0-warden-boshlite-ubuntu-noble-arm64.tgz"
if [ ! -f "$STEMCELL" ]; then
    echo ""
    echo "Building stemcell tarball..."
    bash "$SCRIPT_DIR/build-warden-stemcell.sh"
fi

# Build compiled release (always rebuild to pick up binary changes)
RELEASE="$REPO_ROOT/sample-app-release-2.tgz"
echo ""
echo "Building sample release..."
bash "$SCRIPT_DIR/build-compiled-release.sh"

# Clean up any existing deployment and release (allows re-running the script)
echo ""
echo "Cleaning up previous deployment (if any)..."
EXISTING_DEPLOY=$(docker exec bosh-director curl -s -u "$AUTH" "$DIRECTOR_URL/deployments" | jq -r '.[].name' 2>/dev/null)
# grep -qx, not a string comparison: with more than one deployment on the Director
# this value is multi-line, and `[ "$EXISTING_DEPLOY" = "sample-app" ]` would then
# be false and skip the cleanup entirely.
if echo "$EXISTING_DEPLOY" | grep -qx "sample-app"; then
    TASK_URL=$(docker exec bosh-director curl -s -o /dev/null -w "%{redirect_url}" \
        -X DELETE -u "$AUTH" "$DIRECTOR_URL/deployments/sample-app?force=true")
    TASK_ID=$(echo "$TASK_URL" | grep -o '[0-9]*$')
    if [ -n "$TASK_ID" ]; then
        for i in $(seq 1 90); do
            STATE=$(docker exec bosh-director curl -s -u "$AUTH" "$DIRECTOR_URL/tasks/$TASK_ID" | jq -r .state)
            [ "$STATE" = "done" ] || [ "$STATE" = "error" ] && break
            sleep 3
        done
        echo "   Deleted existing deployment"
    fi
fi
# Delete existing release
docker exec bosh-director curl -s -o /dev/null -X DELETE -u "$AUTH" \
    "$DIRECTOR_URL/releases/sample-app-release?force=true" 2>/dev/null
sleep 2

# Delete the existing stemcell too.
#
# BOSH keys stemcells by name+version, so re-uploading "1.0-arm64" over one that
# already exists is a silent no-op: the upload task reports success, but the
# Director keeps serving the Docker image it imported the first time. A rebuilt
# stemcell therefore never reaches a VM, and the deploy "succeeds" while testing
# the old artifact — the failure mode gives you no signal at all. Deleting first
# forces a real re-import on every run.
#
# Must match the `stemcells:` block of the deployment manifest below.
STEMCELL_NAME="bosh-warden-boshlite-ubuntu-noble-go_agent"
STEMCELL_VERSION="1.0-arm64"
TASK_URL=$(docker exec bosh-director curl -s -o /dev/null -w "%{redirect_url}" \
    -X DELETE -u "$AUTH" "$DIRECTOR_URL/stemcells/$STEMCELL_NAME/$STEMCELL_VERSION?force=true")
TASK_ID=$(echo "$TASK_URL" | grep -o '[0-9]*$')
# The Director returns a delete task even when no such stemcell exists (it
# completes as a no-op), so this runs on a first deploy too.
if [ -n "$TASK_ID" ]; then
    for i in $(seq 1 60); do
        STATE=$(docker exec bosh-director curl -s -u "$AUTH" "$DIRECTOR_URL/tasks/$TASK_ID" | jq -r .state)
        if [ "$STATE" = "done" ]; then
            echo "   Stemcell cleared (forces a real re-import below)"
            break
        fi
        # Don't fail the run, but say so loudly: if the delete failed while a
        # stemcell is still registered, the upload below silently becomes a no-op
        # and the deploy would test the previously imported image instead.
        if [ "$STATE" = "error" ]; then
            echo "   Warning: stemcell delete failed - a rebuilt stemcell may be ignored."
            docker exec bosh-director curl -s -u "$AUTH" "$DIRECTOR_URL/tasks/$TASK_ID" | jq -r .result
            break
        fi
        if [ "$i" -eq 60 ]; then
            echo "  Error: stemcell delete did not finish after 120s (last state: ${STATE:-unknown})"
            echo "  Check: docker logs bosh-director"
            exit 1
        fi
        sleep 2
    done
fi
# Clean up old VM containers. Scoped to the bosh-default network so this only
# removes containers this Director created, not every host container whose name
# happens to start with "c-".
docker ps -a --filter "network=$FWD_NETWORK" --format '{{.Names}}' |
    grep "^c-" | xargs -r docker rm -f 2>/dev/null || true

# Copy files to Director
echo ""
echo "Uploading stemcell..."
docker cp "$STEMCELL" bosh-director:/tmp/stemcell.tgz
TASK_URL=$(docker exec bosh-director curl -s -o /dev/null -w "%{redirect_url}" \
    -X POST -u "$AUTH" -H "Content-Type: multipart/form-data" \
    -F "nginx_upload_path=/tmp/stemcell.tgz" "$DIRECTOR_URL/stemcells")
TASK_ID=$(echo "$TASK_URL" | grep -o '[0-9]*$')
echo "   Task: $TASK_ID"
for i in $(seq 1 120); do
    STATE=$(docker exec bosh-director curl -s -u "$AUTH" "$DIRECTOR_URL/tasks/$TASK_ID" | jq -r .state)
    if [ "$STATE" = "done" ]; then
        echo "  Stemcell uploaded"
        break
    fi
    if [ "$STATE" = "error" ]; then
        echo "  Error: stemcell upload failed"
        docker exec bosh-director curl -s -u "$AUTH" "$DIRECTOR_URL/tasks/$TASK_ID" | jq -r .result
        exit 1
    fi
    if [ "$i" -eq 120 ]; then
        echo "  Error: stemcell upload did not finish after 240s (last state: ${STATE:-unknown})"
        echo "  Check: docker logs bosh-director"
        exit 1
    fi
    sleep 2
done

echo ""
echo "Uploading release..."
docker cp "$RELEASE" bosh-director:/tmp/release.tgz
TASK_URL=$(docker exec bosh-director curl -s -o /dev/null -w "%{redirect_url}" \
    -X POST -u "$AUTH" -H "Content-Type: multipart/form-data" \
    -F "nginx_upload_path=/tmp/release.tgz" "$DIRECTOR_URL/releases")
TASK_ID=$(echo "$TASK_URL" | grep -o '[0-9]*$')
echo "   Task: $TASK_ID"
for i in $(seq 1 60); do
    STATE=$(docker exec bosh-director curl -s -u "$AUTH" "$DIRECTOR_URL/tasks/$TASK_ID" | jq -r .state)
    if [ "$STATE" = "done" ]; then
        echo "  Release uploaded"
        break
    fi
    if [ "$STATE" = "error" ]; then
        echo "  Error: release upload failed"
        docker exec bosh-director curl -s -u "$AUTH" "$DIRECTOR_URL/tasks/$TASK_ID" | jq -r .result
        exit 1
    fi
    if [ "$i" -eq 60 ]; then
        echo "  Error: release upload did not finish after 120s (last state: ${STATE:-unknown})"
        echo "  Check: docker logs bosh-director"
        exit 1
    fi
    sleep 2
done

echo ""
echo "Setting cloud config..."
docker exec bosh-director curl -s -X POST -u "$AUTH" \
    -H "Content-Type: application/json" \
    -d '{"type":"cloud","name":"default","content":"---\nazs:\n- name: z1\n  cloud_properties: {}\nvm_types:\n- name: default\n  cloud_properties: {}\ndisk_types:\n- name: default\n  disk_size: 1024\n  cloud_properties: {}\nnetworks:\n- name: default\n  type: dynamic\n  subnets:\n  - az: z1\n    cloud_properties:\n      name: bosh-default\ncompilation:\n  workers: 1\n  az: z1\n  reuse_compilation_vms: true\n  vm_type: default\n  network: default\n"}' \
    "$DIRECTOR_URL/configs" >/dev/null
echo "  Cloud config applied"

echo ""
echo "Deploying sample-app..."
docker exec bosh-director bash -c 'cat > /tmp/deployment.yml << MANIFEST
---
name: sample-app
releases:
- name: sample-app-release
  version: "2"
stemcells:
- alias: default
  os: ubuntu-noble
  version: "1.0-arm64"
update:
  canaries: 1
  max_in_flight: 1
  canary_watch_time: 1000-180000
  update_watch_time: 1000-180000
instance_groups:
- name: sample-app
  instances: 1
  azs: [z1]
  stemcell: default
  vm_type: default
  networks:
  - name: default
  jobs:
  - name: sample-app
    release: sample-app-release
    properties:
      port: 8080
MANIFEST'

TASK_URL=$(docker exec bosh-director curl -s -o /dev/null -w "%{redirect_url}" \
    -X POST -u "$AUTH" -H "Content-Type: text/yaml" \
    --data-binary @/tmp/deployment.yml "$DIRECTOR_URL/deployments")
TASK_ID=$(echo "$TASK_URL" | grep -o '[0-9]*$')
# 5-10 minutes, not 3-5: a measured run on an M-series Mac took ~7 minutes from
# here to "Deployment complete". Understating it invites killing a healthy deploy.
echo "   Task: $TASK_ID (this takes 5-10 minutes...)"

for i in $(seq 1 360); do
    STATE=$(docker exec bosh-director curl -s -u "$AUTH" "$DIRECTOR_URL/tasks/$TASK_ID" | jq -r .state)
    if [ "$STATE" = "done" ]; then
        echo "  Deployment complete"
        break
    fi
    if [ "$STATE" = "error" ]; then
        echo "  Error: deployment failed"
        docker exec bosh-director curl -s -u "$AUTH" "$DIRECTOR_URL/tasks/$TASK_ID" | jq -r .result
        exit 1
    fi
    if [ "$i" -eq 360 ]; then
        echo "  Error: deployment did not finish after 1800s (last state: ${STATE:-unknown})"
        echo "  Check: docker exec bosh-director curl -s -u \"\$AUTH\" $DIRECTOR_URL/tasks/$TASK_ID/output?type=debug"
        exit 1
    fi
    if [ $((i % 30)) -eq 0 ]; then echo "  Still deploying... ($((i * 5))s)"; fi
    sleep 5
done

# Verify the app is running
echo ""
echo "Verifying sample app..."
sleep 15 # Give monit time to pick up config and start the job
VM=$(docker ps --filter "network=$FWD_NETWORK" --format '{{.Names}}' | grep "^c-" | head -1)
if [ -z "$VM" ]; then
    echo "  Error: no VM container found"
    exit 1
fi

# Reload monit to pick up job config and start app
docker exec "$VM" bash -c '
monit -c /etc/monitrc reload 2>/dev/null
sleep 15
monit -c /etc/monitrc start all 2>/dev/null
' 2>/dev/null

# Wait for app to start (retry for up to 60 seconds).
#
# Timing-sensitive: exceeding this window is only a soft failure (the warning at
# the bottom of this script), so a deploy that actually succeeded can be reported
# as "not responding yet". 60s rather than 30s to keep that from happening on a
# loaded machine.
RESPONSE=""
for i in $(seq 1 12); do
    RESPONSE=$(docker exec "$VM" curl -s http://127.0.0.1:8080/ 2>/dev/null)
    if echo "$RESPONSE" | jq -e .arch >/dev/null 2>&1; then
        break
    fi
    sleep 5
done

if echo "$RESPONSE" | jq -e .arch >/dev/null 2>&1; then
    echo ""
    echo "SUCCESS: app running on ARM64"
    echo ""
    echo "$RESPONSE" | jq .
    echo ""
    echo "VM Container: $VM"
    echo "App endpoint: docker exec $VM curl -s http://127.0.0.1:8080/"

    # --- Optional: expose the app to the host browser ---------------------
    # The VM container has no published ports (Docker CPI creates it without
    # any), so http://localhost is not wired to it by default. Start a socat
    # forwarder on the same network that maps host APP_PORT -> VM_IP:8080.
    if [ "$BROWSER_FORWARD" = "1" ]; then
        echo ""
        echo "Setting up browser access..."
        # Resolve the VM's IP on the bosh-default network at runtime, so this
        # works no matter what IP the freshly-created VM was assigned.
        VM_IP=$(docker inspect "$VM" \
            --format "{{with index .NetworkSettings.Networks \"$FWD_NETWORK\"}}{{.IPAddress}}{{end}}" 2>/dev/null)
        if [ -z "$VM_IP" ]; then
            # Fallback: first IP on any network
            VM_IP=$(docker inspect "$VM" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)
        fi
        if [ -z "$VM_IP" ]; then
            echo "   Warning: could not determine VM IP; skipping browser forwarder."
            echo "   Access the app inside the VM instead:"
            echo "     docker exec $VM curl -s http://127.0.0.1:8080/"
        else
            # Recreate the forwarder each run so a redeploy re-points to the new VM.
            docker rm -f "$FWD_CONTAINER" >/dev/null 2>&1 || true
            # Bound to 127.0.0.1 so the app is reachable from this machine's
            # browser but not published to the LAN.
            if docker run -d --name "$FWD_CONTAINER" --network "$FWD_NETWORK" \
                -p "127.0.0.1:${APP_PORT}:8080" "$FWD_IMAGE" \
                "tcp-listen:8080,fork,reuseaddr" "tcp-connect:${VM_IP}:8080" >/dev/null 2>&1; then
                # Wait briefly for the forwarder to accept connections
                FWD_OK=""
                for i in $(seq 1 10); do
                    if curl -s --max-time 3 "http://localhost:${APP_PORT}/" 2>/dev/null | jq -e .arch >/dev/null 2>&1; then
                        FWD_OK=1
                        break
                    fi
                    sleep 1
                done
                if [ -n "$FWD_OK" ]; then
                    echo "   Forwarder running (container: $FWD_CONTAINER)"
                    echo ""
                    echo "   Open in your browser:  http://localhost:${APP_PORT}/"
                    echo "      Health check:          http://localhost:${APP_PORT}/health"
                    echo ""
                    echo "   Stop the forwarder when done:  docker rm -f $FWD_CONTAINER"
                else
                    echo "   Warning: forwarder started but the app is not answering on host port ${APP_PORT} yet."
                    echo "      It may just need another moment. Try:  curl -s http://localhost:${APP_PORT}/ | jq ."
                    echo "      (Is host port ${APP_PORT} already in use? Re-run with APP_PORT=<free port>.)"
                fi
            else
                echo "   Warning: could not start forwarder (host port ${APP_PORT} may be in use)."
                echo "      Re-run with a different port, e.g.:  APP_PORT=8090 ./deploy-sample.sh"
                echo "      Or reach the app inside the VM:  docker exec $VM curl -s http://127.0.0.1:8080/"
            fi
        fi
    else
        echo ""
        echo "Browser forwarding disabled (BROWSER_FORWARD=0)."
        echo "   To expose the app to your browser, run:"
        echo "     docker run -d --name $FWD_CONTAINER --network $FWD_NETWORK -p 127.0.0.1:${APP_PORT}:8080 \\"
        echo "       $FWD_IMAGE tcp-listen:8080,fork,reuseaddr tcp-connect:<VM_IP>:8080"
        echo "   (VM_IP for the current deploy: use 'docker inspect $VM')"
    fi

    echo ""
    echo "To access Director API (credentials generated at startup). The Director"
    echo "binds 127.0.0.1:25555 inside the container, so query it from in there:"
    echo "  docker exec bosh-director sh -c '. $CREDS_FILE &&"
    echo "    curl -s -u \"\$BOSH_ADMIN_USER:\$BOSH_ADMIN_PASSWORD\" http://127.0.0.1:25555/deployments' | jq ."
else
    echo "   Warning: app not responding yet. Check manually:"
    echo "   docker exec $VM monit -c /etc/monitrc summary"
    echo "   docker exec $VM cat /var/vcap/sys/log/sample-app/sample-app.stderr.log"
fi
