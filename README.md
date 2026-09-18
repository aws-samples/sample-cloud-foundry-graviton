# ARM64 BOSH-lite on Apple Silicon

Run a BOSH Director natively on Apple Silicon (M1/M2/M3/M4) that deploys ARM64 workloads via Docker — no Rosetta emulation.

## What this is and why it exists

This repository is a self-contained proof of concept that the **BOSH toolchain
can build, deploy, and run entirely on ARM64** — both Apple Silicon Macs and AWS
Graviton — with no x86 emulation anywhere in the path. It runs a real BOSH
Director (built from source) that uses the Docker CPI to create ARM64 containers
as "VMs," then deploys a sample workload onto them end to end.

**The proof point:** after following the Quick Start, a sample app is deployed
through the full BOSH lifecycle (stemcell → release → compile → install → start)
and reports back `"arch": "arm64"`, `"os": "linux"` — demonstrating a native
ARM64 deploy with no Rosetta translation. It accompanies the upstream RFC
proposing first-class ARM64 support for Cloud Foundry.

This is **BOSH-lite, not full Cloud Foundry** — there is no `cf push`; workloads
are delivered as BOSH releases. It is a local, developer-facing demonstration
tool, not a production deployment method.

### How this relates to Cloud Foundry

Cloud Foundry runs on top of **BOSH** — BOSH is the release-engineering and
deployment layer beneath the Cloud Foundry platform. This sample proves that
foundational BOSH layer (Director, Docker CPI, stemcells, and agent) builds and
runs natively on ARM64. It is **not** the full Cloud Foundry Application Runtime
— there is no `cf push`, Cloud Controller, Diego, or gorouter — it deploys BOSH
releases directly. Getting BOSH working on ARM64 is the prerequisite step toward
running the full Cloud Foundry platform on AWS Graviton, which the upstream
[RFC](https://github.com/cloudfoundry/community/pull/1530) tracks.

> **This is sample code, for non-production usage.** You should work with your
> security and legal teams to meet your organizational security, regulatory, and
> compliance requirements before deployment. It intentionally uses several
> development-only workarounds (see [Dev Workarounds](#dev-workarounds-not-production))
> that are not suitable for production.

## Prerequisites

- **macOS** on Apple Silicon (M-series chip)
- **Docker Desktop** (4.x+ with ARM64 container support)
- **~4GB free disk** for images
- **jq** installed (`brew install jq`)
- **Go** installed (`brew install go`) — used by `scripts/build-binaries.sh` to
  compile the ARM64 prerequisite binaries

## Quick Start

```bash
# 1. Fetch/compile the ARM64 prerequisite binaries into bin/ (git-ignored)
./scripts/build-binaries.sh

# 2. Build images (first time only — ~5 min)
docker build --platform linux/arm64 -t bosh-stemcell-arm64:latest -f Dockerfile.stemcell .
docker build --platform linux/arm64 -t bosh-director-arm64:latest -f Dockerfile.director .

# 3. Start Director
# Ports are bound to 127.0.0.1: the Director API and the blobstore use HTTP
# basic auth over plaintext, so a bare "-p 25555:25555" would publish them on
# every host interface and leak those credentials to the local network.
docker network create bosh-default 2>/dev/null || true
docker run -d --name bosh-director --privileged \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --network bosh-default \
  -p 127.0.0.1:25555:25555 -p 127.0.0.1:25250:25250 \
  bosh-director-arm64:latest

# 4. Deploy sample app (wait ~25s for Director to start)
sleep 25
./scripts/deploy-sample.sh
```

After ~5–10 minutes (a measured run on an M-series Mac took ~7), you'll see:

```json
{
  "app": "bosh-deployed-arm64-app",
  "arch": "arm64",
  "message": "Hello from Cloud Foundry on ARM64!",
  "os": "linux"
}
```

On success the script also starts a small forwarder container so you can open
the app in your browser:

```
Open in your browser:  http://localhost:8080/
Health check:          http://localhost:8080/health
```

The deployed app runs on port 8080 **inside** the BOSH-created VM container,
which sits on an internal Docker network with no published ports. To make it
reachable from the host, `deploy-sample.sh` starts a tiny `socat` forwarder
container (`sample-app-fwd`) that maps a host port to the VM. Options:

| Env var | Default | Purpose |
|---|---|---|
| `BROWSER_FORWARD` | `1` | Set to `0` to skip the forwarder (e.g. headless/CI). |
| `APP_PORT` | `8080` | Host port to publish. Use another port if 8080 is taken: `APP_PORT=8090 ./scripts/deploy-sample.sh`. |

Stop the forwarder when you're done: `docker rm -f sample-app-fwd`.

## What This Demonstrates

- BOSH Director running natively on ARM64
- Docker CPI creating ARM64 containers as "VMs"
- BOSH Agent managing processes inside VMs via monit
- Full deployment lifecycle: stemcell → release → compile → install → start
- Application running on ARM64 Linux — no emulation

## Architecture

```
Docker Desktop (Apple Silicon — native ARM64)
├── bosh-director container
│   ├── BOSH Director API (Ruby, port 25555)
│   ├── Docker CPI (Go, patched for ARM64)
│   ├── NATS message bus (port 4222)
│   ├── PostgreSQL (deployment state)
│   └── nginx DAV blobstore (port 25250)
└── c-<uuid> container (created by Director)
    ├── systemd (init)
    ├── BOSH Agent (connects to NATS)
    ├── monit (process supervisor)
    └── sample-app (HTTP server on port 8080)
```

## Useful Commands

> **Credentials:** The Director admin password and blobstore password are
> randomly generated the first time the container starts (no fixed default).
> They are stored only inside the container and are **not** printed to
> `docker logs`. Retrieve them by reading the creds file directly, which
> requires active container access:
>
> ```bash
> # Load generated credentials into your shell
> eval "$(docker exec bosh-director cat /var/vcap/bosh/etc/director-creds.env)"
> echo "user=$BOSH_ADMIN_USER password=$BOSH_ADMIN_PASSWORD"
> ```
>
> You can also pin them to known values by passing `-e BOSH_ADMIN_PASSWORD=...`
> and `-e BOSH_BLOBSTORE_PASSWORD=...` to `docker run`.

> **Why the Director API calls go through `docker exec`:** the Director's Puma
> server binds to `127.0.0.1:25555` *inside* the container, so it is not
> reachable from the host even with the port published — run the API calls in
> the container, as `deploy-sample.sh` does. The blobstore on 25250 *does* listen
> on all interfaces inside the container, which is why the `docker run` above
> publishes it on `127.0.0.1` only.

```bash
# Director status
docker exec bosh-director sh -c '. /var/vcap/bosh/etc/director-creds.env &&
  curl -s -u "$BOSH_ADMIN_USER:$BOSH_ADMIN_PASSWORD" http://127.0.0.1:25555/info' | jq .

# List deployments
docker exec bosh-director sh -c '. /var/vcap/bosh/etc/director-creds.env &&
  curl -s -u "$BOSH_ADMIN_USER:$BOSH_ADMIN_PASSWORD" http://127.0.0.1:25555/deployments' | jq .

# Check VM container (filtered to this Director's network, so an unrelated
# container named "c-something" on your machine is not picked up)
VM=$(docker ps --filter network=bosh-default --format '{{.Names}}' | grep "^c-")
docker exec $VM curl -s http://127.0.0.1:8080/ | jq .

# Reach the app from the host browser (deploy-sample.sh sets this up for you)
curl -s http://localhost:8080/ | jq .

# Monit status inside VM
docker exec $VM monit -c /etc/monitrc summary

# Director logs
docker logs bosh-director --tail 20

# Cleanup (the c- filter is scoped to bosh-default so this cannot force-remove
# unrelated containers on your machine)
docker rm -f sample-app-fwd 2>/dev/null || true
docker ps -a --filter network=bosh-default --format '{{.Names}}' | grep "^c-" | xargs -r docker rm -f
docker stop bosh-director && docker rm bosh-director
docker network rm bosh-default
```

## Troubleshooting

### `Timed out pinging VM '<c-uuid>' with agent '<uuid>' after 600 seconds`

The Director created the VM container, but its BOSH agent never answered on the
NATS mbus. The deploy runs for ~10 minutes before failing, and the error names
NATS rather than the actual cause. Check, in order:

**1. Is the agent connected to NATS but not subscribed?** This is the single most
useful diagnostic in this repo:

```bash
docker exec bosh-director curl -s http://127.0.0.1:8222/connz | jq '.connections[]
  | {ip, subscriptions, in_msgs, uptime}'
```

A healthy agent shows `subscriptions: 1` and a rising `in_msgs`. If instead you see
a **new connection every ~10 seconds with `subscriptions: 0, in_msgs: 0`**, the
agent is reaching NATS and then crash-looping before it subscribes (systemd
restarts it). That is an agent problem, not a network problem — go to step 2.

**2. Is the agent binary actually patched?** An unpatched `bin/bosh-agent-arm64`
is the most common cause. `bin/` is git-ignored, so a working tree can carry a
stale agent from an earlier checkout with nothing to indicate it:

```bash
grep -aq BOSH_AGENT_DEV_INSECURE_NATS bin/bosh-agent-arm64 && echo patched || echo UNPATCHED
./scripts/build-binaries.sh   # rebuild if unpatched
```

`scripts/build-warden-stemcell.sh` now refuses to build a stemcell from an
unpatched agent, so this should fail loudly at build time rather than at deploy
time — but check it explicitly if you are debugging an older stemcell.

**3. Is the VM running the stemcell you think it is?**

```bash
VM=$(docker ps --filter network=bosh-default --format '{{.Names}}' | grep "^c-")
docker inspect $VM --format '{{.Config.Image}}'   # the imported stemcell image
```

BOSH keys stemcells by name+version, so uploading `1.0-arm64` when that version
already exists is a **silent no-op** — the task reports success while the Director
keeps serving the image it imported the first time. `deploy-sample.sh` deletes the
stemcell before uploading to force a real re-import; if you upload by hand, delete
it first or your rebuilt stemcell will be ignored.

### Reading BOSH agent logs

**`journalctl -u bosh-agent` does not work** in these VM containers — it returns
"No journal files were found." To see what the agent is doing, run it in the
foreground, and **export the PATH from its systemd unit first**:

```bash
docker exec $VM bash -c '
  systemctl stop bosh-agent
  export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/var/vcap/bosh/bin
  export BOSH_AGENT_DEV_INSECURE_NATS=1
  timeout 25 /var/vcap/bosh/bin/bosh-agent -P ubuntu -C /var/vcap/bosh/etc/agent.json 2>&1 | tail -40
  systemctl start bosh-agent'
```

Skipping the `export PATH` produces a **misleading** error:

```
ERROR - App setup Getting blobstore: Validating blobstore: executable bosh-blobstore-dav not found in PATH
```

The binary is present at `/var/vcap/bosh/bin/bosh-blobstore-dav`; it is only
missing from the default `docker exec` PATH. The systemd unit sets the PATH
correctly, so this error is an artifact of how you invoked the agent, not a real
fault. Don't chase it.

### The deploy is taking longer than the README says

Expect **5–10 minutes** from "Deploying sample-app..." to "Deployment complete".
`deploy-sample.sh` bounds every wait and prints the exact command to inspect the
task, so a genuine hang reports itself:

```bash
docker exec bosh-director sh -c '. /var/vcap/bosh/etc/director-creds.env &&
  curl -s -u "$BOSH_ADMIN_USER:$BOSH_ADMIN_PASSWORD" \
  "http://127.0.0.1:25555/tasks/<TASK_ID>/output?type=debug"' | tail -40
```

### `app not responding yet` after a successful deploy

The deploy finished but the app didn't answer within 60s of `monit` starting it.
The deployment itself is fine; check the job:

```bash
docker exec $VM monit -c /etc/monitrc summary
docker exec $VM cat /var/vcap/sys/log/sample-app/sample-app.stderr.log
```

## Dev Workarounds (Not Production)

This setup uses several development workarounds to run without `bosh create-env`:

| Workaround | Why | Production Fix |
|---|---|---|
| NATS TLS disabled (agent side) | Agent patched to connect to NATS without mutual TLS, matching the Director's plaintext dev NATS | `bosh create-env` auto-generates and enforces NATS mutual TLS |
| Monit reload / systemd supervision patched | `monit reload` + `systemctl restart` are more reliable than kill+start in Docker/systemd | Works correctly with runit in production stemcells |
| Monit 5.25.3 with CSRF disabled | Ubuntu Noble ships monit 5.33 (CSRF breaks BOSH agent) | `bosh-linux-stemcell-builder` compiles its own monit |
| `resolvconf` stub | Package removed in Ubuntu 24.04 | Production stemcells include proper resolver |
| Pre-compiled release | Docker volume issue with standard compilation | Works correctly with real VM disks |
| `verify-multidigest` stubbed to `exit 0` | The real binary ships in the `bosh-utils` release, which isn't built here; the Director requires the path to exist | Production BOSH installs the real binary, so stemcell/release/blob digests are actually verified |
| Director API + blobstore over plaintext HTTP | No TLS is provisioned for the Director's own listeners in this dev setup, so basic-auth credentials are sent in the clear | `bosh create-env` issues Director TLS certs; clients talk HTTPS |
| NATS bus with no TLS and no authentication | Matches the agent-side patch above; the bus is reachable only from the internal `bosh-default` Docker network | `bosh create-env` enforces NATS mutual TLS |

The first two rows are implemented as a source patch applied to the BOSH agent
at build time: [`scripts/patches/bosh-agent-dev-workarounds.patch`](scripts/patches/bosh-agent-dev-workarounds.patch),
applied by `scripts/build-binaries.sh` against the pinned `v2.824.0` tag. The
patch makes the insecure NATS path **opt-in**: the agent only skips NATS TLS when
the environment variable `BOSH_AGENT_DEV_INSECURE_NATS=1` is set (the stemcell's
agent service sets it); otherwise the agent keeps upstream mutual TLS. The patch
also adapts monit/systemd supervision for the containerized Docker-CPI stemcell.
Without it (or without the env var), the agent tries mutual-TLS to the plaintext
dev NATS, never subscribes to its mbus, and deploys fail with "Timed out pinging VM".

These workarounds are acceptable for a development/POC tool. In production, `bosh create-env` on real infrastructure handles all of this automatically.

## Building from Source

### Prerequisite binaries

```bash
# Fetches nats-server and cross-compiles bosh-agent + davcli into bin/ (git-ignored)
./scripts/build-binaries.sh
```

The pinned upstream versions live at the top of `scripts/build-binaries.sh`
(`BOSH_AGENT_REF`, `DAVCLI_REF`, `NATS_VERSION`); bump them there deliberately.

### Stemcell

```bash
# Builds monit 5.25.3 from source (~2 min)
docker build --platform linux/arm64 -t bosh-stemcell-arm64:latest -f Dockerfile.stemcell .

# Package into BOSH stemcell tarball
./scripts/build-warden-stemcell.sh
```

### Director

```bash
# Builds Ruby 3.4, BOSH Director gems, Docker CPI (~5 min first time)
docker build --platform linux/arm64 -t bosh-director-arm64:latest -f Dockerfile.director .
```

### Sample Release

```bash
# Pre-compiled release (skips compilation step)
./scripts/build-compiled-release.sh
```

## Deploy Your Own App

This is **BOSH-lite**, not full Cloud Foundry — there is no `cf push`. To run a
different workload you package it as a **BOSH release** and deploy it the same
way the sample is deployed. The easiest path is to copy `sample-release/` and
swap in your own binary.

> Your workload must be a **statically linked `linux/arm64`** binary — the
> stemcell and Director are ARM64. For Go:
> `GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o app ./...`

**1. Mirror the release layout** (replace `myapp` with your app's name):

```
myapp-release/
├── packages/myapp/
│   ├── spec           # files: [ myapp/app ]
│   └── packaging      # cp myapp/app $BOSH_INSTALL_TARGET/app && chmod +x
├── jobs/myapp/
│   ├── spec           # packages: [myapp]; properties (e.g. port)
│   ├── monit          # check process myapp ... bin/ctl start|stop
│   └── templates/
│       └── ctl.sh     # start command; reads props via <%= p('port') %>
└── src/myapp/app      # your compiled arm64 binary
```

The four small files (`spec`, `packaging`, `monit`, `ctl.sh`) can be copied
almost verbatim from `sample-release/` — rename `sample-app` to `myapp` and set
the start command / env vars in `ctl.sh` to what your app needs.

**2. Build the release tarball.** Copy `scripts/build-compiled-release.sh`, then
update the source-binary path, the release `name:`, the job/package names, and
the output tarball name. Keep `stemcell: ubuntu-noble/1.0-arm64` as-is.

**3. Deploy it.** Copy `scripts/deploy-sample.sh` and edit the deployment-manifest
heredoc: the deployment `name:`, the `releases:` name/version, the
`instance_groups:`/`jobs:` names, and any `properties` (e.g. `port`). The
stemcell/release upload, cloud-config, and task-polling logic stay the same.
Set `APP_PORT` to your app's port to reuse the browser forwarder.

**Note on compilation:** this repo ships *pre-compiled* releases
(`compiled_packages:`) to sidestep the on-stemcell compilation workaround noted
in [Dev Workarounds](#dev-workarounds-not-production). If your app needs native
compilation (C extensions, etc.), pre-build the artifact yourself and package it
the same pre-compiled way.

## Files

| File | Purpose |
|---|---|
| `Dockerfile.stemcell` | ARM64 stemcell image (Ubuntu Noble + agent + monit) |
| `Dockerfile.director` | ARM64 BOSH Director (Ruby + Docker CPI + NATS + PostgreSQL) |
| `scripts/build-binaries.sh` | Fetches/cross-compiles the ARM64 prerequisite binaries into `bin/` |
| `scripts/build-warden-stemcell.sh` | Packages Docker image into BOSH stemcell tarball |
| `scripts/build-compiled-release.sh` | Builds pre-compiled BOSH release for sample app |
| `scripts/build-sample-app.sh` | Rebuilds the sample-app ARM64 binary from source |
| `scripts/start-director.sh` | Director container startup (all services) |
| `scripts/deploy-sample.sh` | One-command deployment automation |
| `sample-release/` | Sample BOSH release (Go HTTP server + source) |
| `sample-release/src/sample-app/main.go` | Sample app source (edit + rebuild with `scripts/build-sample-app.sh`) |
| `bin/` | ARM64 prerequisite binaries (bosh-agent, davcli, nats-server), built by `scripts/build-binaries.sh` — git-ignored, not committed |

## Binary Provenance

This repo commits **no prebuilt binaries**. The ARM64 prerequisites are built on
demand into the git-ignored `bin/` directory by `scripts/build-binaries.sh`,
each from open source at a pinned upstream version:

| Binary | Source | How `build-binaries.sh` produces it |
|---|---|---|
| `bin/bosh-agent-arm64` | [cloudfoundry/bosh-agent](https://github.com/cloudfoundry/bosh-agent) | Clone pinned tag, apply [`scripts/patches/bosh-agent-dev-workarounds.patch`](scripts/patches/bosh-agent-dev-workarounds.patch), `GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build ./main/` |
| `bin/bosh-blobstore-dav` (davcli) | [cloudfoundry/bosh-davcli](https://github.com/cloudfoundry/bosh-davcli) | Clone pinned tag, `GOOS=linux GOARCH=arm64 go build ./main/` |
| `bin/nats-server-arm64` | [nats-io/nats-server](https://github.com/nats-io/nats-server) | Download the official pinned `linux-arm64` release binary |
| `sample-release/src/sample-app/app` | `sample-release/src/sample-app/main.go` (in this repo) | `scripts/build-sample-app.sh` (`GOOS=linux GOARCH=arm64`) — **not committed**, rebuilt on first deploy |
| `monit` (inside stemcell image) | [monit 5.25.3](https://mmonit.com/monit/) | Built from source in `Dockerfile.stemcell` with the CSRF check disabled (Ubuntu Noble ships 5.33, which breaks the BOSH agent) |

The `bin/` binaries, the `sample-app` binary, the stemcell tarball, and the
release tarball are all **build outputs** (git-ignored) — none are committed.
The pinned upstream versions are defined at the top of
`scripts/build-binaries.sh`.

## Related

- [RFC: ARM64 Support for Cloud Foundry](https://github.com/cloudfoundry/community/pull/1530)
- [bosh-deployment#497 — Docker CPI on Apple Silicon](https://github.com/cloudfoundry/bosh-deployment/issues/497)
- Docker CPI ARM64 patch (3-line fix): applied inline in [`Dockerfile.director`](./Dockerfile.director) via `sed` — replaces the hardcoded `amd64` architecture with `runtime.GOARCH` in `vm/container.go`, `vm/factory.go`, and `stemcell/fs_importer.go`.
