# AGENTS — pg-repmgr-builds

Guidance for anyone (human or agent) working in this repository.

## What this project produces

Three published artifacts, all built by CI on every push to `main` and on a
weekly schedule:

1. **glibc repmgr binary** — `repmgr` + `repmgrd`, dynamically linked. For
   hosts that already carry a matching PostgreSQL client library.
2. **musl static repmgr binary** — `repmgr` + `repmgrd` fully static against
   musl, plus the `repmgr.so` extension built glibc-shared (see
   "Architecture" below). For bare-metal / rolling-release hosts that must
   survive OS and libc upgrades.
3. **`postgresql-repmgr` image** — PostgreSQL 16 + repmgr, pushed to GHCR
   as a public package (anonymous `docker pull` works).

Release tags (`v*`) attach the binaries to a GitHub Release; the image is
pushed on every run.

## Repository layout

```
pkgs/pg-repmgr-builds/    GNU Guix package modules (the build source of truth)
  repmgr.scm               repmgr (glibc) + repmgr-static (glibc, legacy)
  repmgr-musl.scm          the published static flavour (musl execs + glibc .so)
  musl-closure.scm         musl rebuilds of libpq/curl/openssl/zlib/json-c/readline
  curl-static.scm          static libcurl for the glibc-static flavour
docker/
  postgresql-repmgr.Dockerfile   image: pgvector:pg16 + PGDG postgresql-16-repmgr
.github/workflows/build.yml      CI: binaries matrix + image + release
README.md                        user-facing overview (artifacts, why musl, versions)
```

Every Guix module lives under `pkgs/<channel>/<module>.scm` and declares
module name `(<channel> <module>)`. `-L pkgs` makes `<channel>` the load root,
so a module `(a b)` must be at `pkgs/a/b.scm`.

## Architecture: why the split-CC build

`repmgr-musl.scm` produces two things that must use **different compilers**:

- **`repmgr` / `repmgrd` executables** → `musl-gcc -static`. Static, no NSS,
  redistributable (musl is MIT).
- **`repmgr.so` PostgreSQL extension** → `gcc` (glibc, shared). It is
  `dlopen()`ed by the glibc PostgreSQL server at runtime; a musl-linked `.so`
  would not load, and a static extension is impossible.

The recipe therefore runs `make` twice in one `build` phase — once with
`CC=gcc` for the `.so`, once with `CC=musl-gcc` and `-static` (carried only in
`LDFLAGS_EX`, which PGXS applies to program links, never to the shared-object
rule) for the executables. The `install` phase splits the same way, and both
stages override `bindir` to `$out` (otherwise PGXS falls back to
`pg_config --bindir`, i.e. the read-only postgresql store, and `install` fails
with a read-only filesystem error).

A musl-static link needs musl archives for every dependency — a glibc `.a`
cannot be linked into a musl binary — which is what `musl-closure.scm`
rebuilds (`--disable-shared --enable-static`, or `make all-static-lib` for
PostgreSQL). `PGXS` also bakes the *glibc* `pg_config --libdir` as the first
`-L`, so the recipe sets `PG_CONFIG` to a wrapper answering `--libdir` with the
musl lib dir; otherwise `-lpq -lpgcommon -lpgport` resolve to glibc archives
and the link dies on `__isoc23_*` symbols musl does not provide.

## Building locally

Requires [GNU Guix](https://guix.gnu.org/) installed (`guix pull` for a
current guix — the distro's packaged guix may predate `postgresql-16`).

```sh
# dry-run first: proves the recipe evaluates (no build)
guix build -L pkgs -n -e '(@ (pg-repmgr-builds repmgr) repmgr)'
guix build -L pkgs -n -e '(@ (pg-repmgr-builds repmgr-musl) repmgr-musl)'

# full build
guix build -L pkgs -e '(@ (pg-repmgr-builds repmgr) repmgr)'            # glibc/dynamic
guix build -L pkgs -e '(@ (pg-repmgr-builds repmgr-musl) repmgr-musl)'  # musl static
```

To add or change a package, edit the `.scm` file and re-run `-n` before a full
build. `guix repl -L pkgs` (then `(use-modules (pg-repmgr-builds <module>))`)
is the cheap way to check a recipe loads; a bare `guile` cannot see `#~`
gexp syntax and will report a false reader error.

## Verifying an artifact

CI does this before publishing; do it locally after a build:

```sh
STORE=$(guix build -L pkgs -e '(@ (pg-repmgr-builds repmgr-musl) repmgr-musl)' | tail -1)

file "$STORE/bin/repmgr"      # must say "statically linked"
ldd  "$STORE/bin/repmgr"      # must say "not a dynamic executable"
"$STORE/bin/repmgr" --version # must print "repmgr 5.5.0"

# the extension must stay glibc-dynamic
file "$STORE/lib/repmgr.so"                  # "dynamically linked"
readelf -d "$STORE/lib/repmgr.so" | grep NEEDED  # must include libc.so.6
```

For the image: `docker pull ghcr.io/<owner>/postgresql-repmgr:16.15`, then
`docker run --rm <img> repmgr --version` and `… postgres --version`. No login
is needed (public package). `repmgrd` refuses to run as root by design — that
is a safety check, not a defect.

## Versioning and pins

- **PG image tag** = `env.PG_VERSION` in the workflow (e.g. `16.15`), plus a
  moving major alias `16`. Bump `PG_VERSION` to track a new point release;
  the weekly cron rebuild picks it up automatically.
- **repmgr** is pinned in the recipes (currently 5.5.0) and only requires the
  same PostgreSQL *major* as the server. When PostgreSQL crosses a major
  (e.g. 16 → 17), bump the recipes and rebuild — that is the point at which
  the static binaries must be rebuilt too.
- **musl closure** hashes live in `musl-closure.scm`; changing any musl
  dependency rebuilds `repmgr-musl` and everything downstream.

## Conventions

- Public repo: never commit private infrastructure names, hostnames, internal
  domains, or credentials. Secrets belong in GitHub Actions secrets or the
  org credential store, never in tracked files.
- Credentials are redacted as `[REDACTED]` in any generated documentation.
- Commit messages describe intent (what and why), not a changelog of edits.
- Prefer a `guix build -n` dry-run over a full build when iterating — it is
  the fast syntax/evaluation gate.
