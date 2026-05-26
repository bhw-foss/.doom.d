;;; document-to-org.el --- Convert .docx/.odt to org-mode  -*- lexical-binding: t; -*-

;; Author: Ben H. W.
;; Keywords: convenience, files, wp
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Read .docx (WordprocessingML) and .odt (OpenDocument Text) files and
;; render their contents as an org-mode document.  The headline feature:
;; with `document-to-org-mode' enabled, pressing RET on a .docx or .odt
;; file in a dired buffer creates a sibling .org file holding the prose,
;; headings, lists, tables and inline formatting, then visits it.
;;
;; Both formats are a ZIP of XML parts.  We extract individual members
;; with the `unzip' program and parse them with `libxml-parse-xml-region'
;; (Emacs must be built with libxml2 -- it is on this machine).  The
;; ZIP/XML plumbing and the dired integration mirror the sibling package
;; `spreadsheet-to-org.el'.
;;
;; Pipeline: each reader (`document-to-org--read-docx',
;; `document-to-org--read-odt') walks the document XML into a shared
;; intermediate block list, and `document-to-org--blocks-to-org-string'
;; renders that to org text.  Block forms:
;;
;;   (:heading LEVEL INLINE)
;;   (:paragraph INLINE)
;;   (:list-item LEVEL ORDERED INLINE)
;;   (:table ROWS)            ; ROWS = list of rows, each a list of cells
;;   (:rule)                  ; horizontal rule
;;
;; INLINE is an already-org-formatted string (bold `*', italic `/',
;; underline `_', strike `+', links `[[url][text]]').
;;
;; Usage:
;;   (load! "private-packages/document-to-org.el")
;;   (document-to-org-mode +1)
;; then press RET on a .docx/.odt in dired, or
;;   M-x document-to-org-convert-file

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'dired)

(declare-function org-table-map-tables "org-table" (function &optional quietly))
(declare-function org-table-align "org-table" ())

;;;; Customization

(defgroup document-to-org nil
  "Convert word-processor documents to org-mode."
  :group 'convenience
  :prefix "document-to-org-")

(defcustom document-to-org-extensions '("docx" "odt")
  "File extensions (lowercase, no dot) treated as convertible documents."
  :type '(repeat string))

(defcustom document-to-org-list-indent 2
  "Number of spaces of indentation per nesting level in lists."
  :type 'integer)

(defcustom document-to-org-table-first-row-header t
  "When non-nil, emit an org hline after the first row of each table."
  :type 'boolean)

(defcustom document-to-org-emit-title t
  "When non-nil, emit a `#+title:' keyword at the top of the org file.
The value is the document's stored title, falling back to its base name."
  :type 'boolean)

(defcustom document-to-org-overwrite 'prompt
  "What to do when the target .org file already exists.
`prompt' asks before regenerating; t always regenerates; nil never
regenerates (just visits the existing file)."
  :type '(choice (const :tag "Ask" prompt)
                 (const :tag "Always regenerate" t)
                 (const :tag "Never regenerate" nil)))

;;;; ZIP + XML helpers (ported from spreadsheet-to-org.el)

(defun document-to-org--unzip-member (zipfile member)
  "Return the contents of MEMBER inside ZIPFILE as a UTF-8 string, or nil."
  (with-temp-buffer
    (let* ((coding-system-for-read 'utf-8)
           (exit (call-process "unzip" nil (list t nil) nil
                               "-p" (expand-file-name zipfile) member)))
      (when (and (integerp exit) (zerop exit) (> (buffer-size) 0))
        (buffer-string)))))

(defun document-to-org--parse-xml-member (zipfile member)
  "Parse XML MEMBER of ZIPFILE into a libxml tree, or nil if absent."
  (let ((text (document-to-org--unzip-member zipfile member)))
    (when text
      (with-temp-buffer
        (insert text)
        (libxml-parse-xml-region (point-min) (point-max))))))

(defun document-to-org--local-name (tag)
  "Return the local part of TAG (a symbol or string), dropping any ns prefix."
  (let ((s (if (symbolp tag) (symbol-name tag) tag)))
    (if (string-match ":\\([^:]+\\)\\'" s)
        (match-string 1 s)
      s)))

(defun document-to-org--children (node local-name)
  "Return direct child elements of NODE whose local name equals LOCAL-NAME."
  (when (consp node)
    (cl-loop for child in (cddr node)
             when (and (consp child)
                       (symbolp (car child))
                       (string= (document-to-org--local-name (car child))
                                local-name))
             collect child)))

(defun document-to-org--child (node local-name)
  "Return the first direct child element of NODE named LOCAL-NAME, or nil."
  (car (document-to-org--children node local-name)))

(defun document-to-org--attr (node name)
  "Return the value of NODE's attribute whose local name equals NAME, or nil."
  (when (consp node)
    (cl-loop for (k . v) in (cadr node)
             when (string= (document-to-org--local-name k) name)
             return v)))

(defun document-to-org--node-text (node)
  "Concatenate all descendant text content of NODE."
  (cond
   ((stringp node) node)
   ((consp node)
    (mapconcat #'document-to-org--node-text (cddr node) ""))
   (t "")))

(defun document-to-org--descendants (node local-name &optional acc)
  "Collect, recursively, all descendant elements of NODE named LOCAL-NAME.
ACC accumulates results; the order of the returned list is unspecified."
  (when (consp node)
    (dolist (child (cddr node))
      (when (consp child)
        (when (string= (document-to-org--local-name (car child)) local-name)
          (push child acc))
        (setq acc (document-to-org--descendants child local-name acc)))))
  acc)

;;;; Inline formatting helpers

(defun document-to-org--blank-p (s)
  "Non-nil if string S is nil or contains only whitespace."
  (or (null s) (string-empty-p (string-trim s))))

(defun document-to-org--apply-markers (text markers)
  "Wrap the non-blank core of TEXT in org emphasis MARKERS.
MARKERS is a list of marker strings ordered outermost-first (e.g.
\\='(\"*\" \"_\") yields \"*_core_*\").  Leading and trailing whitespace
is kept outside the markers so org renders the emphasis."
  (if (or (null markers) (document-to-org--blank-p text))
      text
    (let* ((lead (progn (string-match "\\`[ \t\n]*" text) (match-string 0 text)))
           (trail (progn (string-match "[ \t\n]*\\'" text) (match-string 0 text)))
           (core (substring text (length lead)
                            (- (length text) (length trail)))))
      (dolist (m (reverse markers))
        (setq core (concat m core m)))
      (concat lead core trail))))

(defun document-to-org--props-to-markers (props)
  "Map a formatting PROPS plist to an ordered list of org emphasis markers.
Order is bold-outermost: bold, italic, underline, strike."
  (delq nil
        (list (and (plist-get props :bold) "*")
              (and (plist-get props :italic) "/")
              (and (plist-get props :underline) "_")
              (and (plist-get props :strike) "+"))))

(defun document-to-org--link (target description)
  "Render an org link to TARGET with DESCRIPTION (which may be blank)."
  (let ((desc (string-trim (or description ""))))
    (cond
     ((document-to-org--blank-p target) desc)
     ((string-empty-p desc) (format "[[%s]]" target))
     (t (format "[[%s][%s]]" target desc)))))

;;;; ---------------------------------------------------------------------
;;;; docx (WordprocessingML) reader
;;;; ---------------------------------------------------------------------

(defun document-to-org--docx-bool-prop (rpr name)
  "Non-nil if run-properties RPR turns on toggle property NAME.
A child element NAME is on unless its w:val is a falsey token."
  (let ((node (document-to-org--child rpr name)))
    (and node
         (let ((val (document-to-org--attr node "val")))
           (not (member val '("0" "false" "none" "off")))))))

(defun document-to-org--docx-run-markers (run)
  "Return the org emphasis markers implied by RUN's w:rPr."
  (let ((rpr (document-to-org--child run "rPr")))
    (when rpr
      (document-to-org--props-to-markers
       (list :bold (document-to-org--docx-bool-prop rpr "b")
             :italic (document-to-org--docx-bool-prop rpr "i")
             :underline (document-to-org--docx-bool-prop rpr "u")
             :strike (document-to-org--docx-bool-prop rpr "strike"))))))

(defun document-to-org--docx-run-text (run)
  "Concatenate the textual content of RUN, ignoring formatting."
  (let ((parts '()))
    (dolist (child (cddr run))
      (when (consp child)
        (pcase (document-to-org--local-name (car child))
          ("t" (push (document-to-org--node-text child) parts))
          ((or "br" "cr" "tab") (push " " parts))
          ("noBreakHyphen" (push "-" parts))
          ;; instrText/delInstrText (field codes), drawing, pict, sym: no text.
          (_ nil))))
    (apply #'concat (nreverse parts))))

(defun document-to-org--docx-run-to-string (run)
  "Render RUN to an org-formatted inline string."
  (document-to-org--apply-markers
   (document-to-org--docx-run-text run)
   (document-to-org--docx-run-markers run)))

(defun document-to-org--docx-hyperlink-target (node rels)
  "Resolve the org link target of a w:hyperlink NODE using RELS map."
  (let ((id (document-to-org--attr node "id"))
        (anchor (document-to-org--attr node "anchor")))
    (cond
     ((and id (gethash id rels)) (gethash id rels))
     (anchor (concat "*" anchor))
     (t nil))))

(defun document-to-org--docx-inline (node rels)
  "Render the inline content of run container NODE to an org string.
RELS maps relationship ids to hyperlink targets."
  (let ((parts '()))
    (dolist (child (cddr node))
      (when (consp child)
        (pcase (document-to-org--local-name (car child))
          ("r" (push (document-to-org--docx-run-to-string child) parts))
          ("hyperlink"
           (push (document-to-org--link
                  (document-to-org--docx-hyperlink-target child rels)
                  (document-to-org--docx-inline child rels))
                 parts))
          ((or "ins" "del" "smartTag")
           (push (document-to-org--docx-inline child rels) parts))
          ("sdt"
           (let ((c (document-to-org--child child "sdtContent")))
             (when c (push (document-to-org--docx-inline c rels) parts))))
          (_ nil))))
    (apply #'concat (nreverse parts))))

(defun document-to-org--docx-rels (path)
  "Return a hash of relationship Id -> Target for the docx PATH."
  (let ((rels (document-to-org--parse-xml-member
               path "word/_rels/document.xml.rels"))
        (map (make-hash-table :test 'equal)))
    (dolist (rel (document-to-org--children rels "Relationship"))
      (let ((id (document-to-org--attr rel "Id"))
            (target (document-to-org--attr rel "Target")))
        (when (and id target) (puthash id target map))))
    map))

(defun document-to-org--docx-numbering (path)
  "Return a hash numId -> (hash ilvl -> ordered-p) for the docx PATH.
Absent or unreadable numbering.xml yields an empty table."
  (let ((dom (document-to-org--parse-xml-member path "word/numbering.xml"))
        (abstracts (make-hash-table :test 'equal))
        (result (make-hash-table :test 'equal)))
    (when dom
      ;; abstractNumId -> (hash ilvl -> ordered-p)
      (dolist (an (document-to-org--children dom "abstractNum"))
        (let ((aid (document-to-org--attr an "abstractNumId"))
              (levels (make-hash-table :test 'eql)))
          (dolist (lvl (document-to-org--children an "lvl"))
            (let* ((ilvl (string-to-number
                          (or (document-to-org--attr lvl "ilvl") "0")))
                   (fmt (document-to-org--attr
                         (document-to-org--child lvl "numFmt") "val")))
              (puthash ilvl
                       (not (member fmt '(nil "bullet" "none")))
                       levels)))
          (when aid (puthash aid levels abstracts))))
      ;; numId -> abstractNumId -> levels
      (dolist (num (document-to-org--children dom "num"))
        (let ((nid (document-to-org--attr num "numId"))
              (aid (document-to-org--attr
                    (document-to-org--child num "abstractNumId") "val")))
          (when (and nid aid (gethash aid abstracts))
            (puthash nid (gethash aid abstracts) result)))))
    result))

(defun document-to-org--docx-ordered-p (numbering num-id ilvl)
  "Non-nil if list NUM-ID at level ILVL is ordered, per NUMBERING."
  (let ((levels (and num-id (gethash num-id numbering))))
    (and levels (gethash ilvl levels))))

(defun document-to-org--docx-heading-level (pstyle)
  "Return the org heading level for paragraph style id PSTYLE, or nil."
  (when pstyle
    (cond
     ((string-match "\\`Heading\\([1-9]\\)\\'" pstyle)
      (string-to-number (match-string 1 pstyle)))
     ((member pstyle '("Title" "Subtitle")) 1))))

(defun document-to-org--docx-pict-p (p)
  "Non-nil if paragraph P contains a w:pict (used here for horizontal rules)."
  (cl-some (lambda (r) (document-to-org--child r "pict"))
           (document-to-org--children p "r")))

(defun document-to-org--docx-paragraph (p numbering rels)
  "Convert paragraph node P to a block, or nil when it should be dropped."
  (let* ((ppr (document-to-org--child p "pPr"))
         (pstyle (and ppr (document-to-org--attr
                           (document-to-org--child ppr "pStyle") "val")))
         (numpr (and ppr (document-to-org--child ppr "numPr")))
         (inline (document-to-org--docx-inline p rels))
         (heading (document-to-org--docx-heading-level pstyle)))
    (cond
     ((and heading (not (document-to-org--blank-p inline)))
      (list :heading heading inline))
     (numpr
      (let* ((ilvl (string-to-number
                    (or (document-to-org--attr
                         (document-to-org--child numpr "ilvl") "val")
                        "0")))
             (num-id (document-to-org--attr
                      (document-to-org--child numpr "numId") "val")))
        (list :list-item ilvl
              (document-to-org--docx-ordered-p numbering num-id ilvl)
              inline)))
     ((and (document-to-org--blank-p inline) (document-to-org--docx-pict-p p))
      (list :rule))
     ((not (document-to-org--blank-p inline))
      (list :paragraph inline))
     (t nil))))

(defun document-to-org--docx-table (tbl rels)
  "Convert table node TBL to a (:table ROWS) block."
  (let ((rows '()))
    (dolist (tr (document-to-org--children tbl "tr"))
      (let ((cells '()))
        (dolist (tc (document-to-org--children tr "tc"))
          (push (string-trim
                 (mapconcat (lambda (p) (document-to-org--docx-inline p rels))
                            (document-to-org--children tc "p")
                            " "))
                cells))
        (push (nreverse cells) rows)))
    (list :table (nreverse rows))))

(defun document-to-org--docx-title (path)
  "Return the stored document title of docx PATH, or nil."
  (let ((dom (document-to-org--parse-xml-member path "docProps/core.xml")))
    (when dom
      (let ((title (document-to-org--node-text
                    (document-to-org--child dom "title"))))
        (unless (document-to-org--blank-p title) (string-trim title))))))

(defun document-to-org--read-docx (path)
  "Read docx file PATH into a plist (:title TITLE :blocks BLOCKS)."
  (let* ((dom (document-to-org--parse-xml-member path "word/document.xml"))
         (body (and dom (document-to-org--child dom "body")))
         (numbering (document-to-org--docx-numbering path))
         (rels (document-to-org--docx-rels path))
         (blocks '()))
    (unless body
      (error "No word/document.xml body found in %s" path))
    (dolist (child (cddr body))
      (when (consp child)
        (pcase (document-to-org--local-name (car child))
          ("p" (let ((b (document-to-org--docx-paragraph child numbering rels)))
                 (when b (push b blocks))))
          ("tbl" (push (document-to-org--docx-table child rels) blocks))
          (_ nil))))
    (list :title (document-to-org--docx-title path)
          :blocks (nreverse blocks))))

;;;; ---------------------------------------------------------------------
;;;; odt (OpenDocument Text) reader
;;;; ---------------------------------------------------------------------

(defun document-to-org--odt-text-props (style)
  "Return a formatting plist from a style:style node STYLE's text-properties."
  (let ((tp (document-to-org--child style "text-properties")))
    (when tp
      (let ((weight (document-to-org--attr tp "font-weight"))
            (slant (document-to-org--attr tp "font-style"))
            (uline (document-to-org--attr tp "text-underline-style"))
            (strike (document-to-org--attr tp "text-line-through-style")))
        (list :bold (member weight '("bold" "600" "700" "800" "900"))
              :italic (member slant '("italic" "oblique"))
              :underline (and uline (not (string= uline "none")))
              :strike (and strike (not (string= strike "none"))))))))

(defun document-to-org--odt-style-map (doms)
  "Build a style-name -> (:parent P :bold .. :italic ..) hash from DOMS.
DOMS is a list of parsed XML trees (content.xml and styles.xml)."
  (let ((map (make-hash-table :test 'equal)))
    (dolist (dom doms)
      (dolist (style (document-to-org--descendants dom "style"))
        (let ((name (document-to-org--attr style "name")))
          (when (and name (string= (or (document-to-org--attr style "family") "")
                                   "text"))
            (puthash name
                     (append (list :parent
                                   (document-to-org--attr style "parent-style-name"))
                             (document-to-org--odt-text-props style))
                     map)))))
    map))

(defun document-to-org--odt-markers (style-map name)
  "Return the org emphasis markers for text style NAME, resolving inheritance."
  (let ((props '()) (seen '()))
    (while (and name (not (member name seen)))
      (push name seen)
      (let ((entry (gethash name style-map)))
        ;; child entries lose to already-set (more specific) values
        (dolist (key '(:bold :italic :underline :strike))
          (when (and (plist-get entry key) (not (plist-get props key)))
            (setq props (plist-put props key t))))
        (setq name (plist-get entry :parent))))
    (document-to-org--props-to-markers props)))

(defun document-to-org--odt-list-styles (doms)
  "Build a list-style-name -> (hash level -> ordered-p) hash from DOMS."
  (let ((map (make-hash-table :test 'equal)))
    (dolist (dom doms)
      (dolist (ls (document-to-org--descendants dom "list-style"))
        (let ((name (document-to-org--attr ls "name"))
              (levels (make-hash-table :test 'eql)))
          (dolist (child (cddr ls))
            (when (consp child)
              (let ((lname (document-to-org--local-name (car child)))
                    (lvl (string-to-number
                          (or (document-to-org--attr child "level") "1"))))
                (cond
                 ((string= lname "list-level-style-number")
                  (puthash lvl t levels))
                 ((string= lname "list-level-style-bullet")
                  (puthash lvl nil levels))))))
          (when name (puthash name levels map)))))
    map))

(defun document-to-org--odt-inline (node style-map)
  "Render the inline content of paragraph/span NODE to an org string."
  (let ((parts '()))
    (dolist (child (cddr node))
      (cond
       ((stringp child) (push child parts))
       ((consp child)
        (pcase (document-to-org--local-name (car child))
          ("span"
           (push (document-to-org--apply-markers
                  (document-to-org--odt-inline child style-map)
                  (document-to-org--odt-markers
                   style-map (document-to-org--attr child "style-name")))
                 parts))
          ("a"
           (push (document-to-org--link
                  (document-to-org--attr child "href")
                  (document-to-org--odt-inline child style-map))
                 parts))
          ((or "line-break" "tab") (push " " parts))
          ("s" (push (make-string
                      (string-to-number
                       (or (document-to-org--attr child "c") "1"))
                      ?\s)
                     parts))
          ;; notes, bookmarks, soft page breaks: no inline text
          ((or "note" "bookmark" "bookmark-start" "bookmark-end"
               "reference-mark" "reference-mark-start" "reference-mark-end"
               "soft-page-break")
           nil)
          (_ (push (document-to-org--odt-inline child style-map) parts))))))
    (apply #'concat (nreverse parts))))

(defun document-to-org--odt-list-ordered-p (list-styles node level)
  "Non-nil if text:list NODE is ordered at LEVEL, per LIST-STYLES."
  (let* ((name (document-to-org--attr node "style-name"))
         (levels (and name (gethash name list-styles))))
    (and levels (gethash (1+ level) levels))))

(defun document-to-org--odt-list (node style-map list-styles level)
  "Convert a text:list NODE into list-item blocks at nesting LEVEL.
Each item's direct text:p/text:h becomes a line at LEVEL; a nested
text:list recurses one level deeper."
  (let ((ordered (document-to-org--odt-list-ordered-p list-styles node level))
        (blocks '()))
    (dolist (item (document-to-org--children node "list-item"))
      (dolist (sub (cddr item))
        (when (consp sub)
          (pcase (document-to-org--local-name (car sub))
            ((or "p" "h")
             (let ((inline (document-to-org--odt-inline sub style-map)))
               (unless (document-to-org--blank-p inline)
                 (push (list :list-item level ordered inline) blocks))))
            ("list"
             (dolist (b (document-to-org--odt-list
                         sub style-map list-styles (1+ level)))
               (push b blocks)))
            (_ nil)))))
    (nreverse blocks)))

(defun document-to-org--odt-collect (node style-map list-styles level)
  "Walk container NODE into a list of blocks at list nesting LEVEL."
  (let ((blocks '()))
    (dolist (child (cddr node))
      (when (consp child)
        (pcase (document-to-org--local-name (car child))
          ("h"
           (let ((inline (document-to-org--odt-inline child style-map)))
             (unless (document-to-org--blank-p inline)
               (push (list :heading
                           (max 1 (string-to-number
                                   (or (document-to-org--attr
                                        child "outline-level")
                                       "1")))
                           inline)
                     blocks))))
          ("p"
           (let ((inline (document-to-org--odt-inline child style-map)))
             (unless (document-to-org--blank-p inline)
               (push (list :paragraph inline) blocks))))
          ("list"
           (dolist (b (document-to-org--odt-list
                       child style-map list-styles level))
             (push b blocks)))
          ("table"
           (push (document-to-org--odt-table child style-map) blocks))
          (_ nil))))
    (nreverse blocks)))

(defun document-to-org--odt-table (tbl style-map)
  "Convert table:table node TBL to a (:table ROWS) block."
  (let ((rows '()))
    (dolist (tr (document-to-org--children tbl "table-row"))
      (let ((cells '()))
        (dolist (tc (document-to-org--children tr "table-cell"))
          (push (string-trim
                 (mapconcat (lambda (p) (document-to-org--odt-inline p style-map))
                            (document-to-org--children tc "p")
                            " "))
                cells))
        (push (nreverse cells) rows)))
    (list :table (nreverse rows))))

(defun document-to-org--odt-title (path)
  "Return the stored document title of odt PATH, or nil."
  (let ((dom (document-to-org--parse-xml-member path "meta.xml")))
    (when dom
      (let* ((node (car (document-to-org--descendants dom "title")))
             (title (and node (document-to-org--node-text node))))
        (unless (document-to-org--blank-p title) (string-trim title))))))

(defun document-to-org--read-odt (path)
  "Read odt file PATH into a plist (:title TITLE :blocks BLOCKS)."
  (let* ((content (document-to-org--parse-xml-member path "content.xml"))
         (styles (document-to-org--parse-xml-member path "styles.xml"))
         (doms (delq nil (list content styles)))
         (style-map (document-to-org--odt-style-map doms))
         (list-styles (document-to-org--odt-list-styles doms))
         (body (document-to-org--child content "body"))
         (text (and body (document-to-org--child body "text"))))
    (unless text
      (error "No content.xml office:text found in %s" path))
    (list :title (document-to-org--odt-title path)
          :blocks (document-to-org--odt-collect text style-map list-styles 0))))

;;;; ---------------------------------------------------------------------
;;;; Renderer: blocks -> org text
;;;; ---------------------------------------------------------------------

(defun document-to-org--escape-cell (s)
  "Make string S safe for an org table cell."
  (let ((s (or s "")))
    (setq s (replace-regexp-in-string "[\r\n\t]+" " " s))
    (setq s (replace-regexp-in-string "|" "\\\\vert{}" s))
    (string-trim s)))

(defun document-to-org--table-to-org (rows)
  "Render ROWS (list of cell-string lists) as org table text."
  (if (null rows)
      ""
    (let ((ncol (apply #'max 1 (mapcar #'length rows)))
          (lines '())
          (first t))
      (dolist (row rows)
        (let* ((padded (append row (make-list (max 0 (- ncol (length row))) "")))
               (cells (mapcar #'document-to-org--escape-cell padded)))
          (push (concat "| " (mapconcat #'identity cells " | ") " |") lines)
          (when (and first document-to-org-table-first-row-header)
            (push (concat "|" (mapconcat (lambda (_) "---")
                                         (number-sequence 1 ncol) "+")
                          "|")
                  lines))
          (setq first nil)))
      (mapconcat #'identity (nreverse lines) "\n"))))

(defun document-to-org--reset-deeper-counters (counters level)
  "Remove entries in COUNTERS for nesting levels deeper than LEVEL."
  (let ((kill '()))
    (maphash (lambda (k _v) (when (> k level) (push k kill))) counters)
    (dolist (k kill) (remhash k counters))))

(defun document-to-org--list-item-text (block counters)
  "Render list-item BLOCK to a line, updating ordered COUNTERS in place."
  (cl-destructuring-bind (_ level ordered inline) block
    (setq inline (string-trim-right inline))
    (document-to-org--reset-deeper-counters counters level)
    (let ((indent (make-string (* level document-to-org-list-indent) ?\s)))
      (if ordered
          (let ((n (1+ (gethash level counters 0))))
            (puthash level n counters)
            (format "%s%d. %s" indent n inline))
        (format "%s- %s" indent inline)))))

(defun document-to-org--block-to-text (block counters)
  "Render BLOCK to its org text, threading ordered list COUNTERS."
  (pcase (car block)
    (:heading (format "%s %s" (make-string (max 1 (nth 1 block)) ?*)
                      (string-trim-right (nth 2 block))))
    (:paragraph (string-trim-right (nth 1 block)))
    (:list-item (document-to-org--list-item-text block counters))
    (:table (document-to-org--table-to-org (nth 1 block)))
    (:rule "-----")
    (_ "")))

(defun document-to-org--blocks-to-org-string (title blocks)
  "Render BLOCKS to an org buffer string, optionally headed by TITLE."
  (let ((entries '())
        (counters (make-hash-table :test 'eql)))
    (when (and document-to-org-emit-title (not (document-to-org--blank-p title)))
      (push (cons :meta (format "#+title: %s" (string-trim title))) entries))
    (dolist (block blocks)
      (unless (eq (car block) :list-item) (clrhash counters))
      (push (cons (car block)
                  (document-to-org--block-to-text block counters))
            entries))
    (setq entries (nreverse entries))
    ;; Join with a blank line between blocks, except between adjacent
    ;; list items (which form a single list).
    (let ((out '()) (prev nil))
      (dolist (e entries)
        (when (and prev
                   (not (and (eq (car prev) :list-item)
                             (eq (car e) :list-item))))
          (push "" out))
        (push (cdr e) out)
        (setq prev e))
      (concat (mapconcat #'identity (nreverse out) "\n") "\n"))))

(defun document-to-org--align-all-tables ()
  "Align every org table in the current buffer."
  (when (derived-mode-p 'org-mode)
    (require 'org-table)
    (when (fboundp 'org-table-map-tables)
      (org-table-map-tables #'org-table-align t))))

;;;; ---------------------------------------------------------------------
;;;; Public conversion + dired integration
;;;; ---------------------------------------------------------------------

;;;###autoload
(defun document-to-org-file-p (file)
  "Non-nil if FILE has an extension in `document-to-org-extensions'."
  (and file
       (member (downcase (or (file-name-extension file) ""))
               document-to-org-extensions)
       t))

;;;###autoload
(defun document-to-org-convert-file (file &optional target)
  "Convert document FILE into an org file TARGET and visit it.
TARGET defaults to FILE with its extension replaced by \".org\".  When
TARGET already exists, `document-to-org-overwrite' decides whether to
regenerate or simply visit it."
  (interactive
   (list (or (and (derived-mode-p 'dired-mode) (dired-get-filename nil t))
             (read-file-name "Document (.docx/.odt): " nil nil t))))
  (setq file (expand-file-name file))
  (unless (file-readable-p file)
    (user-error "Cannot read file: %s" file))
  (let* ((ext (downcase (or (file-name-extension file) "")))
         (target (or target (concat (file-name-sans-extension file) ".org")))
         (proceed (or (not (file-exists-p target))
                      (pcase document-to-org-overwrite
                        ('prompt (y-or-n-p
                                  (format "%s exists.  Regenerate from %s? "
                                          (file-name-nondirectory target)
                                          (file-name-nondirectory file))))
                        ('nil nil)
                        (_ t)))))
    (if (not proceed)
        (find-file target)
      (let* ((data
              (condition-case err
                  (cond
                   ((string= ext "docx") (document-to-org--read-docx file))
                   ((string= ext "odt") (document-to-org--read-odt file))
                   (t (user-error "Unsupported extension: .%s" ext)))
                (error (user-error "Failed to convert %s: %s"
                                   (file-name-nondirectory file)
                                   (error-message-string err)))))
             (title (or (plist-get data :title) (file-name-base file)))
             (content (document-to-org--blocks-to-org-string
                       title (plist-get data :blocks)))
             (existing (find-buffer-visiting target)))
        (with-temp-file target (insert content))
        (when existing
          (with-current-buffer existing (revert-buffer t t t)))
        (let ((buf (find-file target)))
          (document-to-org--align-all-tables)
          (when (buffer-modified-p) (save-buffer))
          buf)))))

;;;###autoload
(defun document-to-org-dired-find-file ()
  "In dired, convert the file at point if convertible, else open normally."
  (interactive)
  (let ((file (dired-get-filename nil t)))
    (if (and file (document-to-org-file-p file) (not (file-directory-p file)))
        (document-to-org-convert-file file)
      (dired-find-file))))

(defun document-to-org--dired-find-file-advice (orig &rest args)
  "Around advice for `dired-find-file': intercept convertible files.
ORIG is the original function, ARGS its arguments."
  (let ((file (and (derived-mode-p 'dired-mode)
                   (dired-get-filename nil t))))
    (if (and file
             (document-to-org-file-p file)
             (not (file-directory-p file)))
        (document-to-org-convert-file file)
      (apply orig args))))

;;;###autoload
(define-minor-mode document-to-org-mode
  "Global minor mode: RET on a .docx/.odt in dired converts it to org."
  :global t
  :group 'document-to-org
  (if document-to-org-mode
      (advice-add 'dired-find-file :around
                  #'document-to-org--dired-find-file-advice)
    (advice-remove 'dired-find-file
                   #'document-to-org--dired-find-file-advice)))

(provide 'document-to-org)
;;; document-to-org.el ends here
