;;; pg-repmgr-builds — musl-static versions of repmgr's link closure.
;;;
;;; WHY: a musl-static executable cannot link a glibc .a archive. Every
;;; static-link dependency of repmgr must be REBUILT with musl-gcc. guix has no
;;; musl substitutes (its cache is glibc-only), so each builds from source with
;;; `CC = <musl>/bin/musl-gcc`. guix's musl package ships the gcc wrapper
;;; (`--enable-wrapper=all`), so no cross-toolchain is needed.
;;;
;;; The pattern (validated on libpq — see repmgr-musl.scm header):
;;;   * set CC to musl-gcc in a configure-time phase
;;;   * for PostgreSQL specifically: build ONLY `all-static-lib` (produces
;;;     libpq.a and skips libpq.so — the .so link fails on `ld: -lgcc_s` under
;;;     musl-gcc, and we only need the .a)
;;;   * most autotools libs work with `--disable-shared --enable-static` + CC
;;;
;;; SCOPE (cut to repmgr's actual link line, PG_LDFLAGS=-lcurl -ljson-c plus
;;; libpq): libpq, curl (openssl backend, no nghttp2/idn/psl to keep the closure
;;; on musl-openssl+zlib), json-c, openssl, zlib.

(define-module (pg-repmgr-builds musl-closure)
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module (guix build-system gnu)
  #:use-module (guix gexp)
  #:use-module (gnu packages readline)
  #:use-module (gnu packages ncurses)       ; ncurses (static termcap for readline)
  #:use-module (guix utils)
  #:use-module (guix build utils)             ; find-files/dirname in gexp phases
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (gnu packages musl)
  #:use-module (gnu packages gcc)            ; gcc (lib output = libgcc.a)
  #:use-module (gnu packages compression)     ; zlib
  #:use-module (gnu packages tls)             ; openssl
  #:use-module (gnu packages web)             ; json-c
  #:use-module (gnu packages curl)            ; curl (source origin)
  #:use-module (gnu packages databases)       ; postgresql-16 (source origin)
  #:use-module (gnu packages pkg-config)
  #:use-module (gnu packages bison)          ; bison (libpq native-input)
  #:use-module (gnu packages flex)            ; flex (libpq native-input)
  #:use-module (gnu packages perl)
  #:use-module (gnu packages python))

;; Shared helper: rewrite CC to musl-gcc before configure, and put gcc's `lib`
;; output (libgcc.a) on LIBRARY_PATH. guix's musl-gcc specs only search musl/lib
;; for libgcc (which has none), so any NON-static link (cmake compiler probes,
;; autotools link tests) fails on `-lgcc`. Injecting gcc-lib fixes the probes;
;; the final artifact is still `-static` (musl-gcc %{static:-static} picks
;; libgcc.a). Used by every recipe via `set-musl-cc` phase injection.
(define (set-musl-cc-phase)
  #~(lambda* (#:key inputs #:allow-other-keys)
      (setenv "CC" (string-append (assoc-ref inputs "musl") "/bin/musl-gcc"))
      ;; Inject gcc's `lib` output (libgcc.a) on LIBRARY_PATH: musl-gcc's specs
      ;; (*link_libgcc) only search musl/lib for libgcc, which has none — so any
      ;; link resolves `-lgcc` against nothing. This was promised in the header
      ;; comment above but never implemented; without it musl-curl's libtool
      ;; program link fails `ld: cannot find -lgcc_s`. Proven on host: with
      ;; LIBRARY_PATH set, `musl-gcc -static` links cleanly (exit 0).
      (setenv "LIBRARY_PATH"
              (string-append (assoc-ref inputs "gcc")
                             "/lib/gcc/x86_64-unknown-linux-gnu/14.3.0"))
      ;; Force -static globally: musl-gcc's %{static:-static} picks libgcc.a
      ;; and skips the shared runtime (-lgcc_s), which guix's musl does not ship.
      ;; Without this, any NON-static link (cmake compiler probes, autotools link
      ;; tests) fails on `ld: cannot find -lgcc_s`. cmake/autotools both honor
      ;; LDFLAGS for their configure-time probes AND the final link, so every
      ;; link becomes static — which is exactly what we want for these .a libs.
      (setenv "LDFLAGS" "-static")))

;; gcc's `lib` output — supplies libgcc.a/libgcc_eh.a for musl-gcc's *link_libgcc
;; (musl/lib has none). Every musl package must list this in `inputs` so the
;; set-musl-cc-phase helper can put it on LIBRARY_PATH.
(define gcc-lib (list gcc "lib"))

;; ---------------------------------------------------------------------------
;; zlib — trivial C library; musl build is just CC + static.
;; ---------------------------------------------------------------------------
(define-public musl-zlib
  (package
    (inherit zlib)
    (name "musl-zlib")
    (outputs '("out"))
    ;; FRESH arguments — do NOT substitute-keyword on zlib's arguments: its
    ;; inherited phases embed gexps that declare extra outputs (the
    ;; move-static-library phase references the `static` output) which leak
    ;; into the derivation even if deleted. We build only libz.a + headers.
    ;; CC carries `-static` so ANY link the Makefile does (test programs
    ;; example/minigzip included) resolves libgcc_s -> libgcc.a under musl
    ;; instead of failing `ld: cannot find -lgcc_s`. No target-neutralising
    ;; phase needed. libz.a itself is produced by `ar` (no link).
    (arguments
     (list
      #:tests? #f
      #:phases
      #~(modify-phases %standard-phases
          (add-before 'configure 'set-musl-cc
            (lambda* (#:key inputs #:allow-other-keys)
              (setenv "CC" (string-append
                            (string-append (assoc-ref inputs "musl")
                                           "/bin/musl-gcc")
                            " -static"))))
          (replace 'configure
            (lambda* (#:key outputs #:allow-other-keys)
              ;; zlib's home-made configure (not autoconf): it rejects guix's
              ;; CONFIG_SHELL/--enable-fast-install args, so pass only prefix.
              (invoke "./configure" "--static"
                      (string-append "--prefix="
                                     (assoc-ref outputs "out")))))
          (add-after 'build 'install-musl
            (lambda* (#:key outputs #:allow-other-keys)
              (let ((out (assoc-ref outputs "out")))
                (mkdir-p (string-append out "/include"))
                (mkdir-p (string-append out "/lib"))
                (copy-file "zlib.h" (string-append out "/include/zlib.h"))
                (copy-file "zconf.h" (string-append out "/include/zconf.h"))
                (copy-file "libz.a" (string-append out "/lib/libz.a"))
                #t))))))
    (inputs (list musl gcc gcc-lib))
    (synopsis "zlib built against musl (static)")))

(define-public musl-readline
  (package
    (inherit readline)
    (name "musl-readline")
    (outputs '("out"))
    ;; Fresh arguments (like musl-zlib): readline's glibc recipe threads a
    ;; `-Wl,-rpath` LDFLAGS pointing at ncurses' .so and a loongarch config
    ;; phase — both glibc/shared-oriented. We only need libreadline.a (the
    ;; termcap/ncurses link is satisfied by the system termcap in the static
    ;; link, or we point at musl ncurses if required). `-static` in CC makes
    ;; any test-program link resolve -lgcc_s -> libgcc.a under musl.
    (arguments
     (list
      #:tests? #f
      #:configure-flags
      #~(list "--enable-static" "--disable-shared")
      #:phases
      #~(modify-phases %standard-phases
          (add-before 'configure 'set-musl-cc
            (lambda* (#:key inputs #:allow-other-keys)
              (setenv "CC" (string-append
                            (string-append (assoc-ref inputs "musl")
                                           "/bin/musl-gcc")
                            " -static")
              )))
          (add-after 'build 'install-musl
            (lambda* (#:key outputs #:allow-other-keys)
              (let ((out (assoc-ref outputs "out")))
                (mkdir-p (string-append out "/include"))
                (mkdir-p (string-append out "/lib"))
                ;; readline installs libreadline.a and headers under prefix
                (for-each
                 (lambda (f)
                   (when (file-exists? f)
                     (copy-file f (string-append out "/lib/" (basename f)))))
                 (find-files "libs" "\\.a$"))
                ;; headers
                (copy-file "readline.h" (string-append out "/include/readline.h"))
                (copy-file "history.h" (string-append out "/include/history.h"))
                #t))))))
    (inputs (list musl gcc gcc-lib ncurses))
    (synopsis "readline built against musl (static)")))

(define-public musl-openssl
  (package
    (inherit openssl)
    (name "musl-openssl")
    (outputs '("out"))
    ;; FRESH arguments — do NOT substitute-keyword on openssl's arguments:
    ;; its phases embed #$output:doc / #$output:static gexps that, once lowered,
    ;; declare doc/static outputs even if the phase is later deleted. We build
    ;; only libssl.a + libcrypto.a + headers into out (single output), so the
    ;; static link closure has one clean input.
    (arguments
     (list
      #:tests? #f
      #:phases
      #~(modify-phases %standard-phases
          (replace 'configure
            (lambda* (#:key inputs outputs #:allow-other-keys)
              (setenv "CC" (string-append (assoc-ref inputs "musl") "/bin/musl-gcc"))
              (setenv "LDFLAGS" "-static")
              (let ((out (assoc-ref outputs "out")))
                (substitute* "config"
                  (("/usr/bin/env") (which "env")))
                (setenv "HASHBANGPERL" (which "perl"))
                (invoke "./config"
                        "no-shared" "no-tests"
                        (string-append "--prefix=" out)
                        (string-append "--openssldir=" out "/ssl")
                        "--libdir=lib"))))
          (add-after 'build 'install-musl
            (lambda* (#:key outputs #:allow-other-keys)
              (let ((out (assoc-ref outputs "out")))
                (mkdir-p (string-append out "/include/openssl"))
                (mkdir-p (string-append out "/lib"))
                (copy-file "include/openssl/ssl.h"
                           (string-append out "/include/openssl/ssl.h"))
                (copy-file "libssl.a" (string-append out "/lib/libssl.a"))
                (copy-file "libcrypto.a" (string-append out "/lib/libcrypto.a"))
                #t))))))
    (native-inputs (list perl))
    (inputs (list musl gcc-lib))
    (synopsis "openssl built against musl (static)")))

;; json-c — small autotools; musl + static.
;; ---------------------------------------------------------------------------
(define-public musl-json-c
  (package
    (inherit json-c)
    (name "musl-json-c")
    (arguments
     (list
      #:tests? #f
      ;; json-c uses cmake-build-system (not autotools): BUILD_SHARED_LIBS=OFF
      ;; builds only the static libjson-c.a. The autotools flags
      ;; (--disable-shared) are unknown to cmake and error out.
      #:configure-flags
      #~'("-DBUILD_SHARED_LIBS=OFF")
      #:phases
      #~(modify-phases %standard-phases
          (add-before 'configure 'set-musl-cc
             (lambda* (#:key inputs #:allow-other-keys)
               (setenv "CC" (string-append (assoc-ref inputs "musl") "/bin/musl-gcc"))
               (setenv "LDFLAGS" "-static"))))))
    (inputs (list musl gcc gcc-lib))
    (synopsis "json-c built against musl (static)")))

;; ---------------------------------------------------------------------------
;; libpq — from PostgreSQL source; build ONLY all-static-lib (libpq.a), skip
;; libpq.so (its link fails on `-lgcc_s` under musl-gcc). This is the validated
;; spike recipe.
;; ---------------------------------------------------------------------------
(define-public musl-libpq
  (package
    (inherit postgresql-16)
    (name "musl-libpq")
    (arguments
     (list
      #:tests? #f
      #:phases
      #~(modify-phases %standard-phases
          (add-before 'configure 'set-musl-cc
            (lambda* (#:key inputs #:allow-other-keys)
              (setenv "CC" (string-append (assoc-ref inputs "musl")
                                          "/bin/musl-gcc"))))
          (replace 'configure
            (lambda* (#:key inputs outputs #:allow-other-keys)
              (let* ((out (assoc-ref outputs "out"))
                     (musl (assoc-ref inputs "musl"))
                     (musl-gcc (string-append musl "/bin/musl-gcc")))
                (invoke "chmod" "+x" "config/config.sub" "config/config.guess")
                (patch-shebang "config/config.sub")
                (patch-shebang "config/config.guess")
                (setenv "CONFIG_SHELL" (which "sh"))
                (invoke "./configure"
                        (string-append "--prefix=" out)
                        "--without-readline" "--without-zlib"
                        "--without-icu" "--without-openssl"
                        "--without-bonjour" "--without-ldap"
                        "--without-pam" "--without-perl"
                        "--without-python" "--without-tcl"
                        (string-append "CC=" musl-gcc)
                        "CFLAGS=-O2"
                        "LIBS=-static"))))
          (replace 'build
            (lambda _
              ;; libpq.a (skip libpq.so — its link fails on -lgcc_s under musl-gcc).
              (invoke "make" "-C" "src/interfaces/libpq" "all-static-lib")
              ;; repmgr's PGXS link line also needs -lpgcommon -lpgport
              ;; ($(libpq_pgport)); build them musl-static too so the final
              ;; repmgr link has NO glibc .a (glibc's carry __isoc23_* which
              ;; musl does not provide).
              (invoke "make" "-C" "src/common" "libpgcommon.a")
              (invoke "make" "-C" "src/port" "libpgport.a")))
          (replace 'install
            (lambda* (#:key inputs outputs #:allow-other-keys)
              (let ((out (assoc-ref outputs "out")))
                (mkdir-p (string-append out "/lib"))
                (copy-file "src/interfaces/libpq/libpq.a"
                           (string-append out "/lib/libpq.a"))
                ;; pgcommon/pgport — required by repmgr's link (-lpgcommon -lpgport)
                (copy-file "src/common/libpgcommon.a"
                           (string-append out "/lib/libpgcommon.a"))
                (copy-file "src/port/libpgport.a"
                           (string-append out "/lib/libpgport.a"))
                ;; headers needed to compile repmgr against libpq
                (mkdir-p (string-append out "/include"))
                (for-each
                 (lambda (h)
                   (copy-file h (string-append out "/include/"
                                               (basename h))))
                 (find-files "src/include" "^(libpq|pqexpbuffer|pg_service)"))
                ;; bin/pg_config wrapper — PGXS bakes `pg_config --libdir` into LDFLAGS at
                ;; configure time; pointing it at our lib dir makes -lpq/-lpgcommon/-lpgport
                ;; resolve to the musl .a above (0 __isoc23_* symbols) instead of glibc
                ;; postgresql-16's (9 symbols musl cannot supply). Every other field defers
                ;; to the real pg_config (headers/pgxs/version stay arch-correct).
                (let ((bin (string-append out "/bin"))
                      (real (string-append (assoc-ref inputs "postgresql") "/bin/pg_config")))
                  (mkdir-p bin)
                  (call-with-output-file (string-append bin "/pg_config")
                    (lambda (port)
                      (display "#!/bin/sh\n" port)
                      (display (string-append "REAL=\"" real "\"\n") port)
                      (display "case \"$1\" in\n" port)
                      (display (string-append "  --libdir|--pkglibdir) echo \""
                                              (string-append out "/lib")
                                              "\"; exit 0 ;;\n") port)
                      (display "esac\n" port)
                      (display "exec \"$REAL\" \"$@\"\n" port)))
                  (chmod (string-append bin "/pg_config") #o755))
                #t))))))
    (native-inputs (list bison flex))
    (inputs (list musl gcc gcc-lib postgresql-16))  ; postgresql-16 = real pg_config (deferred fields)
    (synopsis "libpq built against musl (static)")))

;; ---------------------------------------------------------------------------
;; curl — musl + static, openssl backend; closure collapses to musl-openssl +
;; musl-zlib (no nghttp2/idn2/psl/gssapi).
;; ---------------------------------------------------------------------------
(define-public musl-curl
  (package
    (inherit curl)
    (name "musl-curl")
    (outputs '("out"))
    (arguments
     (list
      #:tests? #f
      #:configure-flags
      #~'("--disable-shared" "--enable-static"
          "--with-openssl"
          "--without-libidn2" "--without-libpsl" "--without-nghttp2"
          "--disable-gssapi" "--disable-ldap" "--disable-ldaps"
          "--disable-rtsp" "--without-brotli" "--without-zstd"
          "--without-zsh-functions")
      #:phases
      #~(modify-phases %standard-phases
          (add-before 'configure 'set-musl-cc #$(set-musl-cc-phase))
          ;; curl's two programs (curlinfo, curl) are linked by libtool --mode=link,
          ;; which STRIPS every -static from its command (verified: libtool emits
          ;; `musl-gcc -o X` dropping -static), reverting to gcc's shared runtime
          ;; (-lgcc_s) that musl lacks -> `ld: cannot find -lgcc_s`. Passing
          ;; -Wc,-static instead makes libtool death-loop (13min CPU, no output).
          ;; So after `build` produces libcurl.a + the objects, hand-relink both
          ;; programs DIRECTLY with musl-gcc -static (bypassing libtool entirely),
          ;; with LIBRARY_PATH resolving libgcc.a. Proven on host: exit 0,
          ;; statically-linked. Objects for curlinfo are in src/, for curl in src/.
          ;; Default `make` recurses into src/ and links curlinfo + curl via
          ;; libtool --mode=link, which strips -static (-> `ld: cannot find
          ;; -lgcc_s`) and aborts the build before hand-relink can run. Build
          ;; ONLY the library here (make -C lib: libcurl.la/.a, no program
          ;; links); the two programs are linked by hand-relink below with
          ;; musl-gcc -static (proven on host).
          (replace 'build
            (lambda _
              ;; lib: libcurl.la/.a (must succeed)
              (invoke "make" "-C" "lib")
              ;; src: compile ALL tool objects; the curl/curlinfo links fail
              ;; (-lgcc under libtool's stripped -static) but -k keeps going so
              ;; every .o lands. hand-relink below links the programs directly.
              (system* "make" "-k" "-C" "src")  ;; tolerate link failure
              #t))
          (add-after 'build 'hand-relink-programs
            (lambda* (#:key inputs outputs #:allow-other-keys)
              ;; gexp builder: fresh module scope — import what we use (rule: guix-packaging #3)
              (use-modules (ice-9 textual-ports) (ice-9 popen) (ice-9 rdelim)
                           (srfi srfi-1) (ice-9 i18n))
              ;; libtool's $(LINK)/$(curl_LINK) strip -static (verified: emits
              ;; `musl-gcc -o X` without -static), reverting to gcc's shared
              ;; runtime (-lgcc_s) which musl lacks -> `ld: cannot find -lgcc_s`.
              ;; Overriding LINK/curl_LINK also fails (drops `-o $@`, passes the
              ;; `.la` to raw gcc). So link both programs DIRECTLY with musl-gcc
              ;; -static: append a `print-objs` target to Makefile to read curl's
              ;; own object list (44 .o), then link with the known LDADD
              ;; (libcurl.a, -lssl -lcrypto -lz). LIBRARY_PATH supplies libgcc.a
              ;; (musl/lib has none). Proven on host: both link, statically linked,
              ;; `curl --version` runs.
              (let* ((musl (assoc-ref inputs "musl"))
                     (gcc-lib (assoc-ref inputs "gcc"))
                     (zlib (assoc-ref inputs "musl-zlib"))
                     (openssl (assoc-ref inputs "musl-openssl"))
                     (musl-gcc (string-append musl "/bin/musl-gcc"))
                     (libgcc-dir (string-append gcc-lib
                                 "/lib/gcc/x86_64-unknown-linux-gnu/14.3.0"))
                     (zlib-lib (string-append zlib "/lib"))
                     (openssl-lib (string-append openssl "/lib")))
                (setenv "LIBRARY_PATH" libgcc-dir)
                ;; expose curl_OBJECTS via a throwaway target (Makefile backed up + restored)
                (with-directory-excursion "src"
                  (let ((makefile (call-with-input-file "Makefile" read-string)))
                    (call-with-output-file "Makefile.orig"
                      (lambda (port) (display makefile port)))
                    ;; insert BEFORE the trailing .NOEXPORT: block (a target appended
                    ;; after it yields `objs count: 0` — verified on host)
                    (let* ((marker "\n.NOEXPORT:")
                           (idx (string-contains makefile marker)))
                      (call-with-output-file "Makefile"
                        (lambda (port)
                          (if idx
                              (begin
                                (display (substring makefile 0 idx) port)
                                (newline port)
                                (display "print-objs:" port) (newline port)
                                (display "\t@echo $(curl_OBJECTS)" port) (newline port)
                                (display (substring makefile idx) port))
                              (begin
                                (display makefile port)
                                (newline port)
                                (display "print-objs:" port) (newline port)
                                (display "\t@echo $(curl_OBJECTS)" port) (newline port))))))
                    (let* ((p (open-input-pipe "make -s print-objs"))
                           (out (read-string p)))
                      (close-pipe p)
                      ;; restore the original Makefile immediately
                      (call-with-output-file "Makefile"
                        (lambda (port) (display makefile port)))
                      (let ((objs (filter (lambda (f)
                                            (and (not (string-null? f))
                                                 (string-suffix? ".o" f)))
                                          (string-split out #\space))))
                        (setenv "LIBRARY_PATH" libgcc-dir)
                        ;; curl: all tool objects + libcurl + deps
                        (apply invoke musl-gcc
                               (append (list "-static" "-O2"
                                             "-L" zlib-lib "-L" openssl-lib)
                                       (list "-o" "curl")
                                       objs
                                       (list "../lib/.libs/libcurl.a"
                                             "-lz" "-lssl" "-lcrypto")))
                        ;; curlinfo: single object, same libs
                        (apply invoke musl-gcc
                               (append (list "-static" "-O2"
                                             "-L" zlib-lib "-L" openssl-lib)
                                       (list "-o" "curlinfo" "curlinfo.o"
                                             "../lib/.libs/libcurl.a"
                                             "-lz" "-lssl" "-lcrypto"))))))))
                #t)))))
    (native-inputs (list pkg-config perl python-wrapper))
    ;; openssl/zlib ship their .a in the `static` output — reference it so
    ;; curl's configure finds libssl.a/libz.a.
    (inputs (list musl gcc gcc-lib musl-openssl musl-zlib))
    (synopsis "curl built against musl (static)")))
