#!/bin/bash
# Canvas LMS entrypoint. One image serves both roles; CANVAS_ROLE selects.
set -eo pipefail

cd /usr/src/app

log() { echo "[entrypoint] $*"; }

ROLE="${CANVAS_ROLE:-web}"
DB_HOST="${CANVAS_DB_HOST:-postgres.railway.internal}"
DB_PORT="${CANVAS_DB_PORT:-5432}"
DB_NAME="${CANVAS_DB_DATABASE:-railway}"
DB_USER="${CANVAS_DB_USERNAME:-postgres}"

log "role=${ROLE} revision=$(cat CANVAS_REVISION 2>/dev/null || echo unknown)"

if [ -z "${CANVAS_ENCRYPTION_KEY:-}" ]; then
  log "FATAL: CANVAS_ENCRYPTION_KEY is unset. Canvas encrypts data at rest with it"
  log "       and refuses to boot once the stored hash no longer matches, so there"
  log "       is no safe default. Set a stable random value of 20+ characters."
  exit 1
fi
if [ "${#CANVAS_ENCRYPTION_KEY}" -lt 20 ]; then
  log "FATAL: CANVAS_ENCRYPTION_KEY must be at least 20 characters."
  exit 1
fi

export PGPASSWORD="${CANVAS_DB_PASSWORD:-}"

wait_for_db() {
  local i
  for i in $(seq 1 90); do
    if pg_isready -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -q; then
      log "postgres is accepting connections"
      return 0
    fi
    log "waiting for postgres at ${DB_HOST}:${DB_PORT} (${i}/90)"
    sleep 5
  done
  log "FATAL: postgres never became reachable"
  return 1
}

# Canvas' own schema is the marker: `accounts` is created by its first migration
# and by nothing else, so this asks the app's question rather than inventing a
# separate already-initialised flag.
schema_present() {
  local out
  out="$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
        -tAc "SELECT to_regclass('public.accounts') IS NOT NULL" 2>/dev/null || true)"
  [ "$out" = "t" ]
}

wait_for_db

case "$ROLE" in
  web)
    if schema_present; then
      log "existing Canvas schema found — running pending migrations only"
      bundle exec rake db:migrate
    else
      log "empty database — running db:initial_setup (migrate + first admin + defaults)"
      # CANVAS_LMS_ADMIN_EMAIL / _PASSWORD / _ACCOUNT_NAME / _STATS_COLLECTION make
      # this non-interactive. It runs before any listener opens, so there is no
      # window in which the instance is reachable without an owner.
      bundle exec rake db:initial_setup
    fi

    # Upstream's production image skips brand_configs at build time (it needs the
    # database), so the default theme CSS is generated here. Idempotent.
    log "generating brand configs"
    bundle exec rake brand_configs:generate_and_upload_all || \
      log "WARNING: brand_configs generation failed; the default theme may be unstyled"

    log "starting puma on port ${PORT:-3000} with ${WEB_CONCURRENCY:-2} worker(s)"
    exec bundle exec puma -C railway/puma.rb
    ;;

  jobs)
    # Railway has no service ordering, so the worker waits for the web role's
    # migration rather than racing it.
    for i in $(seq 1 120); do
      if schema_present; then break; fi
      log "waiting for the Canvas schema to be created by the web service (${i}/120)"
      sleep 10
    done
    if ! schema_present; then
      log "FATAL: the Canvas schema never appeared"
      exit 1
    fi

    log "starting the delayed_jobs health server on port ${PORT:-3000}"
    ruby railway/jobs_health.rb &

    log "starting delayed_job pool"
    exec bundle exec script/delayed_job run
    ;;

  *)
    log "FATAL: unknown CANVAS_ROLE '${ROLE}' (expected 'web' or 'jobs')"
    exit 1
    ;;
esac
