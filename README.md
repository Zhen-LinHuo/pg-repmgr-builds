# pg-repmgr-builds

Reproducible builds for [repmgr](https://repmgr.org/) — the replication
manager and failover daemon for PostgreSQL.

Three artifacts come out of CI:

| Artifact | What it is | When to use it |
|:--|:--|:--|
| **glibc binary** | `repmgr` + `repmgrd`, dynamically linked | Hosts that already have a matching PostgreSQL client library and libc (e.g. a distro with `postgresql-16` installed). |
| **static binary** | `repmgr` + `repmgrd`, **fully statically linked** (zero shared-library deps) | Rolling-release or minimal hosts where you want the tool to survive OS / libc upgrades untouched. Drop it on any x86-64 Linux box and it runs. |
| **`postgresql-repmgr` image** | PostgreSQL 16 + repmgr, based on `pgvector/pgvector:pg16` | The database node of a repmgr-managed cluster (containers). |

## Image

```sh
docker pull ghcr.io/<owner>/postgresql-repmgr:16.15   # pinned point release
docker pull ghcr.io/<owner>/postgresql-repmgr:16       # newest 16.x
```

The image is `pgvector/pgvector:pg16` (Debian bookworm, PGDG apt repo
preconfigured) plus `postgresql-16-repmgr` from PGDG — so repmgr is compiled
against exactly the PostgreSQL the image runs.

## Binaries

Built with [GNU Guix](https://guix.gnu.org/) from the recipes in
[`pkgs/`](pkgs/):

- [`pkgs/pg-repmgr-builds/repmgr.scm`](pkgs/pg-repmgr-builds/repmgr.scm) — defines `repmgr` (glibc) and
  `repmgr-static`.
- [`pkgs/pg-repmgr-builds/curl-static.scm`](pkgs/pg-repmgr-builds/curl-static.scm) — a static `libcurl`, needed
  because Guix's `curl` ships only `libcurl.so` while repmgr hard-requires
  `-lcurl`.

Build locally:

```sh
guix build -L pkgs -e '(@ (pg-repmgr-builds repmgr) repmgr)'
guix build -L pkgs -e '(@ (pg-repmgr-builds repmgr) repmgr-static)'
```

A **static** build is genuinely static — CI verifies this by asserting
`file … | grep "statically linked"` and `ldd … | grep "not a dynamic
executable"` before publishing.

## Why a static binary

A normal dynamically-linked repmgr depends on the host's `libc` and
`libpq`. On a rolling-release distro, a libc bump can break a prebuilt binary.
The static build removes that dependency entirely, so the tool keeps working
indefinitely — until PostgreSQL itself crosses a major version (repmgr only
requires the same *major* version as the server), at which point you rebuild
against the new `libpq` (one `guix build` after bumping `postgresql-16`).

Note: `repmgr.so` (the PostgreSQL extension) is always built **shared** — a
static extension is impossible; only the `repmgr`/`repmgrd` executables are
static.

## Version

Built against **repmgr 5.5.0** and **PostgreSQL 16**. See
[repmgr's compatibility matrix](https://www.repmgr.org/docs/current/install-requirements.html#COMPATIBILITY-MATRIX)
for the PostgreSQL versions each repmgr release supports.
