;;; claude-code-ide-extensions.el --- Extra MCP tools for Claude Code IDE  -*- lexical-binding: t; -*-

;;; Commentary:

;; Extension tools for claude-code-ide that expose additional Emacs
;; functionality via MCP.  Currently provides eval-elisp.

;;; Code:

(require 'claude-code-ide-mcp-server)

;;; Tool Functions

(defun claude-code-ide-mcp-eval-elisp (expression)
  "Evaluate EXPRESSION as Elisp and return the result."
  (condition-case err
      (format "%S" (eval (car (read-from-string expression))))
    (error (format "Error: %s" (error-message-string err)))))

;;; Setup

;;;###autoload
(defun claude-code-ide-extensions-setup ()
  "Register extension MCP tools for Claude Code IDE."
  (interactive)
  (claude-code-ide-make-tool
   :function #'claude-code-ide-mcp-eval-elisp
   :name "claude-code-ide-mcp-eval-elisp"
   :description "Execute an Elisp expression in Emacs and return the result. Use this to query Emacs state, run functions, or evaluate any Elisp code."
   :args '((:name "expression"
                  :type string
                  :description "The Elisp expression to evaluate"))))

(provide 'claude-code-ide-extensions)
;;; claude-code-ide-extensions.el ends here
