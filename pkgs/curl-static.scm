;;; pg-repmgr-builds — static libcurl, a build dependency of repmgr-static.
;;;
;;; Why this exists: guix's `curl` package builds only `libcurl.so`
;;; (`--disable-static`), so a fully static repmgr link fails with
;;; `ld: cannot find -lcurl`. repmgr hard-requires libcurl (used by its backup
;;; and standby-clone HTTP paths) and provides no `--without-curl`, so a static
;;; repmgr binary needs a static libcurl.
;;;
;;; This is deliberately cut down so the static dependency closure collapses to
;;; openssl + zlib, both of which guix ships as `-static` outputs (libssl.a,
;;; libcrypto.a, libz.a):
;;;
;;;   --with-openssl      reuse the static openssl instead of pulling gnutls
;;;   --without-libidn2   avoid a transitive dep with no static archive
;;;   --without-libpsl    drop libpsl (not required by repmgr)
;;;   --without-nghttp2   drop HTTP/2 (nghttp2 ships no static archive)
;;;   --disable-gssapi    drop the krb5/gssapi cascade
;;;   --disable-ldap / --disable-rtsp  trim unused protocols
;;;   --disable-shared / --enable-static  produce libcurl.a, no .so

(define-module (pg-repmgr-builds curl-static)
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module (guix build-system gnu)
  #:use-module (guix gexp)                    ; #~ gexp literals in arguments
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (gnu packages curl)            ; curl (for the source origin)
  #:use-module (gnu packages tls)             ; openssl (static output)
  #:use-module (gnu packages compression)     ; zlib (static output)
  #:use-module (gnu packages pkg-config)
  #:use-module (gnu packages perl)
  #:use-module (gnu packages python))

(define-public curl-static
  (package
    (inherit curl)
    (name "curl-static")
    ;; Keep guix's own curl source (same tarball + its official patches).
    (source (package-source curl))
    (outputs '("out"))
    (arguments
     (list
      #:tests? #f                              ; static-link tests are slow & flaky
      #:configure-flags
      #~(list "--disable-shared"
              "--enable-static"
              "--with-openssl"
              "--without-libidn2"
              "--without-libpsl"
              "--without-nghttp2"
              "--disable-gssapi"
              "--disable-ldap"
              "--disable-ldaps"
              "--disable-rtsp"
              "--without-zsh-functions"
              "--without-brotli"
              "--without-zstd")
      #:phases
      #~(modify-phases %standard-phases
          (add-after 'install 'sanitize-libcurl.pc
            (lambda* (#:key outputs #:allow-other-keys)
              (let ((pc (string-append (assoc-ref outputs "out")
                                       "/lib/pkgconfig/libcurl.pc")))
                (when (file-exists? pc)
                  (substitute* pc
                    (("^Requires.private:.*") "")))
                #t))))))
    ;; openssl contributes BOTH its default output (headers, needed by
    ;; configure: openssl/ssl.h) and its `static` output (libssl.a/libcrypto.a).
    ;; listing openssl plainly + (list openssl "static") gives both.
    (native-inputs
     (list pkg-config perl python-wrapper))
    (inputs
     (list openssl
           (list openssl "static")
           (list zlib "static")))
    (synopsis "Static libcurl (for the static repmgr build)")
    (description "A statically-linked libcurl, cut down to an openssl+zlib
closure so a static repmgr can link libcurl.a without dragging gnutls, krb5,
libidn or nghttp2 into the static closure.")
    (license (license:non-copyleft "file://COPYING"
                                   "See COPYING in the distribution."))))
