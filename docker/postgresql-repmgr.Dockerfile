# PostgreSQL 16 + repmgr
#
# A thin extension of the official pgvector PostgreSQL 16 image that adds
# repmgr (the replication manager) so the image can serve as a node in a repmgr
# -managed streaming-replication cluster.
#
# Base choice: pgvector/pgvector:pg16 is Debian bookworm + the PGDG apt repo
# (already configured), which makes repmgr a one-line install — PGDG ships
# postgresql-16-repmgr compiled against exactly the PostgreSQL this image runs.
#
# Build:   docker build -t ghcr.io/<owner>/postgresql-repmgr:<PGTAG> .
# Tag:     <PGTAG> tracks the newest PostgreSQL 16.x (e.g. "16.15", plus a
#          moving "16" alias). See .github/workflows/build.yml.

FROM pgvector/pgvector:pg16

# Install repmgr from PGDG (matches the image's PostgreSQL major version).
# --no-install-recommends keeps the layer small; apt lists are pruned after.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends postgresql-16-repmgr; \
    rm -rf /var/lib/apt/lists/*

# repmgrd is the failover daemon; the image ships both `repmgr` (CLI) and
# `repmgrd` (daemon). They are configured at runtime via the standard
# /etc/repmgr.conf and the PGDATA-repmgr extension, not baked into the image.
#
# Smoke-test with `repmgr` only: `repmgrd` refuses to run as root (the Docker
# build user), which is expected — it runs as the postgres user at runtime.
RUN command -v repmgr && command -v repmgrd \
    && repmgr --version

LABEL org.opencontainers.image.title="postgresql-repmgr" \
      org.opencontainers.image.description="PostgreSQL 16 with repmgr (streaming replication manager)" \
      org.opencontainers.image.source="https://github.com/Zhen-LinHuo/pg-repmgr-builds"
