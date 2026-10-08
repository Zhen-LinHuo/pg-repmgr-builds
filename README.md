# pg-repmgr-builds

Reproducible builds for [repmgr](https://repmgr.org/) — the replication
manager and failover daemon for PostgreSQL.

Three artifacts come out of CI:

| Artifact | What it is | When to use it |
|:--|:--|:--|
| **glibc binary** | `repmgr` + `repmgrd`, dynamically linked against glibc | Hosts that already have a matching PostgreSQL client library and libc (e.g. a distro with `postgresql-16` installed). |
| **musl static binary** | `repmgr` + `repmgrd`, **fully statically linked against musl** (zero shared-library deps); the `repmgr.so` extension is separately glibc-shared | Bare-metal, rolling-release, or minimal hosts where the tool must survive OS / libc upgrades untouched. Drop it on any x86-64 Linux box and it runs. |
| **`postgresql-repmgr` image** | PostgreSQL 16 + repmgr, based on `pgvector/pgvector:pg16` | The database node of a repmgr-managed cluster (containers). |

## Image

```sh
docker pull ghcr.io/<owner>/postgresql-repmgr:16.15   # pinned point release
docker pull ghcr.io/<owner>/postgresql-repmgr:16       # newest 16.x
```

The image is `pgvector/pgvector:pg16` (Debian bookworm, PGDG apt repo
preconfigured) plus `postgresql-16-repmgr` from PGDG — so repmgr is compiled
against exactly the PostgreSQL the image runs. It is published as a **public**
GHCR package, so an anonymous `docker pull` needs no login.

## Binaries

Built with [GNU Guix](https://guix.gnu.org/) from the recipes in
[`pkgs/`](pkgs/):

- [`pkgs/pg-repmgr-builds/repmgr.scm`](pkgs/pg-repmgr-builds/repmgr.scm) — defines `repmgr` (glibc/dynamic) and
  `repmgr-static` (glibc-static; kept for reference, superseded by the musl
  flavour below).
- [`pkgs/pg-repmgr-builds/repmgr-musl.scm`](pkgs/pg-repmgr-builds/repmgr-musl.scm) — the published **static** flavour: musl-static
  executables **plus** the glibc-shared `repmgr.so`, in one package.
- [`pkgs/pg-repmgr-builds/musl-closure.scm`](pkgs/pg-repmgr-builds/musl-closure.scm) — musl rebuilds of repmgr's link closure
  (libpq, curl, openssl, zlib, json-c, readline). A musl-static binary cannot
  link a glibc archive, so every static dependency is rebuilt with `musl-gcc`.
- [`pkgs/pg-repmgr-builds/curl-static.scm`](pkgs/pg-repmgr-builds/curl-static.scm) — a static `libcurl`, needed
  because Guix's `curl` ships only `libcurl.so` while repmgr hard-requires
  `-lcurl`.

Build locally:

```sh
guix build -L pkgs -e '(@ (pg-repmgr-builds repmgr) repmgr)'            # glibc/dynamic
guix build -L pkgs -e '(@ (pg-repmgr-builds repmgr-musl) repmgr-musl)'  # musl static (published)
```

A **static** build is genuinely static — CI verifies this by asserting
`file … | grep "statically linked"` and `ldd … | grep "not a dynamic
executable"` before publishing.

## Why musl static (not glibc static)

A normal dynamically-linked repmgr depends on the host's `libc` and
`libpq`. On a rolling-release distro, a libc bump can break a prebuilt binary.
The static build removes that dependency entirely, so the tool keeps working
indefinitely — until PostgreSQL itself crosses a major version (repmgr only
requires the same *major* version as the server), at which point you rebuild
against the new `libpq` (one `guix build` after bumping `postgresql-16`).

The static flavour links **musl** rather than glibc for two reasons:

1. **Redistribution / licensing** — glibc is LGPL and its static link is
   officially unsupported (the user cannot swap the library, an LGPL
   compliance problem when redistributing). musl is MIT, and static linking is
   its first-class design goal.
2. **NSS** — glibc's `getpwuid()` still `dlopen`s `libnss_*.so` even inside a
   `-static` binary, so a glibc-static `repmgr` can die with
   `could not get current user name` at start-up. musl has no NSS modules and
   reads `/etc/passwd` directly, so a musl-static build is fully functional.

Note: `repmgr.so` (the PostgreSQL extension) is always built **shared** — a
static extension is impossible. It is `dlopen()`ed by the **glibc** PostgreSQL
server, so it is glibc-linked while the `repmgr`/`repmgrd` executables are
musl-static. This split is deliberate and is what `repmgr-musl.scm` builds.

## Version

Built against **repmgr 5.5.0** and **PostgreSQL 16**. See
[repmgr's compatibility matrix](https://www.repmgr.org/docs/current/install-requirements.html#COMPATIBILITY-MATRIX)
for the PostgreSQL versions each repmgr release supports.
