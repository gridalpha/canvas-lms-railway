# Canvas LMS on Railway

Builds [Canvas LMS](https://github.com/instructure/canvas-lms) — Instructure's open
learning management system — into a container that runs on Railway, and adds the
configuration Railway needs.

Instructure publishes no current application image (the `instructure/canvas-lms`
Docker Hub tags were last pushed in 2019), so the `Dockerfile` here follows
upstream's own `Dockerfile.production` recipe and clones the app from the `prod`
branch — Instructure's pointer at the release running in their production estate.

## What this repository adds

| File | Why |
|---|---|
| `config/*.yml` | Canvas reads its configuration from YAML files, not environment variables. Every file here is ERB and resolves from the container environment, so one image serves any deployment. |
| `config/environments/production-local.rb` | Canvas hardcodes `public_file_server.enabled = false` (it expects nginx in front) and `force_ssl` without `assume_ssl`. `production.rb` ends by `eval`ing `production-*.rb`, which is the supported hook for both, plus Railway's proxy ranges for `request.remote_ip`. |
| `railway/puma.rb` | Canvas' own `config/puma.rb` is `threads 0, 1` with no workers — one request at a time. Concurrency comes from `WEB_CONCURRENCY` worker processes instead, because a Railway host reports 48 cores against an 8 GB container quota. |
| `railway/entrypoint.sh` | Waits for Postgres, runs `db:initial_setup` on an empty database (which seeds the first admin from environment variables *before* any listener opens) or `db:migrate` on an existing one, generates the default theme, then starts the selected role. |
| `railway/jobs_health.rb` | The `delayed_jobs` role serves no HTTP, so this gives Railway a real probe: the pool process is its parent, and it caches a Postgres reachability check. |

## Roles

`CANVAS_ROLE` selects which half of upstream's `docker-compose.yml` a container runs:

- `web` — Puma serving the application. Public.
- `jobs` — `script/delayed_job run`, Canvas' background worker pool. Private.

Both are built from this one image.

## Required variables

| Variable | Notes |
|---|---|
| `CANVAS_ENCRYPTION_KEY` | 20+ characters. Canvas encrypts data at rest with it and stores a hash of it in the database, so it must be stable for the life of the deployment. The entrypoint refuses to boot without it. |
| `CANVAS_DB_HOST`, `CANVAS_DB_PORT`, `CANVAS_DB_DATABASE`, `CANVAS_DB_USERNAME`, `CANVAS_DB_PASSWORD` | PostgreSQL. |
| `CANVAS_REDIS_URL` | Redis, used for both the cache and Canvas' own data. |
| `CANVAS_DOMAIN` | The public hostname. Canvas builds every link from it. |
| `CANVAS_LMS_ADMIN_EMAIL`, `CANVAS_LMS_ADMIN_PASSWORD` | The first site admin, created on the first boot only. |

## Optional variables

| Variable | Default | Notes |
|---|---|---|
| `CANVAS_JWT_ENCRYPTION_KEY` | `CANVAS_ENCRYPTION_KEY` | 64 characters where set. |
| `CANVAS_PREVIOUS_ENCRYPTION_KEYS` | unset | Comma-separated, for rotating `CANVAS_ENCRYPTION_KEY`. |
| `CANVAS_LMS_ACCOUNT_NAME` | Canvas' own default | Name of the root account. |
| `CANVAS_LMS_STATS_COLLECTION` | `opt_out` | `opt_in`, `anonymized` or `opt_out`. |
| `S3_BUCKET`, `S3_ENDPOINT`, `S3_REGION`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` | unset | Object storage for uploaded files. With `S3_BUCKET` unset the file store falls back to `local`, which is ephemeral on Railway and not shareable with the jobs role. Path-style addressing is forced. |
| `WEB_CONCURRENCY` | `2` | Puma worker processes. Each costs roughly 700 MB. |
| `CANVAS_JOB_WORKERS`, `CANVAS_JOB_WORKERS_HIGH` | `2`, `1` | delayed_job pool sizes. |
| `CANVAS_SMTP_ADDRESS`, `CANVAS_SMTP_PORT`, `CANVAS_SMTP_USER_NAME`, `CANVAS_SMTP_PASSWORD`, `CANVAS_SMTP_AUTHENTICATION`, `CANVAS_SMTP_OUTGOING_ADDRESS`, `CANVAS_SMTP_DEFAULT_NAME` | unset | With no `CANVAS_SMTP_ADDRESS`, mail is accepted and discarded rather than retried against a host that does not exist. |
| `CANVAS_LOG_LEVEL` | `info` | |
| `CANVAS_DB_POOL` | `5` | ActiveRecord pool per Puma worker. |

## Build arguments

| Argument | Default | Notes |
|---|---|---|
| `CANVAS_REF` | `release/2026-05-20.143` | Upstream branch or tag to build. |
| `CANVAS_ALL_LOCALES` | `0` | `1` compiles all ~30 UI locales. It roughly doubles the webpack stage, which already dominates the build. |

## Licence

Canvas LMS is AGPL-3.0. This repository only contains build and configuration files
for it.
