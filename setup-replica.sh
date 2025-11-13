#!/usr/bin/env bash
set -euo pipefail

# This script runs inside the hot-backup container the first time it boots.
# It prepares passwordless connectivity to the primary so pg_basebackup can
# be executed reliably whenever the replica needs to be re-initialized.

REPL_USER="${REPLICATOR_ROLE:-replicator}"
REPL_PASS="${REPLICATOR_PASSWORD:-replicator_password}"
PRIMARY_HOST="${PRIMARY_HOST:-primary-db}"
PRIMARY_PORT="${PRIMARY_PORT:-5432}"
PGPASS_FILE="/var/lib/postgresql/.pgpass"

echo "Configuring replication credentials for user '${REPL_USER}'..."
cat > "${PGPASS_FILE}" <<EOF
${PRIMARY_HOST}:${PRIMARY_PORT}:*:${REPL_USER}:${REPL_PASS}
EOF
chmod 600 "${PGPASS_FILE}"
chown postgres:postgres "${PGPASS_FILE}" 2>/dev/null || true

cat >/usr/local/bin/reinit-standby.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

PGDATA="${PGDATA:-/var/lib/postgresql/data/pgdata}"
REPL_USER="${REPLICATOR_ROLE:-replicator}"
REPL_PASS="${REPLICATOR_PASSWORD:-replicator_password}"
PRIMARY_HOST="${PRIMARY_HOST:-primary-db}"
PRIMARY_PORT="${PRIMARY_PORT:-5432}"

echo "Re-initializing standby at ${PGDATA} from ${PRIMARY_HOST}:${PRIMARY_PORT}..."
rm -rf "${PGDATA:?}/"*
PGPASSWORD="${REPL_PASS}" pg_basebackup \
  -h "${PRIMARY_HOST}" \
  -p "${PRIMARY_PORT}" \
  -D "${PGDATA}" \
  -U "${REPL_USER}" \
  -Fp -Xs -P -R
chmod 700 "${PGDATA}"
EOF

chmod +x /usr/local/bin/reinit-standby.sh
echo "Replication helper ready. Use 'docker compose exec hot-backup reinit-standby.sh' to force a fresh base backup."
