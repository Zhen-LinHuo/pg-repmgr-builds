;;; pg-repmgr-builds — repmgr packaged for reproducible builds via GNU Guix.
;;;
;;; Two flavours are defined here:
;;;
;;;   repmgr          glibc/dynamic — a normal dynamically-linked build, correct
;;;                   for hosts that already carry a matching PostgreSQL client
;;;                   library and libc.
;;;   repmgr-static   fully static  — a self-contained ELF binary with zero
;;;                   shared-library dependencies (`file` reports "statically
;;;                   linked", `ldd` reports "not a dynamic executable"). Drop it
;;;                   on any x86-64 Linux host and it runs regardless of that
;;;                   host's libc or system upgrades. This is the flavour meant
;;;                   for rolling-release or minimal systems where you want the
;;;                   tool to survive OS churn until PostgreSQL itself needs a
;;;                   major-version bump (at which point rebuild against the new
;;;                   libpq).
;;;
;;; Both compile against PostgreSQL 16 (postgresql-16) so they match a PG16
;;; cluster; repmgr only requires the same MAJOR version as the server.
;;;
;;; repmgr is an autotools project driven through PGXS: it needs pg_config plus
;;; the server dev files (pgxs.mk), and links libcurl + json-c
;;; (Makefile.global.in: PG_LDFLAGS=-lcurl -ljson-c).
;;;
;;; The static flavour is NOT a one-line `static-package`. Three real problems
;;; had to be solved (see the comments on repmgr-static below):
;;;   1. PGXS ignores the LDFLAGS that `static-package` injects for executables;
;;;      we force `-static` onto LDFLAGS_EX (used only by the program link rules)
;;;      while leaving LDFLAGS/SHLIB_LINK default so repmgr.so stays shared.
;;;   2. A PostgreSQL extension (.so) cannot be static — so repmgr.so is always
;;;      built shared; only the repmgr/repmgrd binaries are static.
;;;   3. guix's curl ships only libcurl.so (no .a), yet repmgr hard-requires
;;;      -lcurl. We provide curl-static (pkgs/pg-repmgr-builds/curl-static.scm) whose closure
;;;      collapses to openssl+zlib (both of which DO ship static outputs).

(define-module (pg-repmgr-builds repmgr)
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module (guix build-system gnu)        ; static-package lives here
  #:use-module (guix gexp)                    ; #~ gexp literals in arguments
  #:use-module (guix utils)                   ; substitute-keyword-arguments
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (gnu packages flex)            ; flex (mandatory lexer)
  #:use-module (gnu packages curl)            ; libcurl (PG_LDFLAGS -lcurl)
  #:use-module (gnu packages web)             ; json-c (PG_LDFLAGS -ljson-c)
  #:use-module (gnu packages pkg-config)
  #:use-module (gnu packages tls)             ; openssl (PGXS links -lssl -lcrypto)
  #:use-module (gnu packages compression)     ; zlib (-lz)
  #:use-module (gnu packages readline)        ; readline (-lreadline)
  #:use-module (gnu packages databases)      ; postgresql-16
  #:use-module (pg-repmgr-builds curl-static)) ; libcurl.a for the static build

(define %repmgr-version "5.5.0")

(define-public repmgr
  (package
    (name "repmgr")
    (version %repmgr-version)
    (source
     (origin
       (method url-fetch)
       ;; Upstream release tarball (EnterpriseDB/repmgr v5.5.0).
       (uri (string-append
             "https://codeload.github.com/EnterpriseDB/repmgr/tar.gz/refs/tags/v"
             version))
       (sha256
        (base32
         "111z3c7q10n2vmz0l9q3h2r47qvrjki4lvchmi8q34g2h594yl3k"))
       ;; codeload tarballs unpack into a single top-level dir that
       ;; gnu-build-system does not auto-strip; naming the file keeps the
       ;; source layout predictable (we also chdir in a phase, see below).
       (file-name (string-append name "-" version ".tar.gz"))))
    (build-system gnu-build-system)
    (arguments
     (list
      #:tests? #f                            ; repmgr's tests need a live cluster
      #:phases
      #~(modify-phases %standard-phases
          ;; gexp builders get a fresh module scope: scandir needs (ice-9 ftw),
          ;; file-is-directory? comes from (guix build utils).
          (add-after 'unpack 'enter-source-dir
            (lambda _
              (use-modules (ice-9 ftw) (guix build utils))
              (let ((entries (scandir (getcwd)
                                      (lambda (f)
                                        (and (not (member f '("." "..")))
                                             (file-is-directory? f))))))
                (when (= 1 (length entries))
                  (chdir (car entries))))
              #t))
          ;; Point configure at postgresql's pg_config (not whatever is on
          ;; PATH), so we build against the intended PG major version.
          (add-before 'configure 'set-pg-config
            (lambda* (#:key inputs #:allow-other-keys)
              (setenv "PG_CONFIG"
                      (string-append (assoc-ref inputs "postgresql")
                                     "/bin/pg_config"))
              #t))
          ;; PGXS `make install` writes into pg_config's dirs (pkglibdir,
          ;; bindir, sharedir), which are the read-only postgresql store path.
          ;; Redirect them so repmgr installs into its OWN $out instead.
          (replace 'install
            (lambda* (#:key outputs #:allow-other-keys)
              (let ((out (assoc-ref outputs "out")))
                (invoke "make" "install"
                        (string-append "bindir=" out "/bin")
                        (string-append "pkglibdir=" out "/lib")
                        (string-append "sharedir=" out "/share")
                        (string-append "datadir=" out "/share")
                        (string-append "docdir=" out "/share/doc"))
                #t))))))
    (native-inputs
     (list flex pkg-config))
    (inputs
     (list postgresql-16
           curl
           json-c
           openssl
           zlib
           readline))
    (synopsis "Replication Manager for PostgreSQL clusters")
    (description "repmgr is an open-source tool suite for managing replication
and failover for PostgreSQL clusters.  It enhances PostgreSQL's built-in
replication with a standby register/clone/follow workflow, a witness server for
split-brain avoidance, and repmgrd for automatic failover.")
    (home-page "https://repmgr.org/")
    (license license:bsd-2)))

(define-public repmgr-static
  ;; Fully static repmgr/repmgrd binaries: runs on any x86-64 Linux host
  ;; regardless of its libc or system libraries.
  ;;
  ;; Why not just `(static-package repmgr)`: `static-package` appends
  ;; `LDFLAGS=-static` to configure-flags, but PGXS takes LDFLAGS from
  ;; `pg_config --ldflags` and links the executables with its own rule, so that
  ;; flag never reaches the linker — a plain `static-package repmgr` comes out
  ;; dynamically linked. And forcing global LDFLAGS=-static breaks repmgr.so
  ;; (a PG extension must be shared; -static + -shared => relocation error).
  (package
    (inherit (static-package repmgr))
    (name "repmgr-static")
    (arguments
     (substitute-keyword-arguments (package-arguments (static-package repmgr))
       ((#:phases phases)
        #~(modify-phases #$phases
            (replace 'build
              (lambda* (#:key inputs #:allow-other-keys)
                ;; LDFLAGS_EX is used ONLY by the repmgr/repmgrd executable
                ;; link rules, so -static there static-links the binaries.
                ;; LDFLAGS and SHLIB_LINK stay default so repmgr.so remains a
                ;; shared object.
                (invoke "make" "-j" (number->string (parallel-job-count))
                        "LDFLAGS_EX=-static")))
            (replace 'install
              (lambda* (#:key outputs #:allow-other-keys)
                (let ((out (assoc-ref outputs "out")))
                  (invoke "make" "install"
                          "LDFLAGS_EX=-static"
                          (string-append "bindir=" out "/bin")
                          (string-append "pkglibdir=" out "/lib")
                          (string-append "sharedir=" out "/share")
                          (string-append "datadir=" out "/share")
                          (string-append "docdir=" out "/share/doc"))
                  #t)))))))
    ;; Static link needs every `.a` on the path. guix's curl has no libcurl.a,
    ;; so swap it for curl-static; add the `static` outputs of zlib and openssl
    ;; (libz.a, libssl.a, libcrypto.a). readline/json-c/postgresql already ship
    ;; their `.a` in the default output.
    (inputs
     (append
      (filter (lambda (i) (not (string=? (car i) "curl")))
              (package-inputs (static-package repmgr)))
      (list (list "curl" curl-static)
            (list "zlib" zlib "static")
            (list "openssl" openssl "static"))))
    (synopsis "Statically-linked repmgr (self-contained binary)")
    (description "A fully statically-linked build of the repmgr and repmgrd
executables, with zero shared-library dependencies, so the binary runs on any
x86-64 Linux host independent of that host's libc or system packages.  The
repmgr.so PostgreSQL extension is still built shared, as a static extension is
impossible.")))
