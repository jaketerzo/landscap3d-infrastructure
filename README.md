# landscap3d-infrastructure

Single-host infrastructure stack for the landscap3d project. Runs on an operator's Mac Mini behind Tailscale. No application code lives here — only the compose stack, nginx config, env-var template, and the Postgres backup tooling.

## Services

- **postgres** (Postgres 16) — primary database; one superuser role `landscap3d`.
- **minio** (MinIO) — S3-compatible blob storage for scan photos.
- **redis** (Redis 7) — work queue for the reconstruction worker.
- **nginx** (nginx:alpine) — API gateway; routes `/api/`, `/storage/`, `/minio-console/`.
- **api** — FastAPI service; built from a sibling repo at `../code/landscap3d-api/`.
- **worker** — RQ-based reconstruction worker; built from `../code/landscap3d-worker/`.

Postgres (`:5432`) and Redis (`:6379`) bind directly on the host. nginx fronts MinIO and the FastAPI service.

## Bring-up from a clean clone

The full Mac Mini rebuild guide lives in the project's docs repo. The condensed form:

```
# 1. Clone into the canonical runtime path on the Mini
git clone https://github.com/jaketerzo/landscap3d-infrastructure.git ~/landscap3d
cd ~/landscap3d

# 2. Restore .env from secrets storage (NOT in git — see Secrets management)
cp .env.example .env
$EDITOR .env  # fill in real values

# 3. Restore the backup directory's runtime state from USB (dumps stay off-repo)
cp -r '/Volumes/<usb>/landscap3d-backups' ~/landscap3d-backups

# 4. Bring up the stack
docker compose up -d

# 5. Restore the latest verified Postgres dump
LATEST=$(ls -t ~/landscap3d-backups/dumps/*.dump | head -1)
docker cp "$LATEST" landscap3d-postgres:/tmp/restore.dump
docker exec landscap3d-postgres pg_restore -U landscap3d -d landscap3d \
  --clean --if-exists /tmp/restore.dump

# 6. Reinstall the launchd backup schedule
~/landscap3d/backups/bin/install-launchd.sh
```

The `api` and `worker` services build from sibling repos. Clone them to `~/code/landscap3d-api/` and `~/code/landscap3d-worker/` before `docker compose up` (the compose `build:` paths are relative).

## Sync state

The source-of-truth `docker-compose.yml` lives in this repo and uses env-var substitution for all secrets. As of the initial import, the Mini's working `~/landscap3d/docker-compose.yml` still has hardcoded password values that predate this repo. Reconcile the Mini's compose to match this repo's substitution-based version (verify the stack comes up clean against the existing `.env`) before making any further changes to the compose file. Until reconciled, the two files will drift and the source-of-truth claim is aspirational.

## Secrets management

`.env` is host-only state, gitignored. **Never commit it.** Copy `.env.example` to `.env` on each host and fill in real values.

`.env.example` is the **complete inventory** of env vars the stack reads from `.env`. Vars that are hardcoded as defaults in `docker-compose.yml` (e.g. `MAX_PHOTOS_PER_SCAN`, `PRESIGNED_URL_EXPIRY_SECONDS`) are intentionally absent from `.env.example`. To make one of those host-configurable, switch the compose entry to `${VAR_NAME}` substitution and add it to `.env.example` in the same change.

Per the project's H1 spec § Secrets management, real secret management (Vault, SOPS, etc.) is post-prototype. v1 trust model: only Tailscale-connected devices reach the stack; the Tailscale mesh is the auth boundary at the network layer.

## Repository layout

```
docker-compose.yml         the stack
nginx/nginx.conf           gateway config
.env.example               env-var inventory (placeholders only)
backups/bin/               Postgres backup scripts + launchd plist
CLAUDE.md                  project context for Claude Code sessions
README.md                  this file
```

## Contributing

This repo is the source of truth for the stack. Changes to compose, nginx, or backup scripts go through PRs here — not ad-hoc edits on the Mini. The Mini's clone at `~/landscap3d/` is treated as a read-only checkout pulled from main.

`main` is protected: PRs required, no direct push.
