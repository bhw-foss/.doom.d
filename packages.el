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
;; (package! mu4e-send-delay
;;   :recipe (:host github :repo "krisbalintona/mu4e-send-delay"))
;; (package! greader)
;; (package! literate-calc-mode)
;; (package! listen)
;; (package! org-fragtog)
;; Have my own version of this?
;; org-analyzer
;; Package Configuration:1 ends here
