;; SPDX-License-Identifier: MPL-2.0
;; channels.scm — the Guix revision this repository's guix.scm and manifest.scm
;; were verified against. Reproduce that exact Guix with:
;;
;;   guix time-machine -C channels.scm -- shell -m manifest.scm
;;
;; Refresh it (after re-verifying) with: just toolchain-refresh
;; Canon pin, verified 2026-09-30 (docker.io/metacall/guix, guix describe).
;;
;; Two channels, each pinned to a 40-hex commit and each authenticated by an
;; introduction (PROVISIONING-STANDARD §4):
;;  - guix:   upstream Guix. toolchain-refresh re-pins it per repository.
;;  - estate: https://github.com/hyperpolymath/guix-channel, module
;;            (estate packages idris), which supplies idris2 0.7.0 (Guix has none).
;;            Its pin is canon-controlled: toolchain-refresh never moves it. It
;;            changes only when this canon file changes (owner decision 2026-11-25).
;;            The pin is the channel head when minted; the introduction stays 4b91d37.
;;            When the channel grows, move the pin deliberately and re-run
;;            `guix git authenticate` against the introduction below.
;;            Tested on Guix 1.4.0 only, NOT against the guix pin above; not
;;            bit-reproducible.
(list (channel
       (name 'guix)
       (url "https://codeberg.org/guix/guix.git")
       (branch "master")
       (commit "ae77aeb9543de2661d739104bc4d3803d8c6f38b")
       (introduction
        (make-channel-introduction
         "9edb3f66fd807b096b48283debdcddccfea34bad"
         (openpgp-fingerprint
          "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA"))))
      (channel
       (name 'estate)
       (url "https://github.com/hyperpolymath/guix-channel.git")
       (branch "main")
       (commit "d4c84bde7a728a4a5bbc6bf865ed45e983d01c6d")
       (introduction
        (make-channel-introduction
         "4b91d37a4bbb4bc8c16de791eb5bd2241fb26f4b"
         (openpgp-fingerprint
          "E0B3 6C1B 28F6 E9E0 A460  3F47 FE6E 34E9 F311 0F92")))))
