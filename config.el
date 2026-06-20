;; [[file:../../project-maria/blog/dotemacs.org::*Emacs Configuration][Emacs Configuration:1]]
;;; $DOOMDIR/config.el -*- lexical-binding: t; -*-
;;---------------------------------------------------------------------------
;; PATH for daemon sessions: Emacs runs as a systemd --user daemon, which does
;; NOT source ~/.profile or ~/.bashrc, so user bin dirs (e.g. ~/.local/bin,
;; where the `claude' CLI lives) are absent from PATH/`exec-path'. Prepend them
;; here so `executable-find' and spawned subprocesses (claude-code-ide, etc.)
;; can locate these executables.
(dolist (dir (list (expand-file-name "~/.local/bin")
                   (expand-file-name "~/.config/emacs/bin")))
  (when (and (file-directory-p dir)
             (not (member dir exec-path)))
    (add-to-list 'exec-path dir)
    (setenv "PATH" (concat dir path-separator (getenv "PATH")))))

(defconst +project-maria-dir+ (expand-file-name "~/project-maria/")
  "Absolute path to the project-maria directory.")
(defconst +project-jerome-dir+ (expand-file-name "~/project-jerome/")
  "Absolute path to the project-jerome directory.")

;; might have to install xprop and wmctrl. See fullscreen.sh
(add-to-list 'initial-frame-alist '(fullscreen . fullboth))
(add-to-list 'default-frame-alist '(fullscreen . fullboth))

(defun get-authinfo-password (machine login)
  (if-let* ((credential (car (auth-source-search :max 1
                                                 :host machine
                                                 :user login
                                                 :require '(:secret))))
            (secret (plist-get credential :secret)))
      (if (functionp secret) (funcall secret) secret)
    (message "No password found for %s@%s" login machine)))

(load! "private-packages/personal-info.el")

(defun site/always-save-advice (oldfn &optional arg)
  "Overwrite `yes-or-no-p' in OLDFN.
    The new temporary function will return non-nil, when the message
    wants to save modified buffers, without querying the user.
    Otherwise the original behaviour is preserves, and ARG is passed
    on to OLDFN."
  (cl-letf* ((real-yes-or-no-p (symbol-function 'yes-or-no-p))
             ((symbol-function 'yes-or-no-p)
              (lambda (msg)
                (or (string= msg "Modified buffers exist; exit anyway? ")
                    (funcall real-yes-or-no-p msg)))))
    (funcall oldfn arg)))

(advice-add #'save-buffers-kill-emacs :around #'site/always-save-advice)

(setf org-directory +project-maria-dir+
      auto-save-interval 300
      auto-revert-interval 30
      auto-save-timeout nil
      browse-url-generic-program  "/mnt/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"
      browse-url-browser-function #'browse-url-generic
      initial-major-mode 'org-mode)
(transient-mark-mode 1)
;; Emacs Configuration:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Completion Module Config][Completion Module Config:1]]
;;---------------------------------------------------------------------------
(after! vertico
  (map! :map vertico-map
        "C-d" #'vertico-quick-jump))

(setq completion-ignore-case t
      read-file-name-completion-ignore-case t
      read-buffer-completion-ignore-case t)

(map! :n ";" #'consult-line
      :leader "SPC" #'consult-buffer)
;; Completion Module Config:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Consult Config][Consult Config:1]]
;;---------------------------------------------------------------------------
(after! consult
  (require 'org-node)

  (defvar bhw/consult-source-filesystem
    `(:name     "Find"
      :narrow   ?f
      :category file
      :face     consult-file
      :history  file-name-history
      :action   ,#'consult--file-action
      :state    ,#'consult--file-preview
      ;; Async: `fd' filters by the typed input, so nothing is materialized
      ;; until you type >= `consult-async-min-input' (default 3) chars. `fd'
      ;; still honors the global ignore file (~/.config/fd/ignore), so Trash
      ;; etc. stay excluded. The `let' bakes our flags into the builder closure
      ;; WITHOUT mutating the global `consult-fd-args' (so plain `M-x
      ;; consult-fd' is unaffected). `--search-path' yields absolute paths;
      ;; `abbreviate-file-name' restores the ~/ display of the old source.
      :async
      ,(let ((consult-fd-args
              '((if (executable-find "fdfind" 'remote) "fdfind" "fd")
                "--full-path --color=never --hidden --follow --type f --exclude .git")))
         (consult--process-collection
             (consult--fd-make-builder (list (expand-file-name "~")))
           :transform (consult--async-map #'abbreviate-file-name)
           :highlight t
           :file-handler t))))

  (defvar bhw/consult-source-project-maria
    `(:name     "Project-Maria rg"
      :narrow   ?m
      :category consult-grep
      :history  consult--grep-history
      :state    ,#'consult--grep-state
      :action   ,(lambda (c) (consult--jump (consult--grep-position c)))
      :async
      ,(let ((builder (consult--ripgrep-make-builder (list +project-maria-dir+))))
         (consult--process-collection builder
           :transform (consult--grep-format builder)
           :file-handler t))))

  ;; `mapatoms' over the full obarray (~128k symbols) building ~13k command-name
  ;; strings costs ~85ms and triggers GC on EVERY consult-buffer open.  The
  ;; command set is effectively static between `load's, so cache the list and
  ;; invalidate it only when new code is loaded (rare after startup) via a
  ;; *named* `after-load-functions' hook (named so `doom/reload' re-adds it
  ;; idempotently instead of leaking duplicate anonymous closures).
  (defvar bhw/consult--emacs-commands-cache nil
    "Cached list of command-name strings for `bhw/consult-source-emacs-commands'.")

  (defun bhw/consult--emacs-commands ()
    "Return all command names as strings, rebuilding the cache on demand."
    (or bhw/consult--emacs-commands-cache
        (setq bhw/consult--emacs-commands-cache
              (let (cmds)
                (mapatoms (lambda (s) (when (commandp s) (push (symbol-name s) cmds))))
                cmds))))

  (defun bhw/consult--invalidate-emacs-commands-cache (&rest _)
    "Drop the cached Emacs-commands list so it is rebuilt after new code loads."
    (setq bhw/consult--emacs-commands-cache nil))
  (add-hook 'after-load-functions #'bhw/consult--invalidate-emacs-commands-cache)

  (defvar bhw/consult-source-emacs-commands
    (list :name     "Emacs Commands"
          :narrow   ?e
          :category 'command
          :items    #'bhw/consult--emacs-commands
          :action   (lambda (cmd-str) (command-execute (intern-soft cmd-str))))
    "Source for Emacs commands, used in `consult-buffer'.")

  (defvar org-node-history nil
    "History list for org-node selections in `consult-buffer'. The `:history 'org-node-history` property in `bhw/consult-source-org-node` tells `consult` to record selections into the variable `org-node-history`. But that variable was never declared with `defvar`, so it was void. When `consult--multi` tried to call `(add-to-history org-node-history \"Ecclesiastes 3:1\")`, Emacs raised a `void-variable` error.")

  (defvar bhw/consult-source-org-node
    (list :name     "Org Node"
          :narrow   ?n
          :category 'org-node
          :face     'consult-file
          :history  'org-node-history
          :items    (lambda ()
                      (org-node-cache-ensure)
                      (hash-table-keys org-node--candidate<>entry))
          :action   (lambda (cand)
                      (require 'org-id)
                      (let ((node (gethash cand org-node--candidate<>entry)))
                        (if node
                            (org-node-goto node)
                          ;; Fallback if the user somehow selects a non-existent item
                          ;; though :new usually handles creation
                          (org-node-create cand (org-id-new)))))
          :new      (lambda (cand)
                      (require 'org-id)
                      ;; Handle blank input for creation specifically
                      (let ((title (if (string-blank-p cand)
                                       (funcall org-node-blank-input-title-generator)
                                     cand)))
                        (org-node-create title (org-id-new)))))
    "Source for `org-node' to be used in `consult-buffer'.")

  (setf consult-buffer-sources '(consult-source-buffer
                                 bhw/consult-source-org-node
                                 bhw/consult-source-project-maria
                                 bhw/consult-source-filesystem
                                 bhw/consult-source-emacs-commands))

  ;; Perl split routes plain input to the async source only, leaving sync sources unfiltered.
  (advice-add 'consult-buffer :around
              (lambda (orig &rest args)
                (let ((consult-async-split-style 'none))
                  (apply orig args)))))
;; Consult Config:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*User Interface Config][User Interface Config:1]]
;;---------------------------------------------------------------------------
(dotimes (i 10)
  (define-key doom-leader-map (number-to-string i)
              (intern (format "winum-select-window-%s"
                              (if (= i 0) "0-or-10" (number-to-string i))))))

(setf doom-font (font-spec :family "IosevkaTermSlab Nerd Font" :size 26.0 :weight 'semi-light)
      doom-theme 'ef-owl
      doom-modeline-height 14
      display-line-numbers-type nil
      confirm-kill-emacs nil
      confirm-kill-processes nil)

;; Doom core remaps `delete-frame' to `doom/delete-frame-with-prompt', which
;; asks "Close frame?" before closing.  Undo that remap so closing a frame
;; (SPC q f, C-x 5 0) is immediate.  The remap is installed in doom-emacs.el,
;; already loaded by the time config.el runs, so this needs no `after!' guard
;; (the old `after! doom-ui' wrapper never fired -- doom-ui isn't a feature).
(global-set-key [remap delete-frame] nil)

(add-to-list 'default-frame-alist '(inhibit-double-buffering . t))

(after! nerd-icons
  (setf nerd-icons-font-family "IosevkaTermSlab Nerd Font"))

(dolist (fn '(+dashboard-widget-banner
              +dashboard-widget-loaded
              +dashboard-widget-footer))
  (remove-hook '+dashboard-functions fn))
;; User Interface Config:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Smooth Scrolling Config][Smooth Scrolling Config:1]]
;;---------------------------------------------------------------------------
;; Pixel-level smooth scrolling for the mouse wheel / trackpad (Emacs 29+,
;; native — no external package).
;;
;; Tuned to prioritize trackpad responsiveness over smoothness (keeping both
;; where they don't conflict). Interpolation/momentum add perceptible lag under
;; WSLg, where trackpad gestures arrive as discrete X11 wheel events:
;;   - no momentum -> scrolling stops the instant you lift; no kinetic drift.
;;   - no mouse interpolation -> each wheel notch scrolls immediately instead of
;;     animating over `...-interpolation-total-time'; genuine pixel-precision
;;     deltas (if the device sends them) are still scrolled smoothly.
;;   - no progressive speed -> scroll distance stays proportional, no overshoot.
;; `interpolate-page' stays on: it smooths keyboard `scroll-up/down-command'
;; (C-v / M-v, evil C-f / C-b), which never touches the trackpad path.
(pixel-scroll-precision-mode 1)
(setf pixel-scroll-precision-use-momentum nil
      pixel-scroll-precision-interpolate-mice nil
      pixel-scroll-precision-interpolate-page t
      mouse-wheel-progressive-speed nil)

;; Keyboard-driven scrolling: keep point off the window edge and scroll one
;; line at a time instead of recentering with a jump.
(setf scroll-margin 3
      scroll-conservatively 101
      scroll-preserve-screen-position t
      auto-window-vscroll nil)
;; Smooth Scrolling Config:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Modus Flexoki Config][Modus Flexoki Config:1]]
(use-package! modus-flexoki
  :defer t)
;; Modus Flexoki Config:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Editor Config][Editor Config:1]]
;;---------------------------------------------------------------------------
(+global-word-wrap-mode +1)
(dolist (pair '(([?\(] . [?\[]) ([?\[] . [?\(])
                ([?\)] . [?\]]) ([?\]] . [?\)])))
  (define-key key-translation-map (car pair) (cdr pair)))
;; Bind `s` in both motion and normal state maps for avy.  Normal state
;; needs an explicit binding so modes with `s` as a prefix (e.g. dirvish)
;; can still override it locally.
(dolist (m (list evil-motion-state-map evil-normal-state-map))
  (define-key m (kbd "s") 'avy-goto-word-or-subword-1))
(define-key evil-normal-state-map (kbd "q") 'kill-current-buffer)

(map! :n
      ","   nil ; See `doom-localleader-key' below
      "C-j" #'+evil/insert-newline-below
      "C-k" #'+evil/insert-newline-above)
(setf doom-localleader-key ","
      avy-all-windows t
      +word-wrap-extra-indent nil)
;; Editor Config:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Emacs Config][Emacs Config:1]]
;;---------------------------------------------------------------------------
;; Re-apply Doom's gcmh tuning that its 2026-06-13 core refactor silently
;; dropped: it registers gcmh via `use-package! gcmh-mode', but the package
;; provides the feature `gcmh' (not `gcmh-mode'), so the :config form that sets
;; `gcmh-high-cons-threshold' to 64mb never runs.  gcmh then keeps its 1GB
;; upstream default, letting the Lisp heap balloon until every GC is a ~1.3s
;; freeze that surfaces as GUI input lag.  Keyed on the correct feature; drop
;; this once Doom fixes the `use-package!' declaration upstream.
;;
;; Deviations from Doom's defaults, tuned for long-lived (multi-day) sessions
;; where each full GC measures ~0.5-0.7s: raise the active threshold to 256mb
;; so heavy scrolling rarely trips a collection mid-motion, and use a fixed 15s
;; idle delay (instead of `auto', which fired ~5s after every pause) so the
;; unavoidable freeze lands when genuinely idle rather than between keystrokes.
;; NOTE: this only changes GC *timing/frequency*; per-GC duration scales with
;; heap size, so a periodic Emacs restart remains the real fix for the lag.
(after! gcmh
  (setq gcmh-idle-delay 15
        gcmh-high-cons-threshold (* 256 1024 1024))) ; 256mb
;; Emacs Config:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Dired Config][Dired Config:1]]
;;---------------------------------------------------------------------------
(map! :after dirvish                    ; Doom overrides Dired with Dirvish.
      :map dirvish-mode-map
      :n ";" #'consult-line
      :n "A" #'fuco/org-attach-visit-headline-from-dired)

;; Doom's dired module binds `s` as a prefix (ss/sS/sh → symlink ops) in
;; dirvish-mode-map's normal-state auxiliary keymap.  evil-local-set-key
;; sets a buffer-local binding that has higher priority, so pressing `s`
;; in dired gives avy instead of waiting for a second key.
(add-hook 'dired-mode-hook
          (lambda ()
            (evil-local-set-key 'normal (kbd "s") #'avy-goto-word-or-subword-1)
            (evil-local-set-key 'normal (kbd "e") #'wdired-change-to-wdired-mode)))
;; Dired Config:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*EWW Config][EWW Config:1]]
;;---------------------------------------------------------------------------
(after! eww
  (add-hook! 'eww-after-render-hook #'eww-readable)
  (map! :map eww-mode-map
        :n "Y" #'+org/yank-link))
;; EWW Config:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Term Config][Term Config:1]]
;;---------------------------------------------------------------------------
;; Project/workspace-scoped popup terminal, ported from Doom's :term vterm
;; module (+vterm/toggle, +vterm/here) and this config's vterm keybindings.
(defun +ghostel--configure-project-root-and-display (arg display-fn)
  "Set PROOT and display a ghostel terminal via DISPLAY-FN.
With prefix ARG non-nil, root at `default-directory' instead of project root."
  (let* ((project-root (or (doom-project-root) default-directory))
         (default-directory (if arg default-directory project-root)))
    (setenv "PROOT" project-root)
    (funcall display-fn)))

(defun +ghostel/toggle (arg)
  "Toggle a project-root ghostel terminal popup (persp-scoped).
With prefix ARG, recreate the buffer rooted at the current project."
  (interactive "P")
  (+ghostel--configure-project-root-and-display
   arg
   (lambda ()
     (let* ((bname (format "*doom:ghostel-popup:%s*"
                           (if (bound-and-true-p persp-mode)
                               (safe-persp-name (get-current-persp))
                             "main")))
            (ghostel-buffer-name bname))   ; ghostel keys identity off this var
       (when arg
         (when-let* ((buf (get-buffer bname))) (kill-buffer buf))
         (when-let* ((win (get-buffer-window bname))) (delete-window win)))
       (if-let* ((win (get-buffer-window bname)))
           (delete-window win)             ; visible -> hide
         (ghostel))))))                    ; else create/switch; popup rule places it

(defun +ghostel/here (arg)
  "Open a ghostel terminal in the current window at project root.
With prefix ARG, root at `default-directory' instead."
  (interactive "P")
  (+ghostel--configure-project-root-and-display
   arg
   (lambda ()
     (let (display-buffer-alist)           ; bypass popup rules -> current window
       (ghostel)))))

(use-package! ghostel
  :commands (ghostel ghostel-project +ghostel/toggle +ghostel/here)
  :hook ((ghostel-mode . mode-line-invisible-mode)      ; modeline useless in a term
         (ghostel-mode . doom-disable-line-numbers-h))
  :init
  (map! :leader
        :desc "Toggle ghostel popup" "ot" #'+ghostel/toggle
        :desc "Open ghostel here"    "oT" #'+ghostel/here)
  :config
  (set-popup-rule! "^\\*doom:ghostel-popup:"
    :size 0.25 :vslot -4 :select t :quit nil :ttl 0)
  (setq ghostel-module-auto-install 'download   ; prebuilt binary, no toolchain
        ;; Keep the native module outside straight's tree so `doom sync'/upgrades
        ;; don't delete it and force a re-download (cf. vterm's elpa-dir caveat).
        ghostel-module-directory (expand-file-name "ghostel/" doom-data-dir)
        ;; Stable buffer names (no OSC-title renaming) so the popup rule + toggle
        ;; window lookup stay reliable; mirrors prior vterm behavior.
        ghostel-set-title-function nil
        ghostel-kill-buffer-on-exit t          ; was vterm-kill-buffer-on-exit t
        ghostel-query-before-killing nil)      ; ~ confirm-kill-processes nil
  ;; ghostel-max-scrollback default is 5MB (~ vterm's 5000 lines); left as default.
  ;; Color theming: ghostel's 16 `ghostel-color-*' ANSI faces inherit from
  ;; `ansi-color-*', and `ghostel-default' from `default', so ef-owl (via its
  ;; modus-themes base) already supplies the palette — no hardcoded hexes needed.
  ;; `ghostel-sync-theme' only runs on demand, so re-apply it to live terminals
  ;; whenever the theme (re)loads. `doom-load-theme-hook' covers both startup and
  ;; interactive switches (ef-themes-toggle/select funnel through `load-theme').
  (add-hook 'doom-load-theme-hook #'ghostel-sync-theme)
  (map! :map ghostel-mode-map
        "C-q" #'ghostel-send-next-key                          ; was vterm-send-next-key
        :n "0"  (cmd! (ghostel-send-key "a" "ctrl"))           ; was +vterm/beginning-of-line
        :n "dd" (cmd! (ghostel-send-key "e" "ctrl")
                      (ghostel-send-key "u" "ctrl"))           ; was +vterm/delete-line
        :n "S"  (cmd! (ghostel-send-key "r" "ctrl"))           ; was vterm-send-C-r
        :n ", <escape>" (cmd! (ghostel-send-key "escape")))    ; was vterm-send-escape
  (setq-hook! 'ghostel-mode-hook
    hscroll-margin 0))                          ; prevent premature horizontal scroll

(use-package! evil-ghostel
  :when (modulep! :editor evil)
  :after ghostel
  :hook (ghostel-mode . evil-ghostel-mode))     ; syncs terminal cursor w/ evil state
;; Term Config:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Checkers Config][Checkers Config:1]]
;;---------------------------------------------------------------------------
(setf ispell-alternate-dictionary "/usr/share/hunspell/en_CA.dic")
;; Org 9.7+ returns `org-lint' line positions as propertized strings, but
;; flycheck's org-lint checker still passes them straight to
;; `flycheck-error-new-at', which expects a number-or-marker. Result: every
;; save of an org file errors out. Disable until flycheck#2024 is fixed.
(after! flycheck
  (add-to-list 'flycheck-disabled-checkers 'org-lint))
(defun +spell/correct-previous-highlight ()
  "Jump to previous error, correct it, then return to the original position in insert mode."
  (interactive)
  ;; 1. Save the current position with a Marker
  (let ((origin (point-marker)))
    ;; 2. Ensure marker stays at the end if we are typing at the very end of the line
    (set-marker-insertion-type origin t)

    (when (featurep 'spell-fu)
      ;; 3. Go to error and correct
      (spell-fu-goto-previous-error)
      (+spell/correct))

    ;; 4. Jump back to the marker (the original position)
    (goto-char origin)

    ;; 5. Clean up the marker to free memory
    (set-marker origin nil)

    ;; 6. Force Evil into Insert Mode so you can keep typing immediately
    (evil-insert 1)))
(map! :g   "C-s" nil
      :nim "C-s" #'+spell/correct-previous-highlight)
;; Checkers Config:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Tools Config][Tools Config:1]]
;;---------------------------------------------------------------------------
;; Tools Config:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Pdf-Tools Config][Pdf-Tools Config:2]]
;;---------------------------------------------------------------------------
;; Disable evil-collection's pdf bindings so we have full control over
;; pdf-view-mode-map. Must run before `evil-collection-init', so we use
;; Doom's `+evil-collection-disabled-list' rather than mutating
;; `evil-collection-mode-list' inside `after!' (which fires too late —
;; the `eval-after-load 'pdf-view' hook is already registered, and
;; evil-collection-pdf-setup later tries to bind `sb' under `s', which
;; we've rebound to `avy-goto-word-or-subword-1').
(add-to-list '+evil-collection-disabled-list 'pdf)

(map! :after pdf-tools
      :map pdf-view-mode-map
      :n "i"              #'org-noter-insert-note
      :n "M-i"            #'bhw/org-noter-insert-precise-quote
      :n "d"              #'pdf-view-scroll-up-or-next-page
      :n "u"              #'pdf-view-scroll-down-or-previous-page
      :n "s"              #'avy-goto-word-or-subword-1
      :n "f"              #'pdf-view-set-slice-from-bounding-box
      :n ";"              #'pdf-occur
      :n "q"              #'bhw/org-noter-quit
      :n "gt"             #'pdf-view-goto-page
      :n "w"              #'bhw/pdf-view-fit-width
      :n "y"              #'bhw/pdf-view-yank
      :n [down-mouse-1]   #'bhw/pdf-view-mouse-set-region
      :n [C-down-mouse-1] #'pdf-view-mouse-extend-region
      :n [M-down-mouse-1] #'pdf-view-mouse-set-region-rectangle)

;; Prevent Evil from entering visual-mode when pdf-view activates the
;; mark for text selection.  Without this, Evil hijacks the region and
;; tries to select the PDF image object, breaking click-drag selection.
;; (Mirrors evil-collection-pdf-disable-visual-mode.)
(add-hook! 'pdf-view-mode-hook
  (pdf-view-midnight-minor-mode)
  (run-at-time "0.1 sec" nil (lambda () (when (derived-mode-p 'pdf-view-mode)
                                          (pdf-view-redisplay t))))
  (remove-hook 'activate-mark-hook 'evil-visual-activate-hook t))

(defun bhw/pdf-view-fit-width ()
  "Fit PDF page width, re-displaying first to avoid stale image errors."
  (interactive)
  (pdf-view-redisplay t)
  (pdf-view-fit-width-to-window))

(defun bhw/pdf-view-mouse-set-region (event)
  "Start a PDF text selection, re-displaying first to avoid stale image errors."
  (interactive "@e")
  (pdf-view-redisplay t)
  (pdf-view-mouse-set-region event))

(defun bhw/pdf-view-yank ()
  "Yank the text of the active PDF region into the kill ring."
  (interactive)
  (pdf-view-assert-active-region)
  (let ((txt (pdf-view-active-region-text)))
    (pdf-view-deactivate-region)
    (kill-new (mapconcat #'identity txt "\n"))
    (message "Yanked %d characters." (length (car kill-ring)))))

;; Fix: `pdf-view-image-size' passes the raw display property to the C
;; primitive `image-size' when DISPLAYED-P is nil.  After slicing
;; (`pdf-view-set-slice-from-bounding-box'), the display property
;; becomes ((slice X Y W H) (image …)) — a compound form that the C
;; primitive `image-size' cannot handle (it expects (image …)).  This
;; advice unwraps the image spec from the sliced form so `image-size'
;; receives a bare (image …) descriptor.
(defadvice! bhw/pdf-view-image-size-handle-slice-a (fn &optional displayed-p window page)
  :around #'pdf-view-image-size
  (if displayed-p
      ;; `image-display-size' already handles the sliced compound form.
      (funcall fn displayed-p window page)
    ;; Replicate the display-prop lookup that `pdf-view-image-size' does
    ;; internally, but unwrap any slice wrapper before calling `image-size'.
    (let ((display-prop (if pdf-view-roll-minor-mode
                            (let ((w (if (windowp window) window (selected-window))))
                              (overlay-get (pdf-roll-page-overlay
                                            (or page (pdf-view-current-page w)) w)
                                           'display))
                          (image-get-display-property))))
      (image-size (if (eq (car-safe (car display-prop)) 'slice)
                      (cadr display-prop)   ; ((slice …) (image …)) → (image …)
                    display-prop)           ; already (image …)
                  t))))

(after! pdf-tools
  (setf pdf-view-use-scaling nil
        pdf-view-max-image-width 4800
        pdf-cache-image-limit 512
        pdf-cache-prefetch-delay 0.3
        ;; see also `pdf-view-midnight-minor-mode'
        pdf-view-midnight-invert nil
        pdf-tools-enabled-modes
        '(pdf-view-dark-minor-mode
          pdf-history-minor-mode
          pdf-isearch-minor-mode
          pdf-links-minor-mode
          pdf-misc-minor-mode
          pdf-misc-size-indication-minor-mode
          pdf-occur-global-minor-mode))
  (pdf-cache-prefetch-minor-mode -1))
;; Pdf-Tools Config:2 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Magit Config][Magit Config:1]]
;;---------------------------------------------------------------------------
(after! magit
  (map! :map magit-status-mode-map
        "SPC" #'doom/leader
        "j" #'evil-next-line
        "k" #'evil-previous-line
        "h" #'evil-backward-char
        "l" #'evil-forward-char
        "p" #'magit-push
        "v" #'evil-visual-line
        "V" #'evil-visual-line
        "gg" #'evil-goto-first-line
        "G" #'evil-goto-line))
;; Magit Config:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Claude Code IDE Config][Claude Code IDE Config:5]]
;;---------------------------------------------------------------------------
(use-package! claude-code-ide
  :config
  ;; Use the ghostel terminal backend (installed below) instead of the
  ;; default 'vterm, whose native module isn't compiled in this setup.
  (setq claude-code-ide-terminal-backend 'ghostel)

  (defun bhw/claude-code-ide-start-or-toggle-window ()
    "Start claude-code-ide if needed; otherwise toggle the chat window."
    (interactive)
    (condition-case _
        (call-interactively #'claude-code-ide-toggle-recent)
      (error (call-interactively #'claude-code-ide))))

  ;; Register the 5 built-in Emacs MCP tools (xref-find-references,
  ;; xref-find-apropos, project-info, imenu-list-symbols, treesit-info)
  ;; and set `claude-code-ide-enable-mcp-server' to t.
  (claude-code-ide-emacs-tools-setup)

  ;; --- Custom MCP tools ----------------------------------------------------
  ;; Editor state

  (defun bhw/claude-mcp-current-buffer-info ()
    "Return file, mode, point, line, column, region status of the session buffer."
    (let ((context (claude-code-ide-mcp-server-get-session-context)))
      (if (not context)
          "No session context available"
        (let ((buffer (plist-get context :buffer)))
          (if (not (and buffer (buffer-live-p buffer)))
              "No active buffer in session context"
            (with-current-buffer buffer
              (format "Buffer: %s\nFile: %s\nMode: %s\nLine: %d\nColumn: %d\nPoint: %d\nRegion active: %s"
                      (buffer-name)
                      (or (buffer-file-name) "(no file)")
                      major-mode
                      (line-number-at-pos)
                      (current-column)
                      (point)
                      (if (use-region-p) "yes" "no"))))))))

  (defun bhw/claude-mcp-current-selection ()
    "Return active region text from the session buffer, or a no-region message."
    (let ((context (claude-code-ide-mcp-server-get-session-context)))
      (if (not context)
          "No session context available"
        (let ((buffer (plist-get context :buffer)))
          (if (not (and buffer (buffer-live-p buffer)))
              "No active buffer in session context"
            (with-current-buffer buffer
              (if (use-region-p)
                  (buffer-substring-no-properties (region-beginning) (region-end))
                "No active region")))))))

  (defun bhw/claude-mcp-list-buffers (&optional include_non_file)
    "Return open buffers as `name → file' lines.
With INCLUDE_NON_FILE non-nil, also include non-file user buffers."
    (let ((lines '()))
      (dolist (buf (buffer-list))
        (let ((file (buffer-file-name buf))
              (name (buffer-name buf)))
          (cond (file
                 (push (format "%s → %s" name file) lines))
                ((and include_non_file
                      (not (string-prefix-p " " name)))
                 (push name lines)))))
      (if lines
          (string-join (nreverse lines) "\n")
        "No matching buffers")))

  ;; Org-node (org-mem-entry candidate hash)

  (defun bhw/claude-mcp-org-node-find (query)
    "Substring-match org-node candidates by QUERY (case-insensitive).
Returns up to 20 lines of `title | file | id'."
    (require 'org-node)
    (org-node-cache-ensure)
    (let* ((q (downcase (or query "")))
           (matches '())
           (count 0))
      (catch 'done
        (maphash
         (lambda (cand entry)
           (when (string-match-p (regexp-quote q) (downcase cand))
             (push (format "%s | %s | %s"
                           (org-mem-entry-title entry)
                           (org-mem-entry-file entry)
                           (or (org-mem-entry-id entry) ""))
                   matches)
             (cl-incf count)
             (when (>= count 20) (throw 'done nil))))
         org-node--candidate<>entry))
      (if matches
          (string-join (nreverse matches) "\n")
        (format "No org-node matches for %S" query))))

  ;; Org agenda / clock

  (defun bhw/claude-mcp-org-agenda-todos (&optional keyword)
    "List entries in `org-agenda-files' whose todo state is KEYWORD (default TODO)."
    (require 'org)
    (let* ((kw (or keyword "TODO"))
           (results
            (org-map-entries
             (lambda ()
               (let* ((heading (org-get-heading t t t t))
                      (pri (org-entry-get nil "PRIORITY"))
                      (dl (org-entry-get nil "DEADLINE"))
                      (file (buffer-file-name))
                      (line (line-number-at-pos)))
                 (format "%s:%d: [#%s] %s%s"
                         (or file "(buffer)")
                         line
                         (or pri "?")
                         heading
                         (if dl (format " DEADLINE=%s" dl) ""))))
             (format "+TODO=\"%s\"" kw)
             'agenda)))
      (if results
          (string-join results "\n")
        (format "No entries in state %s across agenda files" kw))))

  (defun bhw/claude-mcp-org-clock-status ()
    "Return current org-clock task with elapsed time, or last history entry."
    (require 'org-clock)
    (cond
     ((org-clocking-p)
      (let* ((elapsed (float-time (time-since org-clock-start-time)))
             (h (floor (/ elapsed 3600)))
             (m (floor (/ (mod elapsed 3600) 60))))
        (format "Clocked in: %s\nStarted: %s\nElapsed: %dh%02dm"
                org-clock-current-task
                (format-time-string "%F %T" org-clock-start-time)
                h m)))
     ((and (boundp 'org-clock-history) org-clock-history)
      (let* ((m (car org-clock-history))
             (buf (and (markerp m) (marker-buffer m))))
        (if (buffer-live-p buf)
            (with-current-buffer buf
              (save-excursion
                (goto-char m)
                (format "No clock running. Last task: %s in %s"
                        (org-get-heading t t t t)
                        (or (buffer-file-name) (buffer-name)))))
          "No clock running. History markers point to dead buffers.")))
     (t "No clock active and history empty")))

  ;; Citar bibliography

  (defun bhw/claude-mcp-citar-lookup (query)
    "Substring-match citar bibliography entries by QUERY (case-insensitive).
Searches citekey, title, and author. Returns up to 20 lines."
    (require 'citar)
    (let* ((q (downcase (or query "")))
           (entries (citar-get-entries))
           (matches '())
           (count 0))
      (catch 'done
        (maphash
         (lambda (key entry)
           (let* ((title (or (cdr (assoc "title" entry)) ""))
                  (author (or (cdr (assoc "author" entry)) ""))
                  (year (or (cdr (assoc "year" entry))
                            (cdr (assoc "date" entry)) "")))
             (when (or (string-match-p (regexp-quote q) (downcase key))
                       (string-match-p (regexp-quote q) (downcase title))
                       (string-match-p (regexp-quote q) (downcase author)))
               (push (format "@%s | %s | %s | %s" key author year title) matches)
               (cl-incf count)
               (when (>= count 20) (throw 'done nil)))))
         entries))
      (if matches
          (string-join (nreverse matches) "\n")
        (format "No bibliography matches for %S" query))))

  ;; --- Tool registrations --------------------------------------------------

  (claude-code-ide-make-tool
   :function #'bhw/claude-mcp-current-buffer-info
   :name "current-buffer-info"
   :description "Get the user's currently active Emacs buffer: file path, major mode, line, column, point, and whether a region is active. Use this to learn what file/location the user is looking at right now."
   :args nil)

  (claude-code-ide-make-tool
   :function #'bhw/claude-mcp-current-selection
   :name "current-selection"
   :description "Return the text of the user's active region (selection) in Emacs, or a no-region message. Use this when the user references \"this\" or \"the selection\"."
   :args nil)

  (claude-code-ide-make-tool
   :function #'bhw/claude-mcp-list-buffers
   :name "list-buffers"
   :description "List the user's currently open Emacs buffers visiting files. Use this to discover what the user has loaded without scanning the filesystem."
   :args '((:name "include_non_file"
            :type boolean
            :description "Also include buffers that are not visiting a file (default false)"
            :optional t)))

  (claude-code-ide-make-tool
   :function #'bhw/claude-mcp-org-node-find
   :name "org-node-find"
   :description "Search the user's org-node knowledge base for entries matching a substring query (case-insensitive). Returns up to 20 results as `title | file | id'."
   :args '((:name "query"
            :type string
            :description "Substring to match against org-node candidate titles")))

  (claude-code-ide-make-tool
   :function #'bhw/claude-mcp-org-agenda-todos
   :name "org-agenda-todos"
   :description "List TODO-like entries across the user's `org-agenda-files'. Filter by a single todo keyword (TODO, PROJ, APPT, PROG, WAIT, DONE, CXLD). Default is TODO."
   :args '((:name "keyword"
            :type string
            :description "Todo keyword to match. Default: TODO."
            :optional t)))

  (claude-code-ide-make-tool
   :function #'bhw/claude-mcp-org-clock-status
   :name "org-clock-status"
   :description "Return the user's currently clocked-in org task with elapsed time, or the most recent clock history entry if no clock is running."
   :args nil)

  (claude-code-ide-make-tool
   :function #'bhw/claude-mcp-citar-lookup
   :name "citar-lookup"
   :description "Search the user's citar bibliography (project-jerome.bib) by substring across citekey, title, and author. Returns up to 20 matches."
   :args '((:name "query"
            :type string
            :description "Substring to match against citekey, title, or author")))

  (map! :leader
        (:prefix-map ("d" . "claude-code-ide")
         :desc "claude-code-ide start/toggle window" "SPC" #'bhw/claude-code-ide-start-or-toggle-window
         :desc "claude-code-ide-menu" "m" #'claude-code-ide-menu)))
;; Claude Code IDE Config:5 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Lexic Config][Lexic Config:2]]
;;---------------------------------------------------------------------------
(use-package! lexic
  :init
  (map! :leader
        :desc "lexic-search-word-at-point" "sx" #'lexic-search-word-at-point
        :desc "lexic-search"               "sX" #'lexic-search)
  :config
  (map! :after lexic
        :map lexic-mode-map
        "SPC" #'doom/leader
        "j"   #'evil-next-line
        "k"   #'evil-previous-line
        "h"   #'evil-backward-char
        "l"   #'evil-forward-char
        "q"   #'lexic-return-from-lexic
        "RET" #'lexic-search-word-at-point
        "a"   #'outline-show-all
        "o"   #'lexic-toggle-entry
        "d"   #'lexic-next-entry
        "u"   #'lexic-previous-entry
        "p"   #'lexic-search-history-backwards
        "n"   #'lexic-search-history-forwards)
  (setf lexic-dictionary-specs '
        (("Webster's Revised Unabridged Dictionary (1913)"
          :short "===========================================================\n Webster's Revised Unabridged Dictionary (1913)\n==========================================================="
          :formatter lexic-format-webster
          :priority 1)
         ("Soule's Dictionary of English Synonyms"
          :short "===========================================================\n Soule's Dictionary of English Synonyms (1871)\n==========================================================="
          :formatter lexic-format-soule
          :priority 2)
         ("Online Etymology Dictionary"
          :short "===========================================================\n Online Etymology Dictionary (2000)\n==========================================================="
          :formatter lexic-format-online-etym
          :priority 3)
         ("Oxford English Dictionary 2nd Ed P1"
          :short "===========================================================\n Oxford English Dictionary 2nd Ed. (1989)\n==========================================================="
          :formatter lexic-format-online-etym
          :priority 4)
         ("Oxford English Dictionary 2nd Ed P2"
          :short "===========================================================\n Oxford English Dictionary 2nd Ed. (1989)\n==========================================================="
          :formatter lexic-format-online-etym
          :priority 5)
         ("latin-english"
          :short "===========================================================\n Latin > English\n==========================================================="
          :formatter lexic-format-online-etym
          :priority 6))))
;; Lexic Config:2 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Biblio Config][Biblio Config:1]]
;;---------------------------------------------------------------------------
(use-package! citar
  :config
  (setf
   citar-bibliography (list (concat +project-maria-dir+ "project-jerome.bib"))
   citar-notes-paths (list (concat +project-maria-dir+ "bibtex-notes"))
   citar-library-paths
   (let* ((base (expand-file-name "~/project-jerome"))
          (excluded (mapcar #'expand-file-name
                            '("~/project-jerome/email-archive"
                              "~/project-jerome/org-attach-data"
                              "~/project-jerome/keepass-database"))))
     (cl-remove-if (lambda (d) (cl-some (lambda (ex) (string-prefix-p ex d)) excluded))
                   (cons base (cl-remove-if-not #'file-directory-p
                                                (directory-files-recursively base "" t))))))
  (map! :leader
        :desc "citar-open" "s SPC" #'citar-open))
;; Biblio Config:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Languages Config][Languages Config:1]]
;;---------------------------------------------------------------------------
;; Languages Config:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Common Lisp Config][Common Lisp Config:1]]
;;---------------------------------------------------------------------------
(after! sly
  (setq sly-contribs (delq 'sly-quicklisp sly-contribs)))

(setf common-lisp-hyperspec-root
      (concat "file://" +project-jerome-dir+
              "000-generalities-information-computers/000-computer-science/HyperSpec/"))
;; https://emacs.stackexchange.com/questions/62536/what-does-making-browse-url
;; -browser-function-local-to-eww-while-let-bound-m
(advice-add 'hyperspec-lookup
            :around
            (lambda (orig-fun &rest args)
              (setq-local browse-url-browser-function 'eww-browse-url)
              (apply orig-fun args)))
;; Common Lisp Config:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Org Mode Config][Org Mode Config:1]]
;;---------------------------------------------------------------------------
(after! evil-org
  (remove-hook 'org-tab-first-hook #'+org-cycle-only-current-subtree-h))

(after! org
  (add-hook! 'org-mode-hook (electric-indent-local-mode -1))
  (add-hook! 'org-mode-hook
    (add-hook 'completion-at-point-functions #'cape-file -10 t))

  (advice-remove #'org-mark-ring-push #'doom-set-jump-a)
  (setf org-adapt-indentation nil
        org-startup-indented nil
        ;; Be strict about extensions: match ".org" and ".org.gpg" only.
        org-id-extra-files (directory-files-recursively +project-maria-dir+ "\\.org\\(\\.gpg\\)?$"))
  (require 'org-depend)
  (require 'cl-lib)

  (defun afs/org-replace-link-by-link-description ()
    "Replace an org link by its description or if empty its address"
    (interactive)
    (if (org-in-regexp org-link-bracket-re 1)
        (save-excursion
          (let ((remove (list (match-beginning 0) (match-end 0)))
                (description
                 (if (match-end 2)
                     (org-match-string-no-properties 2)
                   (org-match-string-no-properties 1))))
            (apply 'delete-region remove)
            (insert description)))))

  (map! :leader
        :desc "Agenda" "a" #'bhw/default-custom-agenda))
;; Org Mode Config:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Org Agenda Config][Org Agenda Config:1]]
;;---------------------------------------------------------------------------
(after! org
  (org-clock-persistence-insinuate)

  (load! "private-packages/org-agenda-find-free-time.el")

  (defun bhw/org-mode-ask-effort ()
    "Ask for an effort estimate when clocking in if none exists."
    (unless (org-entry-get (point) "Effort")
      (let ((effort
             (completing-read
              "Effort: "
              (org-entry-get-multivalued-property (point) "Effort"))))
        (unless (equal effort "")
          (org-set-property "Effort" effort)))))

  (add-hook 'org-clock-in-prepare-hook #'bhw/org-mode-ask-effort)

  (defun bhw/clock-in ()
    "Smart clock-in/out command.

- No running clock: call `org-clock-in' with a prefix arg to select
  from recent clock history.
- Running clock < 3 hours: clock out of the current task.
- Running clock ≥ 3 hours: the clock is likely stale; interactively
  resolve it via `org-resolve-clocks' before doing anything else."
    (interactive)
    (if (org-clocking-p)
        (let* ((elapsed-secs (float-time (time-since org-clock-start-time)))
               (three-hours-secs (* 3 60 60)))
          (if (>= elapsed-secs three-hours-secs)
              ;; Clock has been running for over 3 hours — needs resolution.
              (progn
                (message "Clock has been running for over 3 hours. Resolving…")
                (org-resolve-clocks))
            ;; Normal running clock — just clock out.
            (org-clock-out)))
      ;; No running clock — select from history.
      (org-clock-in '(4))))

  (defun bhw/verify-refile-target ()
    "Exclude todo keywords with a done state from refile targets"
    (not (member (nth 2 (org-heading-components)) org-done-keywords)))

  ;; Press t to change task todo state
  (setf
   org-agenda-files
   (list (concat +project-maria-dir+ "hq.org"))
   inhibit-compacting-font-caches t
   org-agenda-start-day "+0d"
   org-use-fast-todo-selection t
   org-treat-S-cursor-todo-selection-as-state-change t
   ;; Require exit notes for modifying a scheduled for deadline date
   org-log-reschedule 'time
   org-log-redeadline 'note
   org-log-done 'time
   org-todo-keywords
   '((sequence "TODO(t)" "PROJ(p)" "APPT(a)" "PROG(i)"
      "WAIT(w@/!)" "|" "DONE(d)" "CXLD(c@/!)"))
   org-todo-keyword-faces
   '(("PROJ" :foreground "DarkSlateBlue" :weight bold)
     ("TODO" :foreground "tomato1" :weight bold)
     ("WAIT" :foreground "orchid3" :weight bold)
     ("PROG" :foreground "DeepSkyBlue3" :weight bold)
     ("DONE" :foreground "SpringGreen3" :weight bold)
     ("APPT" :foreground "tomato3" :weight bold)
     ("CXLD" :foreground "sienna" :weight bold))
   org-agenda-dim-blocked-tasks t
   org-habit-graph-column 80
   org-agenda-skip-scheduled-if-deadline-is-shown t
   org-agenda-skip-deadline-prewarning-if-scheduled 'pre-scheduled
   org-agenda-skip-scheduled-if-done t
   org-agenda-skip-deadline-if-done t
   org-agenda-todo-ignore-scheduled 'future
   org-agenda-todo-ignore-deadlines t
   org-deadline-warning-days 7
   org-enforce-todo-dependencies nil
   ;; 6) Adding New Tasks Quickly with Org Capture
   ;; Capture templates for: TODO tasks, Notes, appointments, phone calls, meetings, and org-protocol
   ;; \n is newline in the template. Functions as RET would in insert mode
   ;; placing a backslash before " in TRIGGER below to have the string not end
   org-capture-templates
   `(("t" "Todo Task" entry (file+headline ,(concat +project-maria-dir+ "hq.org") "Inbox") "* TODO [#C] %?\n:PROPERTIES:\n:EFFORT:   %^{0:00|0:10|0:30|1:00|1:30|2:00|2:30|3:00}\n:ASSIGNED: %U\n:END:\n" :empty-lines 1)
     ("a" "Appointment" entry (file+headline ,(concat +project-maria-dir+ "hq.org") "Inbox") "* APPT %?\nSCHEDULED: %^T\n:PROPERTIES:\n:LOCATION: %^{LOCATION|TBD}\n:EFFORT:   %^{0:00|0:10|0:30|1:00|1:30|2:00|2:30|3:00}\n:ASSIGNED: %U\n:END:\n" :empty-lines 1)
     ("j" "Journal Entry" entry (file+headline ,(concat +project-maria-dir+ "hq.org") "Inbox")"* TODO [#C] JOURNAL ENTRY %<Y%YW%V%B%d>\n:PROPERTIES:\n:EFFORT: 0:10\n:ASSIGNED: %U\n:END:\n%?" :empty-lines 1)
     ("h" "Habit" entry (file+headline ,(concat +project-maria-dir+ "hq.org") "Inbox")"* TODO %?\nSCHEDULED: %(format-time-string \"%\")\n:PROPERTIES:\n:STYLE: habit\n:REPEAT_TO_STATE: TODO\n:ASSIGNED: %U\n:END:" :empty-lines 1)
     ("c" "Contacts" entry (file ,(concat +project-maria-dir+ "contacts.org")) "* %(org-contacts-template-name)\n:PROPERTIES:\n:PHONE: %?\n:EMAIL:\n:ADDRESS:\n:BIRTHDAY:\n:NOTE: Added on: %U\n:END:" :empty-lines 1)
     ("p" "Project" entry (file ,(concat +project-maria-dir+ "hq.org")) "* PROJ %? [/] [%] %^G\n:PROPERTIES:\n:ASSIGNED: %U\n:END:\n** TODO [#C]\n:PROPERTIES:\n:EFFORT: %^{0:00|0:10|0:30|1:00|1:30|2:00|2:30|3:00}\n:ASSIGNED: %U\n:END:\n" :empty-lines 1))
   ;; **** 9) Clocking
   org-clock-in-switch-to-state "PROG"
   org-clock-out-remove-zero-time-clocks t
   org-clock-out-when-done t
   org-clock-persist t
   org-clock-in-resume t
   org-clock-persist-query-resume nil
   org-clock-auto-clock-resolution 'when-no-clock-is-running
   org-clock-report-include-clocking-task t
   org-time-stamp-rounding-minutes '(1 1)
   org-agenda-clockreport-parameter-plist
   '(:link t :maxlevel 10 :fileskip0 t :stepskip0 t :compact t :narrow 80)
   org-log-into-drawer t
   org-clock-history-length 35
   ;; **** 7) Refiling Tasks
   org-refile-targets '((nil :maxlevel . 9)
                        (org-agenda-files :maxlevel . 9))
   org-outline-path-complete-in-steps nil
   org-refile-use-outline-path 'file
   org-refile-target-verify-function 'bhw/verify-refile-target
   ;; **** 11) Context Tags with fast selection keys
   org-tag-alist '(;; Sets geo-spatial and context tags
                   ;; Startgroup and endgroup make tags mutually
                   ;; exclusive (:startgroup)
                   ("home" . ?h)
                   ("office" . ?o)
                   ("errand" . ?e)
                   ;; (:endgroup)
                   ;; Person(s) can be contexts too.
                   ;; ("father" . ?d)
                   ;; ("workteam1" . ?d)
                   ;; ("docket" . ?d)
                   )
   org-fast-tag-selection-single-key 'expert
   org-tags-column 0
   ;; For tag searches ignore tasks with scheduled and deadline dates
   org-agenda-tags-todo-honor-ignore-options t
   ;; **** 14) Stuck Projects
   org-stuck-projects   '("+TODO=\"PROJ\"" ("TODO" "PROG" "WAIT") nil nil)
   ;; **** 15) Archiving
   org-archive-default-command 'org-archive-subtree
   org-archive-location
   (concat +project-maria-dir+
           "archived-tasks/taskings-"
           (format-time-string "%Y") ".org::datetree/")
   org-archive-save-context-info '(time category olpath ltags itags)
   org-habit-show-habits t
   ;; To speed up org agenda generation
   org-agenda-inhibit-startup t
   org-agenda-ignore-properties '(ASSIGNED LAST_REPEAT)
   org-agenda-sticky nil)

  (defun bhw/org-agenda-calculate-efforts (limit)
    "Sum the efforts of scheduled entries up to LIMIT in the agenda buffer."
    (let ((total-minutes 0))
      (save-excursion
        (while (< (point) limit)
          (when (member (org-get-at-bol 'type) '("scheduled" "past-scheduled" "timestamp"))
            (let* ((marker (org-get-at-bol 'org-hd-marker))
                   (effort (when marker (org-entry-get marker "EFFORT"))))
              (when effort
                (setq total-minutes (+ total-minutes (org-duration-to-minutes effort))))))
          (forward-line)))
      (org-duration-from-minutes total-minutes)))

  (defun bhw/org-agenda-insert-efforts ()
    "Insert the efforts for each day inside the agenda buffer."
    (save-excursion
      (let (pos)
        (while (setq pos (text-property-any
                          (point) (point-max) 'org-agenda-date-header t))
          (goto-char pos)
          (end-of-line)
          (insert-and-inherit
           (concat " ("
                   (bhw/org-agenda-calculate-efforts
                    (or (text-property-any
                         (point) (point-max) 'org-agenda-date-header t)
                        (point-max)))
                   ")"))
          (forward-line)))))

  (add-hook 'org-agenda-finalize-hook #'bhw/org-agenda-insert-efforts)

  (defface bhw/stale-assigned-face
    '((t :background "#4d3028" :extend t))
    "Face for TODO items assigned over a month ago (Priority C, no schedule/deadline).")

  (defun bhw/highlight-stale-assigned-todos ()
    "Highlight agenda TODO items assigned over a month ago.
Only applies to Priority C items with no scheduled date or deadline.
Batches source-buffer lookups to minimize buffer switching."
    (let ((one-month-ago (time-subtract (current-time) (days-to-time 30)))
          (agenda-buf (current-buffer))
          candidates)
      ;; Pass 1: collect candidate lines (agenda-local checks only)
      (save-excursion
        (goto-char (point-min))
        (while (not (eobp))
          (let ((marker (or (org-get-at-bol 'org-hd-marker)
                            (org-get-at-bol 'org-marker))))
            (when (and marker
                       (equal (org-get-at-bol 'todo-state) "TODO")
                       (let ((pri (org-get-at-bol 'priority)))
                         (or (null pri) (= pri 0))))
              (push (list marker (line-beginning-position) (line-end-position))
                    candidates)))
          (forward-line)))
      ;; Pass 2: group by source buffer, single switch per buffer
      (let ((by-buffer (make-hash-table :test 'eq)))
        (dolist (c candidates)
          (let ((buf (marker-buffer (car c))))
            (when buf
              (push c (gethash buf by-buffer)))))
        (maphash
         (lambda (buf entries)
           (with-current-buffer buf
             (dolist (entry entries)
               (let ((marker (nth 0 entry))
                     (bol (nth 1 entry))
                     (eol (nth 2 entry)))
                 (goto-char marker)
                 (let ((scheduled (org-get-scheduled-time (point)))
                       (deadline (org-get-deadline-time (point)))
                       (assigned-str (org-entry-get (point) "ASSIGNED")))
                   (when (and (null scheduled)
                              (null deadline)
                              assigned-str
                              (time-less-p (org-time-string-to-time assigned-str)
                                           one-month-ago))
                     (let ((ov (make-overlay bol eol agenda-buf)))
                       (overlay-put ov 'face 'bhw/stale-assigned-face)
                       (overlay-put ov 'bhw/stale-assigned t))))))))
         by-buffer))))

  (add-hook 'org-agenda-finalize-hook #'bhw/highlight-stale-assigned-todos)

  (defun bhw/default-custom-agenda()
    "Functionally call custom agenda command bound to KEY"
    (interactive)
    (org-agenda nil "d"))

  (defun bhw/org-capture-set-priority-on-deadline ()
    "Set the priority of an org-capture entry to [#B] if a deadline exists.
                          This function is intended to be used with `org-capture-before-finalize-hook`."
    (save-excursion
      (goto-char (point-min))
      ;; Check if a DEADLINE: timestamp exists in the entry
      (when (re-search-forward "^[ \t]*DEADLINE:" nil t)
        ;; If a deadline is found, set the priority to 'B'
        (org-priority ?B))))

  (add-hook 'org-capture-before-finalize-hook #'bhw/org-capture-set-priority-on-deadline)

  (defun bhw/org-agenda-deadline-for-prefix ()
    "Return the deadline relative to today (e.g. 'In 5 d.'), formatted to 6 chars.
   Returns 6 spaces if no deadline exists."
    (let ((deadline-time (org-get-deadline-time (point))))
      (if deadline-time
          (let* ((days (- (org-time-string-to-absolute
                           (format-time-string "%Y-%m-%d" deadline-time))
                          (org-today)))
                 (result-string
                  (cond
                   ((< days 0) (format "%dd ago" (abs days))) ;; Overdue: "2d ago"
                   ((= days 0) "Today")                       ;; Due today
                   (t (format "%d d." days)))))               ;; Future: "5 d."
            ;; Format to exactly 6 characters, left-aligned
            (format "%-6s" result-string))
        ;; If no deadline, return 6 spaces to maintain alignment
        (make-string 6 ?\s))))

  (defun bhw/org-agenda-effort-for-prefix ()
    "Return the effort estimate formatted as '[HH:MM] ', or spacers if no effort."
    (let ((effort (org-entry-get (point) "EFFORT")))
      (if effort
          (format "[%-4s] " effort) ;; Result: "[0:30] "
        "       ")))                ;; 7 spaces to match length of "[0:30] "

  (defvar bhw/excluded-course-tags
    '("-bio1200" "-his2500" "-cla154" "-lat122" "-mus221"
      "-the249" "-the274" "-phl300" "-the219")
    "Course tags excluded from the Review agenda's tag filter.
Prune entries here as courses finish.")

  (setf
   org-agenda-block-separator 61
   org-agenda-breadcrumbs-separator " | "
   ;; https://stackoverflow.com/questions/58820073/s-in-org-agenda-prefix-format-doesnt-display-dates-in-the-todo-view
   org-agenda-prefix-format
   '((agenda . "%-t %s")
     (todo . "%s")
     (tags . "%s")
     (search . "%s"))
   org-agenda-deadline-leaders '("D: " "D%2d: " "OD%2d: ")
   org-agenda-scheduled-leaders '("" "S%2d: ")
   org-agenda-time-grid '((daily today remove-match)
                          (0600 0900 1200 1500 1800 2100)
                          "......" "----------------")
   org-columns-default-format-for-agenda "%75ITEM(Task) %DEADLINE %10Effort(Estim){:} %10CLOCKSUM(ActTime)"
   org-columns-default-format "%75ITEM(Task) %DEADLINE %10Effort(Estim){:} %10CLOCKSUM(ActTime)"
   org-global-properties '(("Effort_ALL" . "0:00 0:10 0:30 1:00 1:30 2:00 2:30 3:00 4:00 5:00 6:00 7:00 8:00")
                           ("STYLE_ALL" . "habit"))
   org-agenda-columns-add-appointments-to-effort-sum t
   org-agenda-default-appointment-duration 0
   org-agenda-log-mode-items '(closed state clock)
   org-agenda-start-with-log-mode t
   org-agenda-start-with-entry-text-mode nil
   org-agenda-add-entry-text-maxlines 5
   org-agenda-entry-text-maxlines 5
   org-agenda-start-with-clockreport-mode nil
   org-priority-default ?C
   org-agenda-custom-commands
   '(
     ;; Default Agenda
     ("d" "Default (Master) Agenda"
      ((agenda "" ((org-agenda-span 'day)
                   (org-deadline-warning-days 1)
                   (org-agenda-overriding-header "Today's Agenda\n")))
       (tags "TODO=\"PROG\""
             ((org-agenda-sorting-strategy '(priority-down deadline-up effort-down))
              (org-agenda-prefix-format
               '((tags . "  %-3:c %(bhw/org-agenda-deadline-for-prefix)%(bhw/org-agenda-effort-for-prefix)")))
              (org-agenda-todo-keyword-format "%-3s")
              (org-agenda-overriding-header "\nTasks in Progress\n")))
       (tags "TODO=\"TODO\""
             ((org-agenda-sorting-strategy '(priority-down deadline-up effort-down))
              (org-agenda-todo-ignore-deadlines nil)
              (org-agenda-prefix-format
               '((tags . "  %-3:c %(bhw/org-agenda-deadline-for-prefix)%(bhw/org-agenda-effort-for-prefix)")))
              (org-agenda-todo-keyword-format "%-3s")
              (org-agenda-skip-function '(org-agenda-skip-entry-if 'scheduled))
              (org-agenda-overriding-header "\nTodo List\n")))
       (agenda "" ((org-agenda-span 30)
                   (org-agenda-start-day "+1d")
                   (org-agenda-start-on-weekday nil)
                   (org-agenda-entry-types '(:timestamp :sexp :scheduled))
                   (org-agenda-overriding-header "Calendar\n"))))
      ((org-agenda-tag-filter-preset '("-SDAY"))))
     ;; Review Agenda
     ("r" "Review Agenda"
      ((tags "TODO=\"DONE\""
             ((org-agenda-sorting-strategy '(priority-down deadline-up))
              (org-agenda-todo-keyword-format "%-3s")
              (org-agenda-overriding-header "\nCompleted Tasks\n")))
       (tags "TODO=\"CXLD\""
             ((org-agenda-sorting-strategy '(tsia-up))
              (org-agenda-todo-keyword-format "%-3s")
              (org-agenda-overriding-header "\nTerminated Tasks\n")))
       (tags "+TODO=\"WAIT\""
             ((org-agenda-sorting-strategy '(timestamp-down))
              (org-agenda-todo-keyword-format "%-3s")
              (org-agenda-overriding-header "\nDelegated/Waiting For\n")))
       (stuck "" ((org-agenda-overriding-header "\nStuck Projects\n")))
       (agenda "" ((org-agenda-span 120)
                   (org-agenda-start-on-weekday nil)
                   (org-agenda-entry-types '(:timestamp :sexp :scheduled))
                   (org-agenda-overriding-header "Calendar\n"))))
      ((org-agenda-tag-filter-preset (append '("-SDAY") bhw/excluded-course-tags)))))
   org-agenda-window-setup 'current-window)
  (map! :after evil-org-agenda
        :map evil-org-agenda-mode-map
        :m "s" #'avy-goto-word-or-subword-1)
  (map! :map (org-mode-map)
        :localleader
        (:prefix ("x" . "text")
         :desc "bold emphasis         " "b" (cmd! (org-emphasize ?*))
         :desc "italic emphasis       " "i" (cmd! (org-emphasize ?/))
         :desc "underline emphasis    " "u" (cmd! (org-emphasize ?_))
         :desc "verbatim emphasis     " "v" (cmd! (org-emphasize ?=))
         :desc "code emphasis         " "c" (cmd! (org-emphasize ?~))
         :desc "strikethrough emphasis" "s" (cmd! (org-emphasize ?+)))
        (:prefix ("v" . "links")
         :desc "org-insert-structure-template" "v" #'org-insert-structure-template))
  (map! :leader
        :desc "bhw/clock-in" "nc" #'bhw/clock-in))
;; Org Agenda Config:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Org Attach Config][Org Attach Config:1]]
;;---------------------------------------------------------------------------
(defun fuco/org-attach-visit-headline-from-dired ()
  "Go to the headline corresponding to this org-attach directory."
  (interactive)
  (let* ((id-parts (last (split-string default-directory "/" t) 2))
         (id (apply #'concat id-parts)))
    (let ((m (org-id-find id 'marker)))
      (unless m (user-error "Cannot find entry with ID \"%s\"" id))
      (pop-to-buffer (marker-buffer m))
      (goto-char m)
      (move-marker m nil)
      (org-fold-show-context))))
(setf
 org-attach-id-dir "~/project-jerome/org-attach-data/"
 ;; https://helpdeskheadesk.net/2022-03-13/
 ;; For org attach, change org timestamps to more human readable format.
 org-id-method 'ts
 org-attach-id-to-path-function-list
 '(org-attach-id-ts-folder-format org-attach-id-uuid-folder-format)
 org-attach-method 'mv)
;; Org Attach Config:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Org Mem Config][Org Mem Config:1]]
;;---------------------------------------------------------------------------
(use-package! org-mem
  :after org
  :config
  (setf org-mem-watch-dirs (list +project-maria-dir+))
  (org-mem-updater-mode))
;; Org Mem Config:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Org Node Config][Org Node Config:1]]
;;---------------------------------------------------------------------------
(use-package! org-node
  :init
  (map! :leader
        :desc "org-node-find" "sf" #'org-node-find)
  :config
  (org-node-cache-mode)
  (setf org-node-backlink-do-drawers t)
  (org-node-backlink-mode)

  (defun bhw/org-node-ensure-source-id ()
    "Give the heading at point its own ID when inserting an org-node link.
Registered on `org-node-insert-link-hook' (point sits in the just-inserted
link).  `org-node-backlink--add-in-target' resolves the link's origin with
`org-entry-get-with-inheritance', so without an own ID the backlink lands on
the nearest ancestor node -- or, if no ancestor has an ID, no backlink is
written at all.  Creating an ID here makes this heading its own node so the
target's backlink points back to it precisely."
    (when (and (derived-mode-p 'org-mode)
               (buffer-file-name)
               (not (org-before-first-heading-p)))
      (save-excursion
        (org-id-get-create))))
  ;; Negative depth => runs before `org-node-backlink--add-in-target' (depth 0),
  ;; so the source ID exists by the time the backlink is written.
  (add-hook 'org-node-insert-link-hook #'bhw/org-node-ensure-source-id -50)

  (map! :map (org-mode-map)
        :localleader
        (:prefix ("l" . "links")
         :desc "org-node-insert-link" "n" #'org-node-insert-link))
  )
;; Org Node Config:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Org Noter Config][Org Noter Config:1]]
;;---------------------------------------------------------------------------
(after! org-noter
  (setf org-noter-always-create-frame nil
        org-noter-hide-other nil
        org-noter-auto-save-last-location t
        org-noter-arrow-delay -1)

  (defun bhw/org-noter-quit ()
    "Kill org-noter session without closing the emacs client frame.
Un-dedicates windows first to avoid Doom's `switch-to-prev-buffer' error,
then shadows `delete-frame' so the session teardown cannot close the frame."
    (interactive)
    (org-noter--with-valid-session
     (let ((frame (org-noter--session-frame session)))
       (dolist (win (window-list frame))
         (set-window-dedicated-p win nil))
       (cl-letf (((symbol-function 'delete-frame) #'ignore))
         (org-noter-kill-session session))
       (when (frame-live-p frame)
         (unless (doom-real-buffer-p (current-buffer))
           (switch-to-buffer (doom-fallback-buffer)))))))

  (map! :map org-noter-notes-mode-map
        :n "q" #'bhw/org-noter-quit)

  (defun bhw/org-noter-insert-precise-quote (&optional toggle-highlight)
    "Insert a quotation block from selected PDF text with org-cite reference.
With prefix argument, fall back to the original `org-noter-insert-precise-note'."
    (interactive "P")
    (if toggle-highlight
        (org-noter-insert-precise-note toggle-highlight)
      (org-noter--with-valid-session
       (let ((selected-text (run-hook-with-args-until-success
                             'org-noter-get-selected-text-hook
                             (org-noter--session-doc-mode session))))
         (if (or (null selected-text) (string-empty-p selected-text))
             (org-noter-insert-precise-note)
           (let* ((location (org-noter--doc-approx-location
                             (or (org-noter--get-precise-info) 'interactive)))
                  (page (car location))
                  (cite-key (file-name-sans-extension
                             (file-name-nondirectory
                              (org-noter--session-property-text session))))
                  (ast (org-noter--parse-root))
                  (window (org-noter--get-notes-window 'force))
                  (view-info (org-noter--get-view-info
                              (org-noter--get-current-view) location))
                  (ref (org-noter--view-info-reference-for-insertion view-info)))
             (let ((inhibit-quit t))
               (with-local-quit
                 (select-frame-set-input-focus (window-frame window))
                 (select-window window)
                 (if ref
                     (goto-char (org-element-property
                                 (if (eq (car ref) 'before) :begin :end)
                                 (cdr ref)))
                   (goto-char (or (org-element-map (org-element-contents ast)
                                      'section
                                    (lambda (s)
                                      (org-element-property :end s))
                                    nil t org-element-all-elements)
                                  (point-max))))
                 (unless (bolp) (insert "\n"))
                 (insert "\n#+BEGIN_QUOTE\n" selected-text
                         "\n" (format "[cite:@%s %s]" cite-key page)
                         "\n#+END_QUOTE\n"))
               (when quit-flag
                 (select-frame-set-input-focus (org-noter--session-frame session))
                 (select-window (get-buffer-window
                                 (org-noter--session-doc-buffer session))))))))))))
;; Org Noter Config:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Org Transclusion Config][Org Transclusion Config:1]]
;;---------------------------------------------------------------------------
(use-package! org-transclusion
  :after org
  :init
  (map! :leader :prefix "n"
        :desc "Toggle Org Transclusion Mode" "t" #'org-transclusion-mode))
;; Org Transclusion Config:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Ob Tangle Sync Config][Ob Tangle Sync Config:1]]
;;---------------------------------------------------------------------------
(load! "private-packages/ob-tangle-sync.el")
(setf org-babel-tangle-sync-files
      (list (concat +project-maria-dir+ "blog/dotemacs.org")))
(org-babel-tangle-sync-mode)
;; Ob Tangle Sync Config:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Office to Org Config][Office to Org Config:1]]
;;---------------------------------------------------------------------------
(load! "private-packages/office-to-org.el")
(office-to-org-mode +1)
;; Office to Org Config:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Org Contacts Config][Org Contacts Config:1]]
;; Require org-contacts to work with mu4e
(after! org
  (require 'org-contacts)
  (setf org-contacts-files (list (concat +project-maria-dir+ "contacts.org"))))
;; Org Contacts Config:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Org Download Config][Org Download Config:1]]
(setf org-download-method 'attach
      ;; https://www.reddit.com/r/emacs/comments/1ow0gza/some_tips_for_using_emacs_on_wsl/
      org-download-screenshot-method
      "powershell.exe -Command \"(Get-Clipboard -Format image).Save('$(wslpath -w %s)')\"")
;; Org Download Config:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Ox Publish Config][Ox Publish Config:1]]
;;---------------------------------------------------------------------------
(after! ox-publish
  ;; ox-extra's `ignore-headlines' lets us exclude a heading itself from
  ;; the ToC while still exporting its body.
  ;; https://emacs.stackexchange.com/questions/30183/orgmode-export-skip-ignore-first-headline-level
  (require 'ox-extra)
  (ox-extras-activate '(ignore-headlines))
  (require 'ox-bibtex)
  (require 'webfeeder)

  ;; https://www.taingram.org/blog/org-mode-blog.html
  (setf org-html-head-include-default-style nil
        org-html-htmlize-output-type 'css
        org-export-global-macros
        '(("timestamp" . "@@html:<span class=\"timestamp\">[$1]</span>@@"))
        org-export-with-broken-links t)

  (defun bhw/org-sitemap-date-entry-format (entry style project)
    "Format ENTRY in org-publish PROJECT Sitemap with a date prefix."
    (let ((filename (org-publish-find-title entry project)))
      (if (= (length filename) 0)
          (format "*%s*" entry)
        (format "{{{timestamp(%s)}}} [[file:%s][%s]]"
                (format-time-string "%Y-%m-%d"
                                    (org-publish-find-date entry project))
                entry
                filename))))

  (setf org-publish-project-alist
        '(("blog"
           :base-directory "~/project-maria/blog"
           :html-extension "html"
           :base-extension "org"
           :recursive t
           :publishing-function org-html-publish-to-html
           :publishing-directory "~/common-lisp/project-isidore/assets/blog"
           :section-numbers t
           :table-of-contents t
           :exclude "rss.org"
           :with-title nil
           :auto-sitemap t
           :sitemap-filename "archive.org"
           :sitemap-title "Blog Archive"
           :sitemap-sort-files anti-chronologically
           :sitemap-style tree
           :sitemap-format-entry bhw/org-sitemap-date-entry-format
           ;; https://orgmode.org/manual/HTML-doctypes.html#HTML-doctypes
           :html-doctype "html5"
           :html-html5-fancy t
           :html-head "
                      <link rel=\"stylesheet\" type=\"text/css\" href=\"../global.css\"/>
                      <link rel=\"stylesheet\"
                            href=\"//cdnjs.cloudflare.com/ajax/libs/highlight.js/11.2.0/styles/base16/solarized-light.min.css\">
                      <script src=\"//cdnjs.cloudflare.com/ajax/libs/highlight.js/11.2.0/highlight.min.js\" defer></script>
                      <script>var hlf=function(){Array.prototype.forEach.call(document.querySelectorAll(\"pre.src\"),function(t){var e;e=t.getAttribute(\"class\"),e=e.replace(/src-(\w+)/,\"src-$1 $1\"),console.log(e),t.setAttribute(\"class\",e),hljs.highlightBlock(t)})};addEventListener(\"DOMContentLoaded\",hlf);</script>"
           :html-preamble "
                                    <div class=\"header header-fixed\">
                                      <div class=\"navbar container\">
                                        <div class=\"logo\"><a href=\"/\">BHW</a></div>
                                        <input type=\"checkbox\" id=\"navbar-toggle\" >
                                        <label for=\"navbar-toggle\"><i></i></label>
                                        <nav class=\"menu\">
                                          <ul>
                                            <li><a href=\"/about\">About</a></li>
                                            <li><a href=\"/work\">Work</a></li>
                                            <li><a href=\"/assets/blog/archive.html\">Blog</a></li>
                                            <li><a href=\"/contact\">Contact</a></li>
                                          </ul>
                                        </nav>
                                      </div>
                                    </div>
                                    <h1 class=\"title\">%t</h1>
                                    <p class=\"subtitle\">%s</p> <br/>
                                    <p class=\"updated\"><a href=\"/contact#article-history\">Updated:</a> %C</p>"
           :html-postamble "<script>
                              const headers = Array.from( document.querySelectorAll('h2, h3, h4, h5, h6') );

                              headers.forEach( header => {
                                header.insertAdjacentHTML('afterbegin',
                                 '<a href=\"#table-of-contents\">&#8689;</a>'
                                );
                              });
                              </script>
                              <hr/>
                              <footer>
                                <div class=\"copyright-container\">
                                    Comments? Corrections? <a href=\"https://bhw.name/contact\"> Please do reach out.</a><a href=\"https://bhw.name/assets/blog/atom.xml\"> RSS Feed. </a><a href=\"https://bhw.name/subscribe\"> Mailing List. </a><br/>
                                    Copyright 2021 Ben H. W. <br/>
                                    Blog content is available under <a rel=\"license\" href=\"http://creativecommons.org/licenses/by-sa/4.0/\"> CC-BY-SA 4.0 </a> unless otherwise noted.<br/>
                                    Created with %c on <a href=\"https://www.gnu.org\">GNU</a>/<a href=\"https://www.kernel.org/\">Linux</a><br/>
                                </div>
                              </footer>")))

  ;; https://alhassy.github.io/AlBasmala#Clickable-Headlines
  (defun bhw/ensure-headline-ids (&rest _)
    "Give every Org tree without a CUSTOM_ID a slug derived from its heading.
Non-alphanumerics collapse to '-'. Duplicate slugs abort with `quit-flag'.

E.g., \"We'll go on a ∀∃⇅ adventure\" ↦ \"We'll-go-on-a-adventure\"."
    (interactive)
    (let ((ids))
      (org-map-entries
       (lambda ()
         (org-with-point-at (point)
           (let ((id (org-entry-get nil "CUSTOM_ID")))
             (unless id
               (thread-last (nth 4 (org-heading-components))
                            (s-replace-regexp "[^[:alnum:]']" "-")
                            (s-replace-regexp "-+" "-")
                            (s-chop-prefix "-")
                            (s-chop-suffix "-")
                            (setq id))
               (if (not (member id ids))
                   (push id ids)
                 (message-box "Oh no, a repeated id!\n\n\t%s" id)
                 (undo)
                 (setq quit-flag t))
               (org-entry-put nil "CUSTOM_ID" id))))))))
  (advice-add 'org-html-export-to-html   :before 'bhw/ensure-headline-ids)
  (advice-add 'org-md-export-to-markdown :before 'bhw/ensure-headline-ids)

  (defun bhw/publish-blog ()
    "Publish the blog project and rebuild atom.xml via webfeeder."
    (interactive)
    (org-publish "blog")
    (webfeeder-build
     "atom.xml"
     "~/common-lisp/project-isidore/assets/blog"
     "https://bhw.name/"
     ;; Skip archive.html and any temp ".#…" files when collecting feed entries.
     (remove "archive.html"
             (directory-files "~/common-lisp/project-isidore/assets/blog"
                              nil "^[^LICENSE]*\.html"))
     :title "BHW Blog"
     :description "Ben's personal blog")))
;; Ox Publish Config:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Cdlatex Config][Cdlatex Config:1]]
;;---------------------------------------------------------------------------
;; Cdlatex Config:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Python Config][Python Config:2]]
;;---------------------------------------------------------------------------
;; lsp-mode ships a built-in ty client (ty-ls) at priority -1; promote it
;; so it wins over pyright/pylsp when ty is on PATH.
(after! lsp-python-ty
  (setf (lsp--client-priority (gethash 'ty-ls lsp-clients)) 1))
;; Python Config:2 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Usage][Usage:1]]
;;---------------------------------------------------------------------------
(use-package! mu4e
  :init
  (map! :leader
        :desc "Email"           "oe" #'mu4e)
  :config
  (require 'mu4e-contrib)
  ;; https://mu-discuss.narkive.com/hXk7RbcH/set-from-address-depending-on-to-address-header
  (defun mu4e-compose-set-from-address-dwim ()
    "Set the From address based on the To address of the original. Added to
  `mu4e-compose-pre-hook'"
    (let ((msg mu4e-compose-parent-message))
      (when msg
        ;; In `mu4e-compose-set-from-address-dwim`, you are using `setf
        ;; user-mail-address`. This sets the *global* value. If you have
        ;; multiple compose buffers open, switching the account in one might
        ;; unexpectedly change the identity in another if they are not properly
        ;; isolated.
        (setq-local user-mail-address
                    (or (seq-find (lambda (addr)
                                    (mu4e-message-contact-field-matches msg :to addr))
                                  bhw/mu4e-address-routing)
                        bhw/default-mail-address)))))

  (evil-set-initial-state 'mu4e-headers-mode 'normal)
  (evil-set-initial-state 'mu4e-view-mode 'normal)
  (evil-set-initial-state 'mu4e-compose-mode 'insert)

  (setf mu4e-change-filenames-when-moving t  ; mbsync specific.
        ;; see an ASCII table for the character decimal codes

        mu4e-bookmarks '(("maildir:/INBOX" "Inbox" 105 )
                         ("\"maildir:/[Gmail]/All Mail\" and flag:unread" "Unread" 85)
                         ("\"maildir:/[Gmail]/All Mail\"" "All Mail" 97)
                         ("\"maildir:/[Gmail]/Sent Mail\"" "Sent Mail" 115))
        user-mail-address bhw/default-mail-address
        user-full-name "Ben H. W."
        ;; mu4e-compose-signature
        mail-user-agent 'mu4e-user-agent
        mu4e-attachment-dir "/mnt/c/Users/bened/Downloads/"
        mu4e-drafts-folder "/[Gmail]/Drafts"
        mu4e-sent-folder "/[Gmail]/Sent Mail"
        mu4e-trash-folder "/[Gmail]/Trash"
        mu4e-refile-folder "/[Gmail]/All Mail"
        send-mail-function 'smtpmail-send-it
        smtpmail-stream-type 'starttls
        smtpmail-default-smtp-server "smtp.gmail.com"
        smtpmail-smtp-server "smtp.gmail.com"
        smtpmail-smtp-service 587
        message-sendmail-f-is-evil t
        mu4e-index-update-in-background t
        mu4e-update-interval 3600
        mu4e-autorun-background-at-startup t
        mu4e-get-mail-command "mbsync -a"
        mu4e-hide-index-messages t
        mu4e-enable-mode-line nil
        ;; If this is enabled, prompts for new gpg fingerprints will not show up.
        ;; Instead emails will silently fail to send.
        mu4e-enable-async-operations nil
        mu4e-search-skip-duplicates t
        ;; Prefer text/plain over text/html in multipart/alternative messages.
        mm-discouraged-alternatives '("text/html" "text/richtext")
        gnus-blocked-images "."
        mu4e-org-link-query-in-headers-mode nil
        ;; mu4e-org-contacts-file (concat +project-maria-dir+ "contacts.org")
        message-kill-buffer-on-exit t
        mu4e-confirm-quit nil
        ;; mu4e-headers-time-format "%y/%m/%d %H:%M"
        ;; mu4e-headers-fields
        ;; '((:human-date . 14)
        ;;   (:from-or-to . 20)
        ;;   (:subject))
        mml-secure-openpgp-sign-with-sender t
        mml-secure-openpgp-signers '("06DDA93690F775E3715B628CCA949A6D46BC2BBE")
        mu4e-compose-complete-addresses t
        mu4e-compose-complete-only-after "2018-01-01"
        browse-url-filename-alist
        '(("^/\\(ftp@\\|anonymous@\\)?\\([^:/]+\\):/*" . "ftp://\\2/")
          ("^/\\([^:@/]+@\\)?\\([^:/]+\\):/*" . "ftp://\\1\\2/")
          ;; For gnus-article-browse-html-article on Windows Subsystem for Linux.
          ("^/+" . "file://///wsl$/Debian/"))
        mu4e-modeline-support nil
        mu4e-search-include-related nil)

  (add-hook 'mu4e-compose-pre-hook #'mu4e-compose-set-from-address-dwim)

  ;; Leave the From: header empty for brand-new messages so the sending
  ;; identity must be chosen explicitly. Replies/forwards/edits keep the
  ;; From set by `mu4e-compose-set-from-address-dwim' above. Appended (t)
  ;; so it runs after `org-msg-post-setup', which is also on this hook.
  (defun bhw/mu4e-empty-from-for-new ()
    "Empty the From: header in new (`mu4e-compose-type' = `new') buffers."
    (when (eq mu4e-compose-type 'new)
      (save-excursion
        (save-restriction
          (message-narrow-to-headers)
          (goto-char (point-min))
          (when (re-search-forward "^From:.*$" nil t)
            (replace-match "From:"))))))
  (add-hook 'mu4e-compose-mode-hook #'bhw/mu4e-empty-from-for-new t)

  ;; (add-hook
  ;;  'mu4e-headers-mode-hook
  ;;  (lambda () (define-key evil-motion-state-map (kbd "RET") nil)))
  ;; (add-hook
  ;;  'mu4e-view-mode-hook
  ;;  (lambda () (define-key evil-normal-state-map (kbd "a") nil)))

  ;; (evil-define-key 'normal mu4e-headers-mode-map
  ;;   "RET" #'mu4e-headers-view-message
  ;;   "s" #'avy-goto-word-or-subword-1
  ;;   "e" #'mu4e-headers-flag-all-read
  ;;   "E" #'mu4e-headers-mark-all)
  (map! :after mu4e
        :map mu4e-headers-mode-map
        :n "RET" #'mu4e-headers-view-message
        :n "s"   #'avy-goto-word-or-subword-1
        :n "e"   #'mu4e-headers-flag-all-read
        :n "E"   #'mu4e-headers-mark-all
        :map mu4e-view-mode-map
        :n "RET" #'browse-url-at-point
        :n "s"   #'avy-goto-word-or-subword-1
        :n "L"   #'mu4e-view-save-url
        :n "A"   #'mu4e-view-save-url))

;; Forwarded HTML bodies can contain unbalanced `<`/`>` (e.g. inside
;; `<style>` blocks), which makes `forward-sexp' under `mml-syntax-table'
;; signal `scan-error' and abort sending. The CID-image rewriting this
;; function performs is only useful when local inline images are present,
;; so fall back to the original `cont' on failure.
(defun +mml-expand-html-into-multipart-related-safe-a (orig cont)
  (condition-case nil
      (funcall orig cont)
    (scan-error cont)))
(advice-add 'mml-expand-html-into-multipart-related :around
            #'+mml-expand-html-into-multipart-related-safe-a)

;; (require 'mu4e-send-delay)
;; (use-package! mu4e-send-delay
;;   :config
;;   (advice-remove 'org-msg-ctrl-c-ctrl-c #'mu4e-send-delay-org-msg-ctrl-c-ctrl-c)
;;   (add-hook! 'mu4e-main-mode-hook 'mu4e-send-delay-setup))

(after! recentf
  (add-to-list 'recentf-exclude "~/project-jerome/email-archive/")
  (add-to-list 'recentf-exclude "/tmp/"))
;; Usage:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Consult-Mu Config][Consult-Mu Config:1]]
;;---------------------------------------------------------------------------
(use-package! consult-mu
  :after (mu4e consult)
  :init
  (map! :leader
        :desc "Search Email"    "se" #'consult-mu
        :desc "Search .emacs.d" "sE" #'+default/search-emacsd)
  :config
  (require 'consult-mu-embark)
  (require 'consult-mu-compose)
  (require 'consult-mu-compose-embark)
  (require 'consult-mu-contacts)
  (require 'consult-mu-contacts-embark)
  (consult-mu-compose-embark-bind-attach-file-key)
  (setf consult-mu-maxnum 200
        consult-mu-preview-key 'any
        consult-mu-mark-previewed-as-read nil
        consult-mu-mark-viewed-as-read t
        consult-mu-use-wide-reply 'ask
        consult-mu-headers-template
        (lambda () (concat "%f" (number-to-string (floor (* (frame-width) 0.15))) "%s" (number-to-string (floor (* (frame-width) 0.5))) "%d13" "%g" "%x"))
        consult-mu-saved-searches-async '("#flag:unread")
        consult-mu-saved-searches-dynamic '("flag:unread")
        consult-mu-compose-preview-key "M-o"
        consult-mu-embark-attach-file-key "C-a"
        consult-mu-contacts-ignore-list '("^.*no.*reply.*")
        consult-mu-contacts-ignore-case-fold-search t
        consult-mu-compose-use-dired-attachment 'in-dired))
;; Consult-Mu Config:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Application Config][Application Config:1]]
;;---------------------------------------------------------------------------
;; Application Config:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Elfeed Config][Elfeed Config:1]]
;;---------------------------------------------------------------------------
(use-package! elfeed
  :init
  (map! :leader
        :desc "Web Feed - Elfeed" "ow" #'elfeed)
  :config

  (defun elfeed-mark-all-as-read ()
    "Marks entire buffer before tagging marked region as read"
    (interactive)
    (mark-whole-buffer)
    (elfeed-search-untag-all-unread))

  (defun bhw/elfeed-search-browse-url (&optional use-generic-p)
    "Visit the current entry in your browser using `browse-url'.
  If there is a prefix argument, visit the current entry in the
  browser defined by `browse-url-generic-program'."
    (interactive "P")
    (let ((buffer (current-buffer))
          (entries (elfeed-search-selected)))
      (cl-loop for entry in entries
               for link = (elfeed-entry-link entry)
               do (elfeed-untag entry 'unread)
               when link
               do (if use-generic-p
                      (browse-url-generic link)
                    (eww link)))
      ;; `browse-url' could have switched to another buffer if eww or another
      ;; internal browser is used, but the remainder of the functions needs to
      ;; run in the elfeed buffer.
      (with-current-buffer buffer
        (mapc #'elfeed-search-update-entry entries)
        (unless (or elfeed-search-remain-on-entry (use-region-p))
          (forward-line)))))

  (defhydra bhw/hydra-elfeed (:exit t)
    ("g" (elfeed-search-set-filter "@6-months-ago +unread +gbl") "Global News")
    ("l" (elfeed-search-set-filter "@6-months-ago +unread +lcl") "Local News")
    ("s" (elfeed-search-set-filter "@6-months-ago +unread +sci") "Science & Tech")
    ("c" (elfeed-search-set-filter "@6-months-ago +unread +rel") "Catholic")
    ("f" (elfeed-search-set-filter "@6-months-ago +unread +frm") "Forums")
    ("o" (elfeed-search-set-filter "@6-months-ago +unread +pod") "Podcasts")
    ("b" (elfeed-search-set-filter "@6-months-ago +unread +blog") "Misc Blogs")
    ("y" (elfeed-search-set-filter "@6-months-ago +unread +vid") "Youtube")
    ("a" (elfeed-search-set-filter "@6-months-ago +unread") "All")
    ("q" nil "quit" :color blue))

  (add-hook 'elfeed-search-mode-hook #'elfeed-update)

  (map! :after elfeed
        :map elfeed-search-mode-map
        :n "s"  #'avy-goto-word-or-subword-1
        :n "r"  #'elfeed-mark-all-as-read
        :n "S"  #'elfeed-search-live-filter
        :n "f"  #'bhw/hydra-elfeed/body
        :n "b"  #'bhw/elfeed-search-browse-url
        :n "B"  #'elfeed-search-browse-url
        :n "R"  #'elfeed-search-update--force
        :n ";"  #'consult-line
        :map elfeed-show-mode-map
        :n "s"  #'avy-goto-word-or-subword-1
        :n "b"  #'bhw/elfeed-search-browse-url
        :n "B"  #'elfeed-search-browse-url
        :n ";"  #'consult-line))
;; Elfeed Config:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Ement Config][Ement Config:1]]
;;---------------------------------------------------------------------------
(use-package! ement
  :init
  (map! :leader
        :desc "Ement"           "oc" #'ement-notifications
        :desc "Ement (Login)"   "oC" #'ement-connect
        :desc "ement-room-view" "sc" #'ement-room-view)
  :config
  (require 'org)
  (require 'url-util)

  (defun bhw/ement-schedule-message (time-str message)
    (interactive
     (let ((msg (if (derived-mode-p 'ement-room-compose-mode)
                    (buffer-substring-no-properties (point-min) (point-max))
                  (read-string "Message to schedule: "))))
       (list (org-read-date nil nil nil "Schedule for: ")
             msg)))
    (let ((room ement-room)
          (session ement-session)
          (time (org-time-string-to-time time-str)))
      (unless (and room session)
        (user-error "Not in an Ement room context"))
      (when (time-less-p time (current-time))
        (user-error "Scheduled time must be in the future"))
      (run-at-time time nil
                   (lambda (r s m)
                     (ement-room-send-message r s :body m))
                   room session message)
      (message "Message scheduled for %s" time-str)
      (when (derived-mode-p 'ement-room-compose-mode)
        (erase-buffer)
        (kill-buffer))))

  (defun bhw/ement-mark-all-read ()
    (interactive)
    (let ((count 0))
      (dolist (session-pair ement-sessions)
        (let ((session (cdr session-pair)))
          (dolist (room (ement-session-rooms session))
            (when (ement--room-unread-p room session)
              (let* ((timeline (ement-room-timeline room))
                     (latest-event (car (last timeline))))
                (when (and latest-event (ement-event-id latest-event))
                  (cl-incf count)
                  (ement-api session
                    (format "rooms/%s/receipt/m.read/%s"
                            (url-hexify-string (ement-room-id room))
                            (url-hexify-string (ement-event-id latest-event)))
                    :method 'post
                    :then (apply-partially
                           (lambda (name _)
                             (message "Read receipt confirmed for %s" name))
                           (ement-room-display-name room))
                    :else (lambda (plz-error)
                            (message "Error marking read: %s" plz-error)))))))))
      (if (> count 0)
          (message "Sending read receipts for %d rooms..." count)
        (message "No unread rooms found."))
      (when (derived-mode-p 'ement-room-list-mode)
        (ement-room-list))))

  ;; When closing the notifications buffer, mark everything read, then tear the
  ;; sessions down to keep Ement's heap from growing while idle.  The dominant
  ;; consumer is `ement-session-events' -- a hash of every event ever seen that
  ;; is never pruned.  `ement-disconnect' only stops the long-poll sync (capping
  ;; further growth) and leaves room buffers alive, which keep buffer-local
  ;; references to the session struct and thus pin that hash; so we also
  ;; `ement-kill-buffers' to drop the last references and let it be GC'd.
  ;; We run it on a 0-delay timer so it fires *after* the buffer is gone.
  (defun bhw/ement-notifications-run-after-kill ()
    (when (derived-mode-p 'ement-notifications-mode)
      (run-at-time 0 nil
                   (lambda ()
                     ;; Dispatches read receipts synchronously across
                     ;; `ement-sessions', so it must run before we clear it.
                     (bhw/ement-mark-all-read)
                     (when ement-sessions
                       ;; The receipt POSTs are now in-flight plz processes,
                       ;; independent of the sync process, so disconnecting
                       ;; won't abort them.
                       (ement-disconnect (mapcar #'cdr ement-sessions))
                       (ement-kill-buffers))))))

  (add-hook 'ement-notifications-mode-hook
            (lambda ()
              (add-hook 'kill-buffer-hook #'bhw/ement-notifications-run-after-kill nil t)))

  (map! :after ement-room
        :map ement-room-mode-map
        :n "RET"        #'ement-room-send-message
        :n "<return>"   #'ement-room-send-message
        :n "M-RET"      #'ement-room-compose-message
        :n "<M-return>" #'ement-room-compose-message
        :n "s"     #'avy-goto-word-or-subword-1
        :n "r"     #'ement-room-write-reply
        :n "D"     #'ement-room-download-file
        :n ";"     #'ement-room-occur
        :n "gg"    #'ement-room-scroll-down-command
        :n "G"     #'ement-room-scroll-up-mark-read
        :n "m"     #'ement-room-mark-read
        :n "e"     #'ement-room-edit-message-prepare
        :n "a e"   #'ement-room-send-emote
        :n "a f"   #'ement-room-send-file
        :n "a i"   #'ement-room-send-image
        :n "a r"   #'ement-room-send-reaction)

  (add-hook 'ement-room-compose-hook 'ement-room-compose-org)
  (setf ement-save-sessions t
        ement-room-mark-rooms-read 'send
        ement-room-send-typing nil
        ement-auto-sync t
        ement-room-images t
        ement-room-image-thumbnail-height 1
        ement-room-image-thumbnail-height-min 1500)

  ;; Watchdog for silently-stalled syncs. If `ement--sync-callback' errors during
  ;; event processing, `ement-syncs' has already been cleared but the next
  ;; long-poll is never started (the call to `ement--auto-sync' is gated behind
  ;; `ement-sync-callback-hook' running, which it never does on error). Symptom:
  ;; sent messages reach the server but don't appear in the buffer until you
  ;; reconnect. The Matrix long-poll has a 30s timeout, so under healthy
  ;; conditions a callback fires at least that often; if we go noticeably longer,
  ;; force a fresh sync.
  (defvar bhw/ement-sync-watchdog-timer nil)
  (defvar bhw/ement-sync-watchdog-seconds 90)

  (defun bhw/ement-sync-watchdog-fire (session)
    (setq bhw/ement-sync-watchdog-timer nil)
    (when (and ement-auto-sync
               (memq session (mapcar #'cdr ement-sessions)))
      ;; (message "Ement: sync watchdog firing; force-resyncing %s"
      ;;          (ement-user-id (ement-session-user session)))
      ;; The forced delete-process below SIGKILLs the stalled sync; plz then
      ;; misreads signal 9 as curl exit 9 ("FTP access denied") and the dead
      ;; process's :else both signals that error and nulls `ement-syncs' for the
      ;; new sync. Neutralise its callbacks first so its deferred timer is inert.
      (when-let ((proc (map-elt ement-syncs session)))
        (when (process-live-p proc)
          (process-put proc :plz-then #'ignore)
          (process-put proc :plz-else #'ignore)))
      (condition-case err
          (ement--sync session :force t)
        (error (message "Ement: watchdog force-sync failed: %S" err)))))

  (defun bhw/ement-sync-watchdog-reset (session)
    (when (timerp bhw/ement-sync-watchdog-timer)
      (cancel-timer bhw/ement-sync-watchdog-timer))
    (setq bhw/ement-sync-watchdog-timer
          (run-at-time bhw/ement-sync-watchdog-seconds nil
                       #'bhw/ement-sync-watchdog-fire session)))

  (add-hook 'ement-sync-callback-hook #'bhw/ement-sync-watchdog-reset)

  ;; Upstream ement-room-list crashes with (wrong-type-argument number-or-marker-p nil)
  ;; when unread_notifications is present but notification_count or highlight_count is nil.
  ;; Redefine the "Unread" column to coerce nil -> 0.
  (ement-room-list-define-column
    #("Unread" 0 6 (help-echo "Unread events (Notifications:Highlights)"))
    (:align 'right)
    (pcase-let* ((`[,(cl-struct ement-room unread-notifications) ,_session] item)
                 ((map notification_count highlight_count) unread-notifications)
                 (n (or notification_count 0))
                 (h (or highlight_count 0)))
      (if (or (not unread-notifications)
              (and (zerop n) (zerop h)))
          ""
        (concat (ement-propertize (number-to-string n)
                  'face (if (zerop h) 'default 'ement-room-mention))
                ":"
                (ement-propertize (number-to-string h)
                  'face 'highlight))))))

(after! evil-collection
  (setq evil-collection-mode-list (delq 'ement evil-collection-mode-list))
  (map! :map ement-notifications-mode-map
        :n "<return>" #'ement-notifications-jump
        :n "RET"      #'ement-notifications-jump ;; Bind both to be safe
        :n "r"          #'ement-notify-reply))
;; Ement Config:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Transmission Config][Transmission Config:2]]
;;---------------------------------------------------------------------------
(use-package! transmission
  :after evil-collection
  :init
  (map! :leader
        :desc "transmission"    "oT" #'transmission)
  :config
  (evil-collection-transmission-setup)
  (map! :map transmission-mode-map
        :n "s" #'avy-goto-word-or-subword-1)
  (setf transmission-refresh-modes
        '(transmission-mode
          transmission-files-mode
          transmission-info-mode
          transmission-peers-mode)))
;; Transmission Config:2 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Shannon Key Logger Config][Shannon Key Logger Config:1]]
;;---------------------------------------------------------------------------
(add-to-list 'load-path "~/.config/emacs/.local/")
;; Defer the keylogger (and its Java subprocess) off the startup critical path;
;; 1s after Emacs goes idle is effectively immediate but doesn't block init.
(run-with-idle-timer
 1 nil
 (lambda ()
   (require 'shannon-max)
   (setq shannon-max-jar-file
         (expand-file-name "~/.config/emacs/.local/target/emacskeys-0.1.0-SNAPSHOT-standalone.jar"))
   (shannon-max-start-logger)))
;; Shannon Key Logger Config:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Calendar Config][Calendar Config:1]]
;;---------------------------------------------------------------------------
(map! :leader
      :desc "gregorian calendar" "og" #'calendar)
;; Calendar Config:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Anki Editor Config][Anki Editor Config:1]]
;;---------------------------------------------------------------------------
(use-package! anki-editor :defer t)
;; Anki Editor Config:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Biome Config][Biome Config:1]]
;;---------------------------------------------------------------------------
(use-package! biome
  :config
  (eval `(biome-def-preset meteorology-detroit-weather
           ((:name . "NOAA GFS & HRRR (U.S.)")
            (:group . "hourly")
            (:params
             ("hourly" "wind_speed_10m" "cloud_cover" "precipitation" "apparent_temperature")
             ("longitude" . ,bhw/biome-detroit-longitude)
             ("latitude"  . ,bhw/biome-detroit-latitude)))))
  (eval `(biome-def-preset meteorology-toronto-weather
           ((:name . "GEM (Canada)")
            (:group . "hourly")
            (:params
             ("hourly" "wind_speed_10m" "cloud_cover" "precipitation" "apparent_temperature")
             ("longitude" . ,bhw/biome-toronto-longitude)
             ("latitude"  . ,bhw/biome-toronto-latitude)))))
  (map! :leader
        :desc "biome" "om" #'meteorology-toronto-weather))
;; Biome Config:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Casual Emacs Calc Config][Casual Emacs Calc Config:1]]
;;---------------------------------------------------------------------------
(use-package! casual-calc
  :config
  (dolist (m (list calc-mode-map calc-alg-map))
    (map! :map m "SPC" #'doom/leader)
    (keymap-set m "C-o" #'casual-calc-tmenu)))
;; Casual Emacs Calc Config:1 ends here

;; [[file:../../project-maria/blog/dotemacs.org::*Emacs Reader Config][Emacs Reader Config:1]]
;;---------------------------------------------------------------------------
;; (add-to-list 'load-path "/usr/local/src/emacs-reader/")
;; (require 'reader-saveplace)
;; (require 'reader)
;; (add-to-list 'auto-mode-alist '("\\.docx\\'" . reader-mode))
;; (define-key reader-mode-map (kbd "d") #'reader-scroll-down-or-next-page)
;; (define-key reader-mode-map (kbd "u") #'reader-scroll-up-or-prev-page)
;; (define-key reader-mode-map (kbd "gt") #'reader-goto-page)
;; (define-key reader-mode-map (kbd "q") #'reader-close-doc)
;; (spacemacs/set-leader-keys-for-major-mode 'reader-mode "fh" 'reader-fit-to-height)
;; (spacemacs/set-leader-keys-for-major-mode 'reader-mode "fw" 'reader-fit-to-width)
;; (spacemacs/set-leader-keys-for-major-mode 'reader-mode "o" 'reader-outline-show)
;; (spacemacs/set-leader-keys-for-major-mode 'reader-mode "ss" 'reader-search-mode)
;; (load! "private-packages/emacs-reader-noter.el")
;; Emacs Reader Config:1 ends here
