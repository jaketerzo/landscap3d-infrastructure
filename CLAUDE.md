# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

The single-host infrastructure stack for the landscap3d project (landscape 3D reconstruction), operator-run on a Mac Mini. **No application service code lives here** — only:

- `docker-compose.yml` — the stack: Postgres 16, MinIO, Redis 7, nginx, plus `api` and `worker` services that build from sibling repos.
- `nginx/nginx.conf` — API gateway config.
- `backups/bin/` — Postgres backup scripts and the launchd plist (`backup.sh`, `restore.sh`, `common.sh`, `install-launchd.sh`, `com.landscap3d.backup.plist`).
- `.env.example` — complete inventory of env vars the stack reads from `.env`. The real `.env` is host-only and gitignored.

Application code (capture PWA, web viewer, reconstruction worker) lives in separate sibling repos. Do not build those here.

## Source of truth

**This repo is the source of truth for the stack.** Changes to `docker-compose.yml`, `nginx/nginx.conf`, or any backup script go through PRs against this repo, not ad-hoc edits on the Mini. The Mini holds a clone at `~/landscap3d/` that tracks main; treat it as a read-only checkout.

What stays on the Mini and is NOT under git:

- `~/landscap3d/.env` — secrets (per H1 spec § Secrets management).
- `~/landscap3d-backups/dumps/` — Postgres dumps (auto-pruned, 14-day retention).
- `~/landscap3d-backups/logs/` — `backup-*.log` + launchd stdio.
- `~/landscap3d-backups/LAST_GOOD` and `ERROR` — runtime canary files.

## Working principles

- **When importing or modifying a file that contains a hardcoded secret, stop and flag before making any change.** Do not silently substitute the secret with an env-var reference, even if the substitution is correct. Surface it first; let the human confirm the substitution. The redaction itself is often right; doing it without flagging is the problem.

## Common commands

```
# Stack lifecycle (run from the Mini's ~/landscap3d/)
docker compose up -d
docker compose ps
docker compose logs -f <service>
docker compose down

# psql into the app DB (use -U landscap3d — see note below)
docker exec -it landscap3d-postgres psql -U landscap3d -d landscap3d

# On-demand backup (daily run is already scheduled via launchd)
~/landscap3d-backups/bin/backup.sh

# Restore a dump to a scratch DB
~/landscap3d-backups/bin/restore.sh landscap3d-YYYY-MM-DD.dump landscap3d_scratch
```

## Architecture notes that aren't obvious from the files

- **Single shared credential** is used for both Postgres and MinIO, sourced from `.env` at runtime. If you rotate it, both services and any clients must change together — no secrets manager is in the loop.
- **Postgres role model**: `POSTGRES_USER: landscap3d` in compose means the container has only one superuser role, `landscap3d`. There is no `postgres` role. Every script or tool must connect with `-U landscap3d`. Connecting without `-U` will try role `postgres` (the container's OS user) and fail with `role "postgres" does not exist`.
- **Four domain tables** in the `landscap3d` DB are load-bearing: `species`, `seasonal_palette`, `species_monthly_keyframe`, `species_growth_curve`. The backup system asserts each is non-empty on every run. If any is renamed or removed, update `backups/bin/common.sh` (`EXPECTED_TABLES`) in the same change.
- **Blue Spruce (Picea pungens) is the reference species** — the only fully populated species across all four domain tables. Match its shape when doing species data work.
- **All services have `restart: unless-stopped`.** Combined with Docker Desktop's "start at login" on the Mini, the stack auto-recovers from reboots. Containers stopped manually with `docker stop` will *not* restart on reboot — that's intentional.

### nginx gateway routing

| Path | Proxies to |
|---|---|
| `http://localhost/api/` | FastAPI service (`api:8000`) |
| `http://localhost/storage/` | MinIO S3 API (`minio:9000`) |
| `http://localhost/minio-console/` | MinIO web console (`minio:9001`) |
| `http://localhost/` | static "Landscap3d API Gateway" string |

Postgres (`:5432`) and Redis (`:6379`) bind directly on the host — not fronted by nginx.

## Backups (load-bearing)

The Postgres backup system is the most important piece of operational tooling for this project. Scripts live at `backups/bin/` in this repo; runtime data (`dumps/`, `logs/`, `LAST_GOOD`, `ERROR`) lives at `~/landscap3d-backups/` on the Mini and is not under git.

The system is load-bearing because a prior backup on a USB drive was silently zero bytes — so every dump self-verifies before being promoted:

1. size floor
2. `pg_restore --list` TOC contains all four expected tables
3. smoke restore into a temp DB `landscap3d_verify_*`
4. row counts across all four tables are > 0

Only if all four pass does the dump land in `dumps/`. On failure, `~/landscap3d-backups/ERROR` is written and every new shell prints a red warning (wired via `~/.zshrc` by `install-launchd.sh`). The script also self-heals stale `landscap3d_verify_*` DBs at the start of each run.

- Scheduled: **daily 03:15** via launchd agent `com.landscap3d.backup` (`~/Library/LaunchAgents/`).
- Retention: **14 days** for dumps and `backup-*.log` files (auto-pruned); `launchd.out` / `launchd.err` truncate in place when stale or >1 MB.
- `restore.sh` refuses to restore into the live `landscap3d` DB without `--force`.

To verify the scheduler works end-to-end (not just a direct script invocation): `launchctl start com.landscap3d.backup && launchctl list com.landscap3d.backup | grep LastExitStatus`.

## Explicitly deferred work

Per the project's spine-first methodology, the following are valuable and planned but NOT built yet. Don't volunteer to add them: rendering pipeline (cel shading, post-processing), capture UX, reconstruction quality improvements, full 50-species database, user accounts, cloud deployment. If in doubt, ask before building.
