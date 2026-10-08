;;; pg-repmgr-builds — repmgr static binaries linked against musl libc.
;;;
;;; WHY musl, not glibc-static: glibc is LGPL and its static link is
;;; officially unsupported (users can't swap the library — LGPL compliance
;;; problem when redistributing), AND glibc's NSS (getpwuid) can't be
;;; statically linked, so `repmgr --version` fails with
;;; "could not get current user name" on a glibc-static build. musl is MIT,
;;; static-linking is its first-class design goal, and its getpwuid reads
;;; /etc/passwd directly (no NSS dlopen) — so a musl-static repmgr is both
;;; redistributable AND fully functional. This is the flavour for bare-metal
;;; hosts (NAS/HC01) that must survive OS/libc upgrades.
;;;
;;; ARCHITECTURE: only the `repmgr`/`repmgrd` EXECUTABLES go musl-static.
;;; `repmgr.so` (the PG extension) stays glibc-shared — it's dlopen()ed by the
;;; PostgreSQL server, which is glibc; a musl .so can't load in a glibc server.
;;;
;;; WHAT MUSL-SPECIFIC BUILD LOOKS LIKE (vs the glibc `repmgr-static`):
;;;   * CC = <musl>/bin/musl-gcc  (guix's musl ships the gcc wrapper,
;;;     `--enable-wrapper=all`; it needs no cross-toolchain)
;;;   * every static-link dependency must be REBUILT on musl — a glibc .a
;;;     (libz.a, libssl.a, ...) cannot link into a musl executable. guix has
;;;     NO substitutes for musl builds (its cache is glibc), so the whole
;;;     closure builds from source: libpq (musl-libpq), curl, json-c, openssl,
;;;     zlib, and repmgr itself.
;;;   * libpq is built only as libpq.a via PG's `all-static-lib` target —
;;;     the shared libpq.so link fails under musl-gcc (`-lgcc_s`), and we only
;;;     need the .a anyway.
;;;
;;; PGXS under musl: repmgr builds through `pg_config --pgxs`. The glibc
;;; postgresql's pg_config supplies only ARCH-INDEPENDENT C headers
;;; (`--includedir-server`) and the pgxs.mk rules — both work fine with
;;; musl-gcc. pgxs.mk:478 links executables with
;;;   $(CC) ... $(LDFLAGS) $(LDFLAGS_EX) $(PG_LIBS) $(LIBS) -o $@
;;; so setting CC=musl-gcc + LDFLAGS_EX=-static statically links the binaries
;;; while SHLIB_LINK (used only for MODULE_big / .so) keeps repmgr.so shared.
;;; musl versions of libpq/curl/json-c/openssl/zlib are fed in via `inputs`.

(define-module (pg-repmgr-builds repmgr-musl)
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module (guix build-system gnu)
  #:use-module (guix gexp)
  #:use-module (guix utils)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (gnu packages musl)
  #:use-module (gnu packages flex)
  #:use-module (gnu packages pkg-config)
  #:use-module (gnu packages databases)       ; postgresql-16 (pg_config/headers/pgxs)
  #:use-module (pg-repmgr-builds repmgr)       ; base repmgr package
  #:use-module (gnu packages gcc)             ; gcc (lib output = libgcc.a)
  #:use-module (pg-repmgr-builds musl-closure)) ; musl-libpq, musl-curl, musl-json-c, ...

(define-public repmgr-musl
  (package
    (inherit repmgr)
    (name "repmgr-musl")
    (arguments
     (substitute-keyword-arguments (package-arguments repmgr)
       ((#:tests? tests?)
        tests?)                                ; base sets #f (tests need a live cluster) — pass through
       ((#:phases phases)
        #~(modify-phases #$phases
            ;; Force musl-gcc as CC and static-link the executables.
            (add-before 'configure 'set-musl-toolchain
              (lambda* (#:key inputs #:allow-other-keys)
                (let ((musl-gcc (string-append (assoc-ref inputs "musl")
                                               "/bin/musl-gcc"))
                      (gcc-lib (assoc-ref inputs "gcc-lib")))
                  ;; CC env is only a fallback — PGXS Makefile.global hardcodes
                  ;; `CC = gcc` (line 254), which a makefile-internal var
                  ;; overrides an environment CC. The authoritative CC is passed
                  ;; on the make COMMAND LINE in `build`/`install` below (a
                  ;; command-line var beats any makefile assignment).
                  (setenv "CC" musl-gcc)
                  ;; musl-gcc's *link_libgcc spec only searches musl/lib for
                  ;; libgcc (musl ships none) — any non-static link dies on
                  ;; `-lgcc`. Put gcc's lib output on LIBRARY_PATH.
                  (when gcc-lib
                    (setenv "LIBRARY_PATH"
                            (string-append gcc-lib
                                           "/lib/gcc/x86_64-unknown-linux-gnu/14.3.0")))
                  (setenv "LDFLAGS_EX" "-static")
                  ;; Point PG_CONFIG at musl-libpq's wrapper.  PGXS reads
                  ;; --libdir at Makefile-include time (Makefile.global:158) and
                  ;; injects it as the FIRST -L (LDFLAGS_INTERNAL :308 and
                  ;; libpq_pgport :602), so the wrapper's musl lib dir wins over
                  ;; glibc's for -lpgcommon -lpgport -lpq — this is what kills
                  ;; the __isoc23_* undefined references (musl's .a have none).
                  ;; The wrapper defers every other field to the real pg_config
                  ;; (headers/pgxs/bindir stay arch-agnostic and correct).
                  (setenv "PG_CONFIG"
                          (string-append (assoc-ref inputs "libpq") "/bin/pg_config")))
                #t))
            (replace 'build
              (lambda* (#:key inputs #:allow-other-keys)
                (let* ((musl-gcc (string-append (assoc-ref inputs "musl")
                                                "/bin/musl-gcc"))
                       (libpq-dir (string-append (assoc-ref inputs "libpq") "/lib"))
                       (curl-dir (string-append (assoc-ref inputs "curl") "/lib"))
                       (jsonc-dir (string-append (assoc-ref inputs "json-c") "/lib"))
                       (ssl-dir (string-append (assoc-ref inputs "openssl") "/lib"))
                       (zlib-dir (string-append (assoc-ref inputs "zlib") "/lib"))
                       (readline-dir (string-append (assoc-ref inputs "readline") "/lib"))
                       (ldflags (string-append "LDFLAGS=-L" libpq-dir
                                               " -L" curl-dir " -L" jsonc-dir
                                               " -L" ssl-dir " -L" zlib-dir
                                               " -L" readline-dir)))
                  ;; Architecture (plan C): a single `CC` cannot build BOTH a
                  ;; musl-static executable AND a glibc-shared repmgr.so, so we
                  ;; run make TWICE with different CCs.
                  ;;
                  ;; Stage 1 — repmgr.so with the glibc PG toolchain (CC=gcc).
                  ;;   repmgr.so is dlopen()'d by the glibc PostgreSQL server, so
                  ;;   it MUST be glibc-linked (NEEDED: libc.so.6).  Building it
                  ;;   with musl-gcc fails: the shlib rule needs -lgcc_s, which
                  ;;   musl's specs cannot find (musl ships no libgcc_s).
                  (invoke "make" "repmgr.so"
                          "CC=gcc"
                          ldflags)
                  ;; Stage 2 — the repmgr/repmgrd executables, musl + fully
                  ;;   static.  `-static` rides in LDFLAGS_EX (used ONLY by the
                  ;;   program link rules; the shlib rule never sees it).
                  ;;   CC=musl-gcc on the command line beats PGXS's `CC = gcc`.
                  (invoke "make" "-j" (number->string (parallel-job-count))
                          "repmgr" "repmgrd"
                          (string-append "CC=" musl-gcc " -static")
                          "LDFLAGS_EX=-static"
                          ldflags))))

            (replace 'install
              (lambda* (#:key inputs outputs #:allow-other-keys)
                (let* ((out (assoc-ref outputs "out"))
                      (musl-gcc (string-append (assoc-ref inputs "musl")
                                               "/bin/musl-gcc"))
                      (libpq-dir (string-append (assoc-ref inputs "libpq") "/lib"))
                      (curl-dir (string-append (assoc-ref inputs "curl") "/lib"))
                      (jsonc-dir (string-append (assoc-ref inputs "json-c") "/lib"))
                      (ssl-dir (string-append (assoc-ref inputs "openssl") "/lib"))
                      (zlib-dir (string-append (assoc-ref inputs "zlib") "/lib"))
                      (readline-dir (string-append (assoc-ref inputs "readline") "/lib"))
                      (sharedirs (list (string-append "sharedir=" out "/share")
                                       (string-append "datadir=" out "/share")
                                       (string-append "docdir=" out "/share/doc")))
                      (libdirs (list (string-append "pkglibdir=" out "/lib"))))
                  ;; `bindir` must be overridden on BOTH stages: without it
                  ;; PGXS falls back to `pg_config --bindir` = the read-only
                  ;; glibc postgresql store, and `install` dies with EROFS.
                  ;; Stage 1: install repmgr.so with the glibc CC — `make
                  ;; install` would otherwise relink it under musl-gcc (CC from
                  ;; the command line) and hit the same -lgcc_s failure.
                  (apply invoke "make" "install"
                         "CC=gcc"
                         (string-append "LDFLAGS=-L" libpq-dir
                                        " -L" curl-dir " -L" jsonc-dir
                                        " -L" ssl-dir " -L" zlib-dir
                                        " -L" readline-dir)
                         (append (list (string-append "bindir=" out "/bin"))
                                 libdirs sharedirs))
                  ;; Stage 2: install the musl-static executables.
                  (apply invoke "make" "install"
                         (string-append "CC=" musl-gcc " -static")
                         "LDFLAGS_EX=-static"
                         (string-append "LDFLAGS=-L" libpq-dir
                                        " -L" curl-dir " -L" jsonc-dir
                                        " -L" ssl-dir " -L" zlib-dir
                                        " -L" readline-dir)
                         (append (list (string-append "bindir=" out "/bin"))
                                 libdirs sharedirs))
                  #t)))))))

    (inputs
     (append
      (filter (lambda (i)
                (not (member (car i) '("curl" "json-c" "openssl" "zlib" "postgresql" "readline"))))
              (package-inputs repmgr))
      ;; musl-built static closure (see musl-closure.scm).
      (list (list "musl" musl)
            (list "gcc-lib" gcc "lib")          ; libgcc.a for LIBRARY_PATH (3-tuple label pkg output)
            (list "libpq" musl-libpq)           ; musl libpq.a + libpgcommon.a + libpgport.a
            (list "readline" musl-readline)     ; musl libreadline.a (pg_config --libs wants -lreadline)
            (list "postgresql" postgresql-16)   ; pg_config + PGXS + headers (arch-agnostic)
            (list "curl" musl-curl)
            (list "json-c" musl-json-c)
            (list "openssl" musl-openssl)
            (list "zlib" musl-zlib))))
    (synopsis "repmgr (musl static binaries + glibc extension)")
    (description "repmgr and repmgrd built as fully static musl binaries — no
NSS, LGPL-free, runs on any x86-64 Linux host regardless of libc or system
upgrades. The repmgr.so PostgreSQL extension remains glibc-shared (dlopen'ed by
the glibc PostgreSQL server).")))
