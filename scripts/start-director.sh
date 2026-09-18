#!/bin/bash
set -e

echo "Starting ARM64 BOSH Director"
echo "Architecture: $(uname -m)"

# -----------------------------------------------------------------------------
# Generate credentials at startup (no hardcoded/known passwords in the image)
# -----------------------------------------------------------------------------
# Credentials are generated once and persisted so that restarts of the same
# container keep working. They are exported to a well-known env file that
# helper scripts (e.g. deploy-sample.sh) read via `docker exec`. The secret
# values are deliberately NOT printed to stdout, so they are never persisted
# in `docker logs` history; retrieve them by reading the creds file directly.
CREDS_FILE=/var/vcap/bosh/etc/director-creds.env
# Set the restrictive umask unconditionally, before the first-run check below.
# It has to cover the whole script, not just credential generation: the TLS
# private keys written further down are created on *every* start, so leaving
# the umask inside the `if` gave them 0600 on a first run but 0644 on a
# container restart. The few files that must be readable by the nginx worker
# (www-data) are chmod'ed explicitly where they are created.
umask 077

if [ ! -f "$CREDS_FILE" ]; then
    mkdir -p "$(dirname "$CREDS_FILE")"
    # Allow override via environment variables for reproducible/CI use.
    ADMIN_PASSWORD="${BOSH_ADMIN_PASSWORD:-$(openssl rand -hex 16)}"
    BLOBSTORE_PASSWORD="${BOSH_BLOBSTORE_PASSWORD:-$(openssl rand -hex 16)}"
    cat >"$CREDS_FILE" <<CREDS
BOSH_ADMIN_USER=admin
BOSH_ADMIN_PASSWORD=${ADMIN_PASSWORD}
BOSH_BLOBSTORE_USER=agent
BOSH_BLOBSTORE_PASSWORD=${BLOBSTORE_PASSWORD}
CREDS
    chmod 600 "$CREDS_FILE"
fi
# shellcheck disable=SC1090
. "$CREDS_FILE"

echo ""
echo "BOSH Director credentials (generated)"
echo " Director API (port 25555) credentials were generated."
echo " They are NOT printed here to avoid persisting secrets in docker logs."
echo " Retrieve them from the running container:"
echo "   docker exec bosh-director cat ${CREDS_FILE}"
echo ""

# Start PostgreSQL
service postgresql start
sleep 3

# Create BOSH database
su -c "psql -c \"CREATE USER bosh WITH PASSWORD 'bosh' SUPERUSER;\"" postgres 2>/dev/null || true
su -c "psql -c \"CREATE DATABASE bosh OWNER bosh;\"" postgres 2>/dev/null || true

# Generate self-signed certs.
#
# The NATS server itself is started WITHOUT TLS below (dev workaround), so these
# are not used to secure the mbus. They are still referenced by the `nats:`
# block of the Director config, and the Director signs a per-agent NATS client
# certificate from this CA for each VM it creates — so despite the plaintext
# bus they are not dead code. (The previously generated director.key/.csr/.pem
# were referenced by nothing and have been dropped.)
mkdir -p /var/vcap/bosh/etc/certs
cd /var/vcap/bosh/etc/certs
DIRECTOR_IP=$(hostname -I | awk '{print $1}')
NATS_SAN="subjectAltName=IP:127.0.0.1,IP:${DIRECTOR_IP},DNS:nats,DNS:localhost"
openssl req -x509 -newkey rsa:2048 -keyout ca.key -out ca.pem -days 365 -nodes -subj "/CN=BOSH-CA" 2>/dev/null
# NATS cert with IP SAN so agent can verify server identity
openssl req -newkey rsa:2048 -keyout nats.key -out nats.csr -nodes -subj "/CN=nats" \
    -addext "$NATS_SAN" 2>/dev/null
openssl x509 -req -in nats.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out nats.pem -days 365 \
    -extfile <(printf '%s\n' "$NATS_SAN") 2>/dev/null

# Start NATS WITHOUT TLS (development workaround)
/var/vcap/bosh/bin/nats \
    --addr 0.0.0.0 \
    --port 4222 \
    -m 8222 &
sleep 2

# Create required directories
mkdir -p /var/vcap/store/director/blobstore
mkdir -p /var/vcap/sys/log/director
mkdir -p /var/vcap/data/tmp
mkdir -p /var/vcap/sys/log/blobstore

# Configure and start nginx DAV blobstore on port 25250
# Agents use this endpoint to fetch packages/blobs during compilation
# The DAV client adds a sha1-based prefix dir (e.g., "ab/blob-id"), so nginx
# needs to handle both prefixed and flat paths. We serve from a "store" subdir
# that the Director will write into via the DAV protocol as well.
mkdir -p /var/vcap/store/director/blobstore/store
# nginx workers run as www-data and must both traverse and write the entire
# blobstore path. Chown/chmod the whole blobstore tree (not just the "store"
# leaf): the parent "blobstore" dir defaulted to 0700 root:root, which blocked
# www-data from traversing into "store", causing DAV PUTs to fail with
# nginx "[crit] rename(...) failed (13: Permission denied)" and HTTP 500.
chown -R www-data:www-data /var/vcap/store/director/blobstore
chmod 755 /var/vcap/store/director/blobstore /var/vcap/store/director/blobstore/store
chown -R www-data:www-data /var/vcap/data/tmp
chmod 755 /var/vcap/data/tmp
cat >/etc/nginx/sites-available/blobstore <<'BLOBCFG'
server {
  listen 25250;
  server_name "";

  access_log /var/vcap/sys/log/blobstore/access.log;
  error_log /var/vcap/sys/log/blobstore/error.log;

  client_max_body_size 10000m;

  location / {
    root /var/vcap/store/director/blobstore/store;
    client_body_temp_path /var/vcap/data/tmp;

    dav_methods DELETE PUT;
    create_full_put_path on;

    auth_basic "Blobstore";
    auth_basic_user_file /etc/nginx/blobstore_users;
  }
}
BLOBCFG

# Create htpasswd for blobstore auth (generated credentials).
# NOTE: the umask 077 set earlier (for director-creds.env) is still in effect,
# so htpasswd would create this file as 0600 root:root. nginx worker processes
# run as www-data and must be able to read it, otherwise every authenticated
# blob PUT fails with nginx "[crit] open() blobstore_users failed (13:
# Permission denied)" and returns HTTP 500. Make it owner-root, group-www-data,
# and group-readable so only nginx (not the world) can read the hashes.
htpasswd -cb /etc/nginx/blobstore_users "${BOSH_BLOBSTORE_USER}" "${BOSH_BLOBSTORE_PASSWORD}"
chown root:www-data /etc/nginx/blobstore_users
chmod 640 /etc/nginx/blobstore_users

# Enable the blobstore site
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/blobstore /etc/nginx/sites-enabled/blobstore

# Start nginx (DAV blobstore)
nginx
echo "Nginx DAV blobstore started on port 25250"

# Create Docker CPI config (use DIRECTOR_IP for agent mbus since VMs are separate containers)
DIRECTOR_IP_FOR_CPI=$(hostname -I | awk '{print $1}')
cat >/var/vcap/bosh/etc/cpi.json <<CPICFG
{
  "actions": {
    "docker": {
      "host": "unix:///var/run/docker.sock",
      "api_version": "1.44"
    },
    "agent": {
      "mbus": "nats://${DIRECTOR_IP_FOR_CPI}:4222",
      "blobstore": {
        "provider": "dav",
        "options": {
          "endpoint": "http://${DIRECTOR_IP_FOR_CPI}:25250",
          "user": "${BOSH_BLOBSTORE_USER}",
          "password": "${BOSH_BLOBSTORE_PASSWORD}"
        }
      }
    }
  },
  "start_containers_with_systemd": true
}
CPICFG

# Create CPI wrapper that passes the config
cat >/var/vcap/bosh/bin/cpi <<'CPIWRAPPER'
#!/bin/bash
exec /var/vcap/bosh/bin/docker_cpi -configPath=/var/vcap/bosh/etc/cpi.json
CPIWRAPPER
chmod +x /var/vcap/bosh/bin/cpi

# Create verify-multidigest stub.
#
# DEV WORKAROUND (not production): the real bosh-utils verify-multidigest binary
# checks the digests of uploaded stemcells/releases and of blobs the Director
# hands to agents. This stub always exits 0, so those integrity checks are
# effectively disabled — a corrupted or tampered stemcell/release would be
# accepted. Acceptable only because this Director is local and loopback-scoped;
# see "Dev Workarounds" in README.md. Production BOSH ships the real binary
# from the bosh-utils release.
cat >/var/vcap/bosh/bin/verify-multidigest <<'SCRIPT'
#!/bin/bash
exit 0
SCRIPT
chmod +x /var/vcap/bosh/bin/verify-multidigest

# Write BOSH Director config
DIRECTOR_IP=$(hostname -I | awk '{print $1}')
cat >/opt/bosh-director.yml <<EOF
---
name: bosh-lite-arm64
dir: /var/vcap/store/director
port: 25555
bind_address: 0.0.0.0
version: 0.0.1-arm64

audit_log_path: /var/vcap/sys/log/director

logging:
  level: info
  file: /var/vcap/sys/log/director/director.log

db:
  adapter: postgres
  host: 127.0.0.1
  port: 5432
  database: bosh
  user: bosh
  password: bosh

mbus: nats://127.0.0.1:4222

nats:
  server_ca_path: /var/vcap/bosh/etc/certs/ca.pem
  client_certificate_path: /var/vcap/bosh/etc/certs/nats.pem
  client_private_key_path: /var/vcap/bosh/etc/certs/nats.key
  client_ca_certificate_path: /var/vcap/bosh/etc/certs/ca.pem
  client_ca_private_key_path: /var/vcap/bosh/etc/certs/ca.key

blobstore:
  provider: davcli
  options:
    endpoint: http://127.0.0.1:25250
    user: ${BOSH_BLOBSTORE_USER}
    password: ${BOSH_BLOBSTORE_PASSWORD}
    davcli_path: /var/vcap/packages/davcli/bin/davcli

cpi:
  name: docker
  path: /var/vcap/bosh/bin/cpi
  max_supported_api_version: 2
  preferred_api_version: 2

cloud:
  plugin: external
  provider:
    name: external
    path: /var/vcap/bosh/bin/cpi
  properties:
    cpi_path: /var/vcap/bosh/bin/cpi
    agent:
      mbus: nats://${DIRECTOR_IP}:4222
      blobstore:
        provider: dav
        options:
          endpoint: http://${DIRECTOR_IP}:25250
          user: ${BOSH_BLOBSTORE_USER}
          password: ${BOSH_BLOBSTORE_PASSWORD}

verify_multidigest_path: /var/vcap/bosh/bin/verify-multidigest

agent:
  env:
    bosh:
      blobstores:
      - provider: dav
        options:
          endpoint: http://${DIRECTOR_IP}:25250
          user: ${BOSH_BLOBSTORE_USER}
          password: ${BOSH_BLOBSTORE_PASSWORD}

trusted_certs: ""

user_management:
  provider: local
  local:
    users:
    - name: ${BOSH_ADMIN_USER}
      password: ${BOSH_ADMIN_PASSWORD}
EOF

# Run database migrations
cd /opt/bosh/src/bosh-director
echo "Running database migrations..."
bundle exec sequel -m db/migrations postgres://bosh:bosh@127.0.0.1/bosh 2>&1 | tail -3
echo "Migrations complete."

echo ""
echo "BOSH Director ARM64 starting..."
echo "Architecture: $(uname -m)"
echo "Ruby: $(ruby --version)"
echo "Port: 25555"

# Run BOSH Director and Worker
cd /opt/bosh/src/bosh-director
bundle exec bosh-director-worker -c /opt/bosh-director.yml &
exec bundle exec bosh-director -c /opt/bosh-director.yml
