;; [[file:../../project-maria/blog/dotemacs.org::*Package Configuration][Package Configuration:1]]
;; -*- no-byte-compile: t; -*-
;;; $DOOMDIR/packages.el

(package! evil-snipe :disable t)
(package! mu4e-alert :disable t)
(package! ef-themes)
(package! consult-mu
  :recipe (:host github :repo "armindarvish/consult-mu" :files (:defaults "extras/*.el")))
(package! ement)
(package! org-node)
(package! org-contacts)
(package! anki-editor)
(package! org-transclusion)
(package! transmission)
(package! lexic)
(package! casual)
(package! biome)
(package! webfeeder)
(package! casual)
(package! claude-code-ide
  :recipe (:host github :repo "manzaltu/claude-code-ide.el"))
(package! sly-quicklisp :disable t)
(package! ghostel)
(package! evil-ghostel)
;; Rebuild pdf-tools' epdfinfo server with CPU-native optimizations
;; (-O2 -march=native), per https://github.com/vedang/pdf-tools/discussions/351.
;; Doom otherwise builds epdfinfo lazily via `pdf-tools-install' without these
;; flags. This :post-build runs after every straight build/update of pdf-tools:
;; it compiles the C server and installs it into the version-stamped build dir
;; where `pdf-info-epdfinfo-program' looks, so the runtime build is skipped.
;; `-D' skips dependency install (already satisfied). Failures are non-fatal
;; (call-process doesn't signal), falling back to the lazy runtime build; see
;; the *pdf-tools-epdfinfo-build* buffer for output.
(package! pdf-tools
  :recipe (:post-build
           (when (eq system-type 'gnu/linux)
             ;; :post-build runs in the repo dir; build dir is resolved via
             ;; straight so we never hardcode the "build-NN.N" version segment.
             (let ((default-directory (expand-file-name "server/" default-directory)))
               (call-process
                "sh" nil (get-buffer-create "*pdf-tools-epdfinfo-build*") t "-c"
                (format "CFLAGS='-O2 -march=native' ./autobuild -i %s -D"
                        (shell-quote-argument
                         (directory-file-name (straight--build-dir "pdf-tools")))))))))
;; (package! mu4e-send-delay
;;   :recipe (:host github :repo "krisbalintona/mu4e-send-delay"))
;; (package! greader)
;; (package! literate-calc-mode)
;; (package! listen)
;; (package! org-fragtog)
;; Have my own version of this?
;; org-analyzer
;; Package Configuration:1 ends here
