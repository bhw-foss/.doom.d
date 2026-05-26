;;; ob-tangle-sync.el --- Synchronize Source Code and Org Files -*- lexical-binding: t; -*-

;; Copyright (C) 2009-2023 Free Software Foundation, Inc.

;; Author: Mehmet Tekman
;; Keywords: literate programming, reproducible research
;; URL: https://orgmode.org

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Synchronize the code between source blocks and raw source-code files.

;;; Code:

(require 'org-macs)
(org-assert-version)

(require 'ol)
(require 'org)
(require 'org-element)
(require 'ob-core)

;; --- Upstream bug fix ------------------------------------------------------
;; `org-babel-tangle-jump-to-org' (ob-tangle.el) delimits a tangled block by
;; searching *backward* from the block body for its "[[file:...][Name:N]]"
;; comment.  Its inner search sets END unconditionally, so a literal Org
;; bracket-link appearing INSIDE a code body -- e.g. a "[[file:%s][%s]]"
;; format string -- is wrongly accepted as the delimiter.  END then collapses
;; onto that line, the (< start mid end) bounds test fails, and detangle/sync
;; signals "Not in tangled code".  This override only accepts a link whose
;; matching " ... ends here" marker is actually found.  Remove if fixed
;; upstream.
(defun org-babel-tangle-sync--jump-to-org ()
  "Jump from a tangled code file to the related Org mode file.
Drop-in replacement for `org-babel-tangle-jump-to-org' that ignores stray
\"[[...]]\" links occurring inside a code body."
  (interactive)
  (let ((mid (point))
        start body-start end target-buffer target-char link block-name body)
    (save-window-excursion
      (save-excursion
        (while (and (re-search-backward org-link-bracket-re nil t)
                    (not ; ever wider searches until matching block comments
                     (and (setq start (line-beginning-position))
                          (setq body-start (line-beginning-position 2))
                          (setq link (match-string 0))
                          (setq block-name (match-string 2))
                          (save-excursion
                            (save-match-data
                              (and (re-search-forward
                                    (concat " " (regexp-quote block-name)
                                            " ends here")
                                    nil t)
                                   (setq end (line-beginning-position)))))))))
        (unless (and start (< start mid) (< mid end))
          (error "Not in tangled code"))
        (setq body (buffer-substring body-start end)))
      ;; Go to the beginning of the relative block in Org file.
      (let (org-link-search-must-match-exact-headline)
        (org-link-open-from-string link))
      (setq target-buffer (current-buffer))
      (if (string-match "[^ \t\n\r]:\\([[:digit:]]+\\)" block-name)
          (let ((n (string-to-number (match-string 1 block-name))))
            (if (org-before-first-heading-p) (goto-char (point-min))
              (org-back-to-heading t))
            (cond ((or (org-at-heading-p)
                       (not (org-element-type-p (org-element-at-point) 'src-block)))
                   (org-babel-next-src-block n))
                  ((= n 1))
                  (t (org-babel-next-src-block (1- n)))))
        (org-babel-goto-named-src-block block-name))
      (goto-char (org-babel-where-is-src-block-head))
      (forward-line 1)
      ;; Try to preserve location of point within the source code.
      (let ((offset (- mid body-start))
            (block-ends-here (org-with-point-at (org-element-end (org-element-at-point))
                               (skip-chars-backward " \t\n\r")
                               (forward-line 0)
                               (point))))
        (when (> block-ends-here (+ offset (point)))
          (forward-char offset)))
      (setq target-char (point)))
    (org-src-switch-to-buffer target-buffer t)
    (goto-char target-char)
    body))

(advice-add 'org-babel-tangle-jump-to-org :override
            #'org-babel-tangle-sync--jump-to-org)

(defgroup org-babel-tangle-sync nil
  "Options for synchronizing source code and code blocks."
  :tag "Org Babel Tangle sync"
  :group 'org-babel-tangle)

;;;###autoload
(define-minor-mode org-babel-tangle-sync-mode
  "Global minor mode that synchronizes tangled files after every save."
  :global t
  :lighter " o-ts"
  (if org-babel-tangle-sync-mode
      (add-hook 'after-save-hook 'org-babel-tangle-sync-synchronize nil t)
    (remove-hook 'after-save-hook 'org-babel-tangle-sync-synchronize t)))

(defcustom org-babel-tangle-sync-files nil
  "A list of `org-mode' files.
When `org-babel-tangle-sync-mode' is enabled only files listed
here are subject to the org-babel-tangle-sync treatment.  If nil,
then all org files with tangle headers are considered."
  :group 'org-babel-tangle-sync
  :type 'list
  :package-version '(Org . "9.6.5")
  :set (lambda (var val) (set var (mapcar #'expand-file-name val))))

(defun org-babel-tangle-sync--babel-tangle-jump (link block-name)
  "Jump from a tangled file to the Org file without returning anything.
The location of the code block in the Org file is given by a
combination of the LINK filename and header, followed by the
BLOCK-NAME Org mode source block number.  The code is borrowed
heavily from `org-babel-tangle-jump-to-org'"
  ;; Go to the beginning of the relative block in Org file.
  ;; Explicitly allow fuzzy search even if user customized
  ;; otherwise.
  (let (org-link-search-must-match-exact-headline)
    (org-link-open-from-string link))
  ;;(setq target-buffer (current-buffer))
  (if (string-match "[^ \t\n\r]:\\([[:digit:]]+\\)" block-name)
      (let ((n (string-to-number (match-string 1 block-name))))
	(if (org-before-first-heading-p) (goto-char (point-min))
	  (org-back-to-heading t))
	;; Do not skip the first block if it begins at point min.
	(cond ((or (org-at-heading-p)
		   (not (eq (org-element-type (org-element-at-point))
			    'src-block)))
	       (org-babel-next-src-block n))
	      ((= n 1))
	      (t (org-babel-next-src-block (1- n)))))
    (org-babel-goto-named-src-block block-name))
  (goto-char (org-babel-where-is-src-block-head))
  (forward-line 1))

;;;###autoload
(defun org-babel-tangle-sync-synchronize ()
  "Synchronize a tangled code block to its source-specific file, or vice versa.
If the cursor is either within the source file or in destination
tangled file, perform a desired tangling action.  The tangling
action by default is to detangle the tangled files' changes back
to its source block, or to tangle the source block to its tangled
file.  Actions are one of `skip' (no action), `import' (detangle
only), `export' (tangle only), and `both' (default, synchronize
in both directions).  All `org-mode' source blocks and all tangled
files with comments are considered valid targets, unless
specified otherwise by `org-babel-tangle-sync-files'."
  (interactive)
  (let* ((link (save-excursion
                 (re-search-backward org-link-bracket-re nil t)
		 (match-string-no-properties 0)))
         (block-name (match-string 2))
         (orgfile-p (string= major-mode "org-mode"))
         (tangled-file-p (and link (not orgfile-p))))
    ;; Tangled File → Source Block
    (if tangled-file-p
        ;; Examine the block: Get the source file and the desired tangle-sync action
        (let* ((parsed-link (with-temp-buffer
	                      (let ((org-inhibit-startup nil))
	                        (insert link)
	                        (org-mode)
	                        (goto-char (point-min))
	                        (org-element-link-parser))))
               (source-file (expand-file-name
                             (org-element-property :path parsed-link)))
               (sync-action (save-window-excursion
                              (org-babel-tangle-sync--babel-tangle-jump link block-name)
                              (alist-get :tangle-sync
                                         (nth 2 (org-babel-get-src-block-info
                                                 'no-eval))))))
          ;; De-tangle file back to source block if:
          ;; - member of sync file list (or list is empty)
          ;; - source file tangle-sync action isn't "skip" or "export",
          (if (or (null org-babel-tangle-sync-files)
                  (member source-file org-babel-tangle-sync-files))
              (cond ((string= sync-action "skip") nil)
                    ((string= sync-action "export")
                     (save-window-excursion
                       (org-babel-tangle-sync--babel-tangle-jump link block-name)
                       (let ((current-prefix-arg '(16)))
                         (call-interactively 'org-babel-tangle))
                       (message "Exported from %s" source-file)))
                    (t
                     (save-window-excursion
                       (org-babel-detangle)
                       (message "Synced to %s" source-file))))))
      ;; Source Block → Tangled File (or Source Block ← Tangled File (via "import"))
      (when orgfile-p
        ;; Tangle action of Source file on Block if:
        ;; - member of sync file list (or list is empty)
        ;; Actions
        ;; - import (Source Block ← File)
        ;; - skip (nothing)
        ;; - export, both, nil (Source Block → File)
        (if (or (null org-babel-tangle-sync-files)
                (member buffer-file-name org-babel-tangle-sync-files))
            (let* ((src-headers (nth 2 (org-babel-get-src-block-info 'no-eval)))
                   (tangle-file (cdr (assq :tangle src-headers)))
                   (tangle-action (alist-get :tangle-sync src-headers)))
              (when tangle-file
                (cond ((string= tangle-action "import") (save-excursion
                                                          (org-babel-detangle tangle-file)))
                      ((string= tangle-action "skip") nil)
                      (t (let ((current-prefix-arg '(16)))
                           (call-interactively 'org-babel-tangle)
                           ;; Revert to see changes, then re-enable the mode
                           (with-current-buffer (get-file-buffer tangle-file)
                             (revert-buffer)
                             (org-babel-tangle-sync-mode t))))))))))))

(provide 'ob-tangle-sync)

;;; ob-tangle-sync.el ends here
