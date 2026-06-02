;; [[file:../../project-maria/dotemacs.org::*Emacs Initialization][Emacs Initialization:1]]
;;; init.el -*- lexical-binding: t; -*-
(setf evil-respect-visual-line-mode t)
(doom!
 :completion
 (corfu +orderless)
 vertico

 :ui
 doom
 dashboard
 hl-todo
 (modeline +light)
 (popup +defaults)
 (window-select +numbers)
 workspaces

 :editor
 (evil +everywhere)
 fold
 (format +onsave)
 lispy
 multiple-cursors
 snippets
 (whitespace +guess +trim)
 word-wrap

 :emacs
 (dired +dirvish)
 electric
 eww
 tramp
 undo
 vc

 :checkers
 syntax
 (spell +hunspell)

 :tools
 biblio
 (eval +overlay)
 lookup
 (magit +forge)
 pdf

 :lang
 common-lisp
 data
 emacs-lisp
 json
 (latex +cdlatex)
 ledger
 markdown
 (org +noter +pandoc +contacts)
 plantuml
 graphviz
 sh

 :email
 (mu4e +org +mbsync)

 :app
 (rss +org +youtube)

 :config
 (default +bindings +smartparens))
;; Emacs Initialization:1 ends here
