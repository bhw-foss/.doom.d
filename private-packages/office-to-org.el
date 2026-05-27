;;; office-to-org.el --- Convert office documents to org-mode  -*- lexical-binding: t; -*-

;; Author: Ben H. W.
;; Keywords: convenience, files, wp, data, presentations
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Read common office file formats and render their contents as org-mode,
;; then visit the result.  With `office-to-org-mode' enabled, pressing RET
;; on a convertible file in a dired buffer converts it.  Supported inputs:
;;
;;   .docx / .odt   word-processor documents   (WordprocessingML / ODT)
;;   .xlsx / .csv   spreadsheets               -> native org tables
;;   .pptx / .odp   presentations              (PresentationML / ODP)
;;
;; This package unifies three former siblings (`document-to-org',
;; `spreadsheet-to-org', `slides-to-org') that shared most of their
;; plumbing.  The shared core lives under the `office-to-org--' prefix:
;; ZIP/XML extraction, inline-formatting helpers, the OpenDocument reader
;; (text-styles, lists, tables -- identical for ODT and ODP), and the
;; block renderer.  Per-format readers walk each format's XML into a
;; common intermediate block list which the renderer turns into org text.
;;
;; The ZIP-based formats (.docx/.xlsx/.pptx and their OpenDocument peers)
;; are a ZIP of XML parts.  Individual members are extracted with the
;; `unzip' program and parsed with `libxml-parse-xml-region' (Emacs must
;; be built with libxml2 -- it is on this machine).
;;
;; Block forms:
;;
;;   (:heading LEVEL INLINE)
;;   (:paragraph INLINE)
;;   (:list-item LEVEL ORDERED INLINE)
;;   (:image RELPATH)          ; rendered as [[file:RELPATH]]
;;   (:table ROWS)             ; ROWS = list of rows, each a list of cells
;;   (:rule)                   ; horizontal rule
;;
;; INLINE is an already-org-formatted string (bold `*', italic `/',
;; underline `_', strike `+', links `[[url][text]]').
;;
;; Readers return a plist (:title TITLE :blocks BLOCKS :images IMAGES),
;; where IMAGES is an alist of (ZIP-MEMBER . RELPATH) -- non-nil only for
;; presentations, whose embedded pictures are extracted to disk.
;;
;; Output strategy depends on the format:
;;
;;   * documents and spreadsheets write a sibling .org file next to the
;;     source (FILE.docx -> FILE.org);
;;   * presentations, which carry media, write a *folder* named after the
;;     slugified base name, holding the .org file and the extracted images
;;     side-by-side, linked relatively as [[file:image1.png]]:
;;
;;       ~/Downloads/Instant Lisp + IDE + CLOG App.pptx
;;         -> ~/Downloads/instant-lisp-ide-clog-app/instant-lisp-ide-clog-app.org
;;            + image1.png, image3.png, ... in the same folder.
;;
;; Usage:
;;   (load! "private-packages/office-to-org.el")
;;   (office-to-org-mode +1)
;; then press RET on a convertible file in dired, or
;;   M-x office-to-org-convert-file

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'dired)

(declare-function org-table-map-tables "org-table" (function &optional quietly))
(declare-function org-table-align "org-table" ())
(declare-function org-display-inline-images "org" (&optional include-linked refresh beg end))

;;;; Customization

(defgroup office-to-org nil
  "Convert office documents, spreadsheets and presentations to org-mode."
  :group 'convenience
  :prefix "office-to-org-")

(defcustom office-to-org-extensions
  '("docx" "odt" "xlsx" "csv" "pptx" "odp")
  "File extensions (lowercase, no dot) treated as convertible office files."
  :type '(repeat string))

(defcustom office-to-org-list-indent 2
  "Number of spaces of indentation per nesting level in lists."
  :type 'integer)

(defcustom office-to-org-first-row-is-header t
  "When non-nil, emit an org hline after the first row of each table."
  :type 'boolean)

(defcustom office-to-org-emit-title t
  "When non-nil, emit a `#+title:' keyword at the top of the org file.
The value is the source's stored title, falling back to its base name.
Spreadsheets carry no document title and never emit this keyword."
  :type 'boolean)

(defcustom office-to-org-emit-startup-inline-images t
  "When non-nil, prepend `#+startup: inlineimages' to presentation output."
  :type 'boolean)

(defcustom office-to-org-slide-heading 'title-or-number
  "How to title each slide's top-level heading.
`title-or-number' uses the slide's own title text, falling back to
\"Slide N\"; `number' always uses \"Slide N\"."
  :type '(choice (const :tag "Slide title, else Slide N" title-or-number)
                 (const :tag "Always Slide N" number)))

(defcustom office-to-org-include-notes t
  "When non-nil, emit each slide's speaker notes under a `** Notes' subheading."
  :type 'boolean)

(defcustom office-to-org-csv-separator ?,
  "Field separator character used when parsing CSV files."
  :type 'character)

(defcustom office-to-org-date-format "%Y-%m-%d"
  "`format-time-string' format for date-styled spreadsheet cells.
Times are formatted in UTC to match the workbook's stored serials."
  :type 'string)

(defcustom office-to-org-include-time t
  "When non-nil, append \" %H:%M\" to dates whose serial has a time fraction."
  :type 'boolean)

(defcustom office-to-org-overwrite 'prompt
  "What to do when the target .org file already exists.
`prompt' asks before regenerating; t always regenerates; nil never
regenerates (just visits the existing file)."
  :type '(choice (const :tag "Ask" prompt)
                 (const :tag "Always regenerate" t)
                 (const :tag "Never regenerate" nil)))

;;;; ---------------------------------------------------------------------
;;;; Shared: ZIP + XML helpers
;;;; ---------------------------------------------------------------------

(defun office-to-org--unzip-member (zipfile member)
  "Return the contents of MEMBER inside ZIPFILE as a UTF-8 string, or nil."
  (with-temp-buffer
    (let* ((coding-system-for-read 'utf-8)
           (exit (call-process "unzip" nil (list t nil) nil
                               "-p" (expand-file-name zipfile) member)))
      (when (and (integerp exit) (zerop exit) (> (buffer-size) 0))
        (buffer-string)))))

(defun office-to-org--parse-xml-member (zipfile member)
  "Parse XML MEMBER of ZIPFILE into a libxml tree, or nil if absent."
  (let ((text (office-to-org--unzip-member zipfile member)))
    (when text
      (with-temp-buffer
        (insert text)
        (libxml-parse-xml-region (point-min) (point-max))))))

(defun office-to-org--extract-member-to-file (zipfile member dest)
  "Extract MEMBER of ZIPFILE to DEST, preserving bytes.  Return DEST or nil.
Uses no-conversion so binary images (PNG/JPEG) are written intact."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (let ((coding-system-for-read 'no-conversion))
      (when (zerop (call-process "unzip" nil (list (current-buffer) nil) nil
                                 "-p" (expand-file-name zipfile) member))
        (let ((coding-system-for-write 'no-conversion))
          (write-region (point-min) (point-max) dest nil 'silent))
        dest))))

(defun office-to-org--local-name (tag)
  "Return the local part of TAG (a symbol or string), dropping any ns prefix."
  (let ((s (if (symbolp tag) (symbol-name tag) tag)))
    (if (string-match ":\\([^:]+\\)\\'" s)
        (match-string 1 s)
      s)))

(defun office-to-org--children (node local-name)
  "Return direct child elements of NODE whose local name equals LOCAL-NAME."
  (when (consp node)
    (cl-loop for child in (cddr node)
             when (and (consp child)
                       (symbolp (car child))
                       (string= (office-to-org--local-name (car child))
                                local-name))
             collect child)))

(defun office-to-org--child (node local-name)
  "Return the first direct child element of NODE named LOCAL-NAME, or nil."
  (car (office-to-org--children node local-name)))

(defun office-to-org--attr (node name)
  "Return the value of NODE's attribute whose local name equals NAME, or nil."
  (when (consp node)
    (cl-loop for (k . v) in (cadr node)
             when (string= (office-to-org--local-name k) name)
             return v)))

(defun office-to-org--attr-qualified (node name)
  "Return NODE's attribute whose full (possibly prefixed) name equals NAME."
  (when (consp node)
    (cl-loop for (k . v) in (cadr node)
             when (string= (if (symbolp k) (symbol-name k) k) name)
             return v)))

(defun office-to-org--node-text (node)
  "Concatenate all descendant text content of NODE."
  (cond
   ((stringp node) node)
   ((consp node)
    (mapconcat #'office-to-org--node-text (cddr node) ""))
   (t "")))

(defun office-to-org--descendants (node local-name &optional acc)
  "Collect, recursively, all descendant elements of NODE named LOCAL-NAME.
ACC accumulates results; the order of the returned list is unspecified."
  (when (consp node)
    (dolist (child (cddr node))
      (when (consp child)
        (when (string= (office-to-org--local-name (car child)) local-name)
          (push child acc))
        (setq acc (office-to-org--descendants child local-name acc)))))
  acc)

;;;; Shared: ZIP path + slug helpers

(defun office-to-org--resolve-rel (base-dir target)
  "Resolve relationship TARGET against zip-internal BASE-DIR to a member path."
  (when target
    (cond
     ((string-prefix-p "/" target) (substring target 1))
     (t (let ((parts (split-string (concat (or base-dir "") target) "/" t))
              (out '()))
          (dolist (p parts)
            (cond ((string= p ".") nil)
                  ((string= p "..") (pop out))
                  (t (push p out))))
          (mapconcat #'identity (nreverse out) "/"))))))

(defun office-to-org--rels-path (member)
  "Return the relationship-file member path for the part MEMBER."
  (concat (file-name-directory member) "_rels/"
          (file-name-nondirectory member) ".rels"))

(defun office-to-org--slugify (name)
  "Slugify NAME: downcase, non-alphanumeric runs to \"-\", trim ends."
  (let* ((down (downcase (or name "")))
         (s (replace-regexp-in-string "[^a-z0-9]+" "-" down))
         (s (replace-regexp-in-string "\\`-+\\|-+\\'" "" s)))
    (if (string-empty-p s) "slides" s)))

(defun office-to-org--register-image (images member)
  "Return the output relpath for MEMBER, registering it in IMAGES (member->relpath).
On basename collision with a different member, append a numeric suffix."
  (or (gethash member images)
      (let* ((base (file-name-nondirectory member))
             (relpath base)
             (n 1))
        (while (cl-find relpath (hash-table-values images) :test #'string=)
          (setq relpath (format "%s-%d%s"
                                (file-name-sans-extension base) n
                                (let ((e (file-name-extension base)))
                                  (if e (concat "." e) ""))))
          (setq n (1+ n)))
        (puthash member relpath images)
        relpath)))

;;;; Shared: inline formatting helpers

(defun office-to-org--blank-p (s)
  "Non-nil if string S is nil or contains only whitespace."
  (or (null s) (string-empty-p (string-trim s))))

(defun office-to-org--apply-markers (text markers)
  "Wrap the non-blank core of TEXT in org emphasis MARKERS.
MARKERS is a list of marker strings ordered outermost-first (e.g.
\\='(\"*\" \"_\") yields \"*_core_*\").  Leading and trailing whitespace
is kept outside the markers so org renders the emphasis."
  (if (or (null markers) (office-to-org--blank-p text))
      text
    (let* ((lead (progn (string-match "\\`[ \t\n]*" text) (match-string 0 text)))
           (trail (progn (string-match "[ \t\n]*\\'" text) (match-string 0 text)))
           (core (substring text (length lead)
                            (- (length text) (length trail)))))
      (dolist (m (reverse markers))
        (setq core (concat m core m)))
      (concat lead core trail))))

(defun office-to-org--props-to-markers (props)
  "Map a formatting PROPS plist to an ordered list of org emphasis markers.
Order is bold-outermost: bold, italic, underline, strike."
  (delq nil
        (list (and (plist-get props :bold) "*")
              (and (plist-get props :italic) "/")
              (and (plist-get props :underline) "_")
              (and (plist-get props :strike) "+"))))

(defun office-to-org--link (target description)
  "Render an org link to TARGET with DESCRIPTION (which may be blank)."
  (let ((desc (string-trim (or description ""))))
    (cond
     ((office-to-org--blank-p target) desc)
     ((string-empty-p desc) (format "[[%s]]" target))
     (t (format "[[%s][%s]]" target desc)))))

;;;; Shared: title helpers

(defun office-to-org--ooxml-core-title (path)
  "Return the stored title from docProps/core.xml of OOXML file PATH, or nil.
Shared by the .docx and .pptx readers."
  (let ((dom (office-to-org--parse-xml-member path "docProps/core.xml")))
    (when dom
      (let ((title (office-to-org--node-text
                    (office-to-org--child dom "title"))))
        (unless (office-to-org--blank-p title) (string-trim title))))))

(defun office-to-org--odt-title (path)
  "Return the stored title from meta.xml of OpenDocument file PATH, or nil.
Shared by the .odt and .odp readers."
  (let ((dom (office-to-org--parse-xml-member path "meta.xml")))
    (when dom
      (let* ((node (car (office-to-org--descendants dom "title")))
             (title (and node (office-to-org--node-text node))))
        (unless (office-to-org--blank-p title) (string-trim title))))))

;;;; ---------------------------------------------------------------------
;;;; Shared: OpenDocument (ODT/ODP) reader helpers
;;;; ---------------------------------------------------------------------

(defun office-to-org--odt-text-props (style)
  "Return a formatting plist from a style:style node STYLE's text-properties."
  (let ((tp (office-to-org--child style "text-properties")))
    (when tp
      (let ((weight (office-to-org--attr tp "font-weight"))
            (slant (office-to-org--attr tp "font-style"))
            (uline (office-to-org--attr tp "text-underline-style"))
            (strike (office-to-org--attr tp "text-line-through-style")))
        (list :bold (member weight '("bold" "600" "700" "800" "900"))
              :italic (member slant '("italic" "oblique"))
              :underline (and uline (not (string= uline "none")))
              :strike (and strike (not (string= strike "none"))))))))

(defun office-to-org--odt-style-map (doms)
  "Build a style-name -> (:parent P :bold .. :italic ..) hash from DOMS.
DOMS is a list of parsed XML trees (content.xml and styles.xml)."
  (let ((map (make-hash-table :test 'equal)))
    (dolist (dom doms)
      (dolist (style (office-to-org--descendants dom "style"))
        (let ((name (office-to-org--attr style "name")))
          (when (and name (string= (or (office-to-org--attr style "family") "")
                                   "text"))
            (puthash name
                     (append (list :parent
                                   (office-to-org--attr style "parent-style-name"))
                             (office-to-org--odt-text-props style))
                     map)))))
    map))

(defun office-to-org--odt-markers (style-map name)
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
    (office-to-org--props-to-markers props)))

(defun office-to-org--odt-list-styles (doms)
  "Build a list-style-name -> (hash level -> ordered-p) hash from DOMS."
  (let ((map (make-hash-table :test 'equal)))
    (dolist (dom doms)
      (dolist (ls (office-to-org--descendants dom "list-style"))
        (let ((name (office-to-org--attr ls "name"))
              (levels (make-hash-table :test 'eql)))
          (dolist (child (cddr ls))
            (when (consp child)
              (let ((lname (office-to-org--local-name (car child)))
                    (lvl (string-to-number
                          (or (office-to-org--attr child "level") "1"))))
                (cond
                 ((string= lname "list-level-style-number")
                  (puthash lvl t levels))
                 ((string= lname "list-level-style-bullet")
                  (puthash lvl nil levels))))))
          (when name (puthash name levels map)))))
    map))

(defun office-to-org--odt-inline (node style-map)
  "Render the inline content of paragraph/span NODE to an org string."
  (let ((parts '()))
    (dolist (child (cddr node))
      (cond
       ((stringp child) (push child parts))
       ((consp child)
        (pcase (office-to-org--local-name (car child))
          ("span"
           (push (office-to-org--apply-markers
                  (office-to-org--odt-inline child style-map)
                  (office-to-org--odt-markers
                   style-map (office-to-org--attr child "style-name")))
                 parts))
          ("a"
           (push (office-to-org--link
                  (office-to-org--attr child "href")
                  (office-to-org--odt-inline child style-map))
                 parts))
          ((or "line-break" "tab") (push " " parts))
          ("s" (push (make-string
                      (string-to-number
                       (or (office-to-org--attr child "c") "1"))
                      ?\s)
                     parts))
          ;; notes, bookmarks, soft page breaks: no inline text
          ((or "note" "bookmark" "bookmark-start" "bookmark-end"
               "reference-mark" "reference-mark-start" "reference-mark-end"
               "soft-page-break")
           nil)
          (_ (push (office-to-org--odt-inline child style-map) parts))))))
    (apply #'concat (nreverse parts))))

(defun office-to-org--odt-list-ordered-p (list-styles node level)
  "Non-nil if text:list NODE is ordered at LEVEL, per LIST-STYLES."
  (let* ((name (office-to-org--attr node "style-name"))
         (levels (and name (gethash name list-styles))))
    (and levels (gethash (1+ level) levels))))

(defun office-to-org--odt-list (node style-map list-styles level)
  "Convert a text:list NODE into list-item blocks at nesting LEVEL.
Each item's direct text:p/text:h becomes a line at LEVEL; a nested
text:list recurses one level deeper."
  (let ((ordered (office-to-org--odt-list-ordered-p list-styles node level))
        (blocks '()))
    (dolist (item (office-to-org--children node "list-item"))
      (dolist (sub (cddr item))
        (when (consp sub)
          (pcase (office-to-org--local-name (car sub))
            ((or "p" "h")
             (let ((inline (office-to-org--odt-inline sub style-map)))
               (unless (office-to-org--blank-p inline)
                 (push (list :list-item level ordered inline) blocks))))
            ("list"
             (dolist (b (office-to-org--odt-list
                         sub style-map list-styles (1+ level)))
               (push b blocks)))
            (_ nil)))))
    (nreverse blocks)))

(defun office-to-org--odt-table (tbl style-map)
  "Convert table:table node TBL to a (:table ROWS) block."
  (let ((rows '()))
    (dolist (tr (office-to-org--children tbl "table-row"))
      (let ((cells '()))
        (dolist (tc (office-to-org--children tr "table-cell"))
          (push (string-trim
                 (mapconcat (lambda (p) (office-to-org--odt-inline p style-map))
                            (office-to-org--children tc "p")
                            " "))
                cells))
        (push (nreverse cells) rows)))
    (list :table (nreverse rows))))

;;;; ---------------------------------------------------------------------
;;;; docx (WordprocessingML) reader
;;;; ---------------------------------------------------------------------

(defun office-to-org--docx-bool-prop (rpr name)
  "Non-nil if run-properties RPR turns on toggle property NAME.
A child element NAME is on unless its w:val is a falsey token."
  (let ((node (office-to-org--child rpr name)))
    (and node
         (let ((val (office-to-org--attr node "val")))
           (not (member val '("0" "false" "none" "off")))))))

(defun office-to-org--docx-run-markers (run)
  "Return the org emphasis markers implied by RUN's w:rPr."
  (let ((rpr (office-to-org--child run "rPr")))
    (when rpr
      (office-to-org--props-to-markers
       (list :bold (office-to-org--docx-bool-prop rpr "b")
             :italic (office-to-org--docx-bool-prop rpr "i")
             :underline (office-to-org--docx-bool-prop rpr "u")
             :strike (office-to-org--docx-bool-prop rpr "strike"))))))

(defun office-to-org--docx-run-text (run)
  "Concatenate the textual content of RUN, ignoring formatting."
  (let ((parts '()))
    (dolist (child (cddr run))
      (when (consp child)
        (pcase (office-to-org--local-name (car child))
          ("t" (push (office-to-org--node-text child) parts))
          ((or "br" "cr" "tab") (push " " parts))
          ("noBreakHyphen" (push "-" parts))
          ;; instrText/delInstrText (field codes), drawing, pict, sym: no text.
          (_ nil))))
    (apply #'concat (nreverse parts))))

(defun office-to-org--docx-run-to-string (run)
  "Render RUN to an org-formatted inline string."
  (office-to-org--apply-markers
   (office-to-org--docx-run-text run)
   (office-to-org--docx-run-markers run)))

(defun office-to-org--docx-hyperlink-target (node rels)
  "Resolve the org link target of a w:hyperlink NODE using RELS map."
  (let ((id (office-to-org--attr node "id"))
        (anchor (office-to-org--attr node "anchor")))
    (cond
     ((and id (gethash id rels)) (gethash id rels))
     (anchor (concat "*" anchor))
     (t nil))))

(defun office-to-org--docx-inline (node rels)
  "Render the inline content of run container NODE to an org string.
RELS maps relationship ids to hyperlink targets."
  (let ((parts '()))
    (dolist (child (cddr node))
      (when (consp child)
        (pcase (office-to-org--local-name (car child))
          ("r" (push (office-to-org--docx-run-to-string child) parts))
          ("hyperlink"
           (push (office-to-org--link
                  (office-to-org--docx-hyperlink-target child rels)
                  (office-to-org--docx-inline child rels))
                 parts))
          ((or "ins" "del" "smartTag")
           (push (office-to-org--docx-inline child rels) parts))
          ("sdt"
           (let ((c (office-to-org--child child "sdtContent")))
             (when c (push (office-to-org--docx-inline c rels) parts))))
          (_ nil))))
    (apply #'concat (nreverse parts))))

(defun office-to-org--docx-rels (path)
  "Return a hash of relationship Id -> Target for the docx PATH."
  (let ((rels (office-to-org--parse-xml-member
               path "word/_rels/document.xml.rels"))
        (map (make-hash-table :test 'equal)))
    (dolist (rel (office-to-org--children rels "Relationship"))
      (let ((id (office-to-org--attr rel "Id"))
            (target (office-to-org--attr rel "Target")))
        (when (and id target) (puthash id target map))))
    map))

(defun office-to-org--docx-numbering (path)
  "Return a hash numId -> (hash ilvl -> ordered-p) for the docx PATH.
Absent or unreadable numbering.xml yields an empty table."
  (let ((dom (office-to-org--parse-xml-member path "word/numbering.xml"))
        (abstracts (make-hash-table :test 'equal))
        (result (make-hash-table :test 'equal)))
    (when dom
      ;; abstractNumId -> (hash ilvl -> ordered-p)
      (dolist (an (office-to-org--children dom "abstractNum"))
        (let ((aid (office-to-org--attr an "abstractNumId"))
              (levels (make-hash-table :test 'eql)))
          (dolist (lvl (office-to-org--children an "lvl"))
            (let* ((ilvl (string-to-number
                          (or (office-to-org--attr lvl "ilvl") "0")))
                   (fmt (office-to-org--attr
                         (office-to-org--child lvl "numFmt") "val")))
              (puthash ilvl
                       (not (member fmt '(nil "bullet" "none")))
                       levels)))
          (when aid (puthash aid levels abstracts))))
      ;; numId -> abstractNumId -> levels
      (dolist (num (office-to-org--children dom "num"))
        (let ((nid (office-to-org--attr num "numId"))
              (aid (office-to-org--attr
                    (office-to-org--child num "abstractNumId") "val")))
          (when (and nid aid (gethash aid abstracts))
            (puthash nid (gethash aid abstracts) result)))))
    result))

(defun office-to-org--docx-ordered-p (numbering num-id ilvl)
  "Non-nil if list NUM-ID at level ILVL is ordered, per NUMBERING."
  (let ((levels (and num-id (gethash num-id numbering))))
    (and levels (gethash ilvl levels))))

(defun office-to-org--docx-heading-level (pstyle)
  "Return the org heading level for paragraph style id PSTYLE, or nil."
  (when pstyle
    (cond
     ((string-match "\\`Heading\\([1-9]\\)\\'" pstyle)
      (string-to-number (match-string 1 pstyle)))
     ((member pstyle '("Title" "Subtitle")) 1))))

(defun office-to-org--docx-pict-p (p)
  "Non-nil if paragraph P contains a w:pict (used here for horizontal rules)."
  (cl-some (lambda (r) (office-to-org--child r "pict"))
           (office-to-org--children p "r")))

(defun office-to-org--docx-paragraph (p numbering rels)
  "Convert paragraph node P to a block, or nil when it should be dropped."
  (let* ((ppr (office-to-org--child p "pPr"))
         (pstyle (and ppr (office-to-org--attr
                           (office-to-org--child ppr "pStyle") "val")))
         (numpr (and ppr (office-to-org--child ppr "numPr")))
         (inline (office-to-org--docx-inline p rels))
         (heading (office-to-org--docx-heading-level pstyle)))
    (cond
     ((and heading (not (office-to-org--blank-p inline)))
      (list :heading heading inline))
     (numpr
      (let* ((ilvl (string-to-number
                    (or (office-to-org--attr
                         (office-to-org--child numpr "ilvl") "val")
                        "0")))
             (num-id (office-to-org--attr
                      (office-to-org--child numpr "numId") "val")))
        (list :list-item ilvl
              (office-to-org--docx-ordered-p numbering num-id ilvl)
              inline)))
     ((and (office-to-org--blank-p inline) (office-to-org--docx-pict-p p))
      (list :rule))
     ((not (office-to-org--blank-p inline))
      (list :paragraph inline))
     (t nil))))

(defun office-to-org--docx-table (tbl rels)
  "Convert table node TBL to a (:table ROWS) block."
  (let ((rows '()))
    (dolist (tr (office-to-org--children tbl "tr"))
      (let ((cells '()))
        (dolist (tc (office-to-org--children tr "tc"))
          (push (string-trim
                 (mapconcat (lambda (p) (office-to-org--docx-inline p rels))
                            (office-to-org--children tc "p")
                            " "))
                cells))
        (push (nreverse cells) rows)))
    (list :table (nreverse rows))))

(defun office-to-org--read-docx (path)
  "Read docx file PATH into a plist (:title :blocks :images)."
  (let* ((dom (office-to-org--parse-xml-member path "word/document.xml"))
         (body (and dom (office-to-org--child dom "body")))
         (numbering (office-to-org--docx-numbering path))
         (rels (office-to-org--docx-rels path))
         (blocks '()))
    (unless body
      (error "No word/document.xml body found in %s" path))
    (dolist (child (cddr body))
      (when (consp child)
        (pcase (office-to-org--local-name (car child))
          ("p" (let ((b (office-to-org--docx-paragraph child numbering rels)))
                 (when b (push b blocks))))
          ("tbl" (push (office-to-org--docx-table child rels) blocks))
          (_ nil))))
    (list :title (office-to-org--ooxml-core-title path)
          :blocks (nreverse blocks)
          :images nil)))

;;;; ---------------------------------------------------------------------
;;;; odt (OpenDocument Text) reader
;;;; ---------------------------------------------------------------------

(defun office-to-org--odt-collect (node style-map list-styles level)
  "Walk container NODE into a list of blocks at list nesting LEVEL."
  (let ((blocks '()))
    (dolist (child (cddr node))
      (when (consp child)
        (pcase (office-to-org--local-name (car child))
          ("h"
           (let ((inline (office-to-org--odt-inline child style-map)))
             (unless (office-to-org--blank-p inline)
               (push (list :heading
                           (max 1 (string-to-number
                                   (or (office-to-org--attr
                                        child "outline-level")
                                       "1")))
                           inline)
                     blocks))))
          ("p"
           (let ((inline (office-to-org--odt-inline child style-map)))
             (unless (office-to-org--blank-p inline)
               (push (list :paragraph inline) blocks))))
          ("list"
           (dolist (b (office-to-org--odt-list
                       child style-map list-styles level))
             (push b blocks)))
          ("table"
           (push (office-to-org--odt-table child style-map) blocks))
          (_ nil))))
    (nreverse blocks)))

(defun office-to-org--read-odt (path)
  "Read odt file PATH into a plist (:title :blocks :images)."
  (let* ((content (office-to-org--parse-xml-member path "content.xml"))
         (styles (office-to-org--parse-xml-member path "styles.xml"))
         (doms (delq nil (list content styles)))
         (style-map (office-to-org--odt-style-map doms))
         (list-styles (office-to-org--odt-list-styles doms))
         (body (office-to-org--child content "body"))
         (text (and body (office-to-org--child body "text"))))
    (unless text
      (error "No content.xml office:text found in %s" path))
    (list :title (office-to-org--odt-title path)
          :blocks (office-to-org--odt-collect text style-map list-styles 0)
          :images nil)))

;;;; ---------------------------------------------------------------------
;;;; xlsx (SpreadsheetML) reader
;;;; ---------------------------------------------------------------------

(defun office-to-org--col-of-ref (ref)
  "Return the 1-based column index encoded by an A1 cell REF (e.g. \"C3\" -> 3)."
  (let ((col 0) (done nil))
    (when ref
      (cl-loop for ch across ref
               until done
               do (cond
                   ((and (>= ch ?A) (<= ch ?Z)) (setq col (+ (* col 26) (- ch ?A -1))))
                   ((and (>= ch ?a) (<= ch ?z)) (setq col (+ (* col 26) (- ch ?a -1))))
                   (t (setq done t)))))
    col))

(defun office-to-org--excel-serial-to-string (serial)
  "Convert an Excel SERIAL date (1900 system) to a formatted string.
Uses the epoch 1899-12-30, correct for all modern dates."
  (let* ((base (encode-time (list 0 0 0 30 12 1899 nil -1 t)))
         (secs (round (* serial 86400)))
         (tm (time-add base secs))
         (frac (- serial (floor serial))))
    (format-time-string
     (if (and office-to-org-include-time (> frac 0))
         (concat office-to-org-date-format " %H:%M")
       office-to-org-date-format)
     tm t)))

(defun office-to-org--read-styles (zipfile)
  "Read xl/styles.xml from ZIPFILE into a plist (:num-fmts HASH :cell-xfs VEC)."
  (let ((dom (office-to-org--parse-xml-member zipfile "xl/styles.xml"))
        (num-fmts (make-hash-table :test 'eql))
        (cell-xfs '()))
    (when dom
      (let ((nfs (office-to-org--child dom "numFmts")))
        (dolist (nf (office-to-org--children nfs "numFmt"))
          (let ((id (office-to-org--attr nf "numFmtId"))
                (code (office-to-org--attr nf "formatCode")))
            (when id (puthash (string-to-number id) code num-fmts)))))
      (let ((xfs (office-to-org--child dom "cellXfs")))
        (dolist (xf (office-to-org--children xfs "xf"))
          (let ((nid (office-to-org--attr xf "numFmtId")))
            (push (if nid (string-to-number nid) 0) cell-xfs)))))
    (list :num-fmts num-fmts :cell-xfs (vconcat (nreverse cell-xfs)))))

(defun office-to-org--date-format-code-p (code)
  "Heuristic: non-nil if format CODE represents a date/time."
  (when (stringp code)
    (let ((c (downcase code)))
      (or (string-match-p "yy" c) (string-match-p "mm" c)
          (string-match-p "dd" c) (string-match-p "hh" c)
          (string-match-p "ss" c) (string-match-p "m/d" c)
          (string-match-p "d-m" c)))))

(defun office-to-org--date-style-p (styles style-id)
  "Non-nil if STYLE-ID in STYLES designates a date number format."
  (when (and styles style-id)
    (let ((xfs (plist-get styles :cell-xfs))
          (num-fmts (plist-get styles :num-fmts)))
      (when (and (>= style-id 0) (< style-id (length xfs)))
        (let ((nid (aref xfs style-id)))
          (or (and (>= nid 14) (<= nid 22))
              (and (>= nid 45) (<= nid 47))
              (office-to-org--date-format-code-p (gethash nid num-fmts))))))))

(defun office-to-org--si-text (node)
  "Concatenate text of all <t> elements within NODE (handles rich-text runs)."
  (let ((parts '()))
    (dolist (tn (office-to-org--children node "t"))
      (push (office-to-org--node-text tn) parts))
    (dolist (r (office-to-org--children node "r"))
      (dolist (tn (office-to-org--children r "t"))
        (push (office-to-org--node-text tn) parts)))
    (apply #'concat (nreverse parts))))

(defun office-to-org--read-shared-strings (zipfile)
  "Read xl/sharedStrings.xml from ZIPFILE into a vector of strings."
  (let ((dom (office-to-org--parse-xml-member zipfile "xl/sharedStrings.xml"))
        (items '()))
    (dolist (si (office-to-org--children dom "si"))
      (push (office-to-org--si-text si) items))
    (vconcat (nreverse items))))

(defun office-to-org--render-number (raw style-id styles)
  "Render numeric RAW string, converting to a date when STYLE-ID is a date style."
  (if (office-to-org--date-style-p styles style-id)
      (office-to-org--excel-serial-to-string (string-to-number raw))
    raw))

(defun office-to-org--cell-value (c shared-strings styles)
  "Return the display string for cell node C."
  (let* ((type (or (office-to-org--attr c "t") "n"))
         (s-attr (office-to-org--attr c "s"))
         (style-id (and s-attr (string-to-number s-attr)))
         (v (office-to-org--child c "v")))
    (cond
     ((string= type "s")
      (let ((idx (and v (string-to-number (office-to-org--node-text v)))))
        (if (and idx (>= idx 0) (< idx (length shared-strings)))
            (aref shared-strings idx)
          "")))
     ((string= type "inlineStr")
      (let ((is (office-to-org--child c "is")))
        (if is (office-to-org--si-text is) "")))
     ((string= type "str") (if v (office-to-org--node-text v) ""))
     ((string= type "b")
      (if (and v (string= (office-to-org--node-text v) "1")) "TRUE" "FALSE"))
     ((string= type "e") (if v (office-to-org--node-text v) ""))
     (t
      (let ((raw (and v (office-to-org--node-text v))))
        (if (and raw (> (length raw) 0))
            (office-to-org--render-number raw style-id styles)
          ""))))))

(defun office-to-org--row-empty-p (row)
  "Non-nil if every cell of ROW is blank after trimming."
  (cl-every (lambda (cell) (string= (string-trim cell) "")) row))

(defun office-to-org--trim-empty-rows (rows)
  "Drop trailing all-empty rows from ROWS."
  (let ((rev (reverse rows)))
    (while (and rev (office-to-org--row-empty-p (car rev)))
      (setq rev (cdr rev)))
    (nreverse rev)))

(defun office-to-org--trim-empty-cols (rows)
  "Drop trailing columns of ROWS that are blank in every row.
Interior empty columns are kept so data positions are preserved."
  (if (null rows)
      rows
    (let* ((ncol (apply #'max 0 (mapcar #'length rows)))
           (keep ncol))
      (while (and (> keep 0)
                  (cl-every (lambda (r)
                              (let ((cell (nth (1- keep) r)))
                                (or (null cell) (string= (string-trim cell) ""))))
                            rows))
        (setq keep (1- keep)))
      (if (= keep ncol)
          rows
        (mapcar (lambda (r) (seq-take r keep)) rows)))))

(defun office-to-org--read-sheet-grid (zipfile sheet-path shared-strings styles)
  "Read worksheet SHEET-PATH in ZIPFILE into a rectangular list of string rows."
  (let* ((dom (office-to-org--parse-xml-member zipfile sheet-path))
         (sheet-data (and dom (office-to-org--child dom "sheetData")))
         (rows '())
         (max-col 0)
         (last-row 0))
    (dolist (row-node (office-to-org--children sheet-data "row"))
      (let* ((r-attr (office-to-org--attr row-node "r"))
             (rnum (if r-attr (string-to-number r-attr) (1+ last-row))))
        ;; Fill gaps between rows with empty rows.
        (when (> rnum (1+ last-row))
          (dotimes (_ (- rnum last-row 1)) (push nil rows)))
        (setq last-row rnum)
        (let ((cells '()) (last-col 0))
          (dolist (c (office-to-org--children row-node "c"))
            (let* ((ref (office-to-org--attr c "r"))
                   (col (if ref (office-to-org--col-of-ref ref) (1+ last-col))))
              (when (> col (1+ last-col))
                (dotimes (_ (- col last-col 1)) (push "" cells)))
              (setq last-col col)
              (push (office-to-org--cell-value c shared-strings styles) cells)))
          (setq cells (nreverse cells))
          (setq max-col (max max-col (length cells)))
          (push cells rows))))
    (setq rows (nreverse rows))
    (setq rows (mapcar (lambda (r)
                         (append r (make-list (max 0 (- max-col (length r))) "")))
                       rows))
    (office-to-org--trim-empty-cols
     (office-to-org--trim-empty-rows rows))))

(defun office-to-org--resolve-target (target)
  "Resolve a workbook-relationship TARGET to a path inside the ZIP."
  (when target
    (cond
     ((string-prefix-p "/" target) (substring target 1))
     ((string-prefix-p "../" target) (concat "xl/" (substring target 3)))
     (t (concat "xl/" target)))))

(defun office-to-org--xlsx-sheets (path)
  "Read xlsx file PATH into a list of (SHEET-NAME . GRID) pairs in workbook order."
  (let* ((wb (office-to-org--parse-xml-member path "xl/workbook.xml"))
         (rels (office-to-org--parse-xml-member path "xl/_rels/workbook.xml.rels"))
         (rel-map (make-hash-table :test 'equal))
         (shared (office-to-org--read-shared-strings path))
         (styles (office-to-org--read-styles path))
         (result '()))
    (unless wb
      (error "No xl/workbook.xml found in %s" path))
    (dolist (rel (office-to-org--children rels "Relationship"))
      (let ((id (office-to-org--attr rel "Id"))
            (target (office-to-org--attr rel "Target")))
        (when (and id target) (puthash id target rel-map))))
    (let ((sheets-node (office-to-org--child wb "sheets")))
      (dolist (sheet (office-to-org--children sheets-node "sheet"))
        (let* ((name (or (office-to-org--attr sheet "name") "Sheet"))
               (rid (office-to-org--attr sheet "id"))   ; local name of r:id
               (target (and rid (gethash rid rel-map)))
               (sheet-path (office-to-org--resolve-target target)))
          (when sheet-path
            (push (cons name (office-to-org--read-sheet-grid
                              path sheet-path shared styles))
                  result)))))
    (nreverse result)))

(defun office-to-org--read-xlsx (path)
  "Read xlsx file PATH into a plist (:title :blocks :images)."
  (list :title nil
        :blocks (office-to-org--sheets-to-blocks (office-to-org--xlsx-sheets path))
        :images nil))

;;;; ---------------------------------------------------------------------
;;;; csv reader
;;;; ---------------------------------------------------------------------

(defun office-to-org--read-csv-string (text sep)
  "Parse CSV TEXT (separator char SEP) into a list of rows of field strings.
Implements RFC-4180 quoting: fields may be double-quoted, with \"\" escaping
a literal quote, and quoted fields may contain SEP and newlines."
  (let ((rows '()) (fields '()) (chars '())
        (i 0) (n (length text)) (in-quote nil))
    (cl-flet ((end-field ()
                (push (apply #'string (nreverse chars)) fields)
                (setq chars '()))
              (end-row ()
                (push (apply #'string (nreverse chars)) fields)
                (setq chars '())
                (push (nreverse fields) rows)
                (setq fields '())))
      (while (< i n)
        (let ((ch (aref text i)))
          (cond
           (in-quote
            (cond
             ((eq ch ?\")
              (if (and (< (1+ i) n) (eq (aref text (1+ i)) ?\"))
                  (progn (push ?\" chars) (setq i (1+ i)))
                (setq in-quote nil)))
             (t (push ch chars))))
           ((eq ch ?\") (setq in-quote t))
           ((eq ch sep) (end-field))
           ((eq ch ?\r) nil)
           ((eq ch ?\n) (end-row))
           (t (push ch chars))))
        (setq i (1+ i)))
      (when (or chars fields) (end-row)))
    (nreverse rows)))

(defun office-to-org--rectangularize (rows)
  "Right-pad each row in ROWS with empty strings to the maximum row width."
  (let ((max-col (apply #'max 0 (mapcar #'length rows))))
    (mapcar (lambda (r) (append r (make-list (- max-col (length r)) ""))) rows)))

(defun office-to-org--csv-sheets (path)
  "Read CSV file PATH into a one-element list of (NAME . GRID)."
  (let* ((text (with-temp-buffer
                 (let ((coding-system-for-read 'utf-8))
                   (insert-file-contents path))
                 (buffer-string)))
         (grid (office-to-org--read-csv-string
                text office-to-org-csv-separator))
         (grid (office-to-org--rectangularize grid))
         (grid (office-to-org--trim-empty-cols
                (office-to-org--trim-empty-rows grid))))
    (list (cons (file-name-base path) grid))))

(defun office-to-org--read-csv (path)
  "Read CSV file PATH into a plist (:title :blocks :images)."
  (list :title nil
        :blocks (office-to-org--sheets-to-blocks (office-to-org--csv-sheets path))
        :images nil))

(defun office-to-org--sheets-to-blocks (sheets)
  "Convert SHEETS (list of (NAME . GRID)) into heading + table blocks."
  (let ((blocks '()))
    (dolist (pair sheets)
      (push (list :heading 1 (car pair)) blocks)
      (push (list :table (cdr pair)) blocks))
    (nreverse blocks)))

;;;; ---------------------------------------------------------------------
;;;; pptx (PresentationML) reader
;;;; ---------------------------------------------------------------------

(defun office-to-org--pptx-bool-attr (node name)
  "Non-nil if NODE's attribute NAME is a truthy DrawingML toggle value."
  (let ((v (office-to-org--attr node name)))
    (and v (member v '("1" "true" "on")))))

(defun office-to-org--pptx-run-markers (run)
  "Return the org emphasis markers implied by RUN's a:rPr."
  (let ((rpr (office-to-org--child run "rPr")))
    (when rpr
      (office-to-org--props-to-markers
       (list :bold (office-to-org--pptx-bool-attr rpr "b")
             :italic (office-to-org--pptx-bool-attr rpr "i")
             :underline (let ((u (office-to-org--attr rpr "u")))
                          (and u (not (string= u "none"))))
             :strike (let ((s (office-to-org--attr rpr "strike")))
                       (and s (not (string= s "noStrike")))))))))

(defun office-to-org--pptx-run-text (run)
  "Concatenate the textual content of RUN (a:r or a:fld), ignoring formatting."
  (let ((parts '()))
    (dolist (child (cddr run))
      (when (consp child)
        (pcase (office-to-org--local-name (car child))
          ("t" (push (office-to-org--node-text child) parts))
          (_ nil))))
    (apply #'concat (nreverse parts))))

(defun office-to-org--pptx-run-hyperlink (run rels)
  "Resolve RUN's a:rPr/a:hlinkClick target via the RELS id->target hash."
  (let* ((rpr (office-to-org--child run "rPr"))
         (hl (and rpr (office-to-org--child rpr "hlinkClick")))
         (id (and hl (office-to-org--attr hl "id"))))
    (and id (gethash id rels))))

(defun office-to-org--pptx-run-to-string (run rels)
  "Render RUN (a:r or a:fld) to an org-formatted inline string."
  (let* ((text (office-to-org--apply-markers
                (office-to-org--pptx-run-text run)
                (office-to-org--pptx-run-markers run)))
         (target (office-to-org--pptx-run-hyperlink run rels)))
    (if (and target (not (office-to-org--blank-p text)))
        (office-to-org--link target text)
      text)))

(defun office-to-org--pptx-para-inline (p rels)
  "Render the inline content of paragraph node P to an org string."
  (let ((parts '()))
    (dolist (child (cddr p))
      (when (consp child)
        (pcase (office-to-org--local-name (car child))
          ((or "r" "fld") (push (office-to-org--pptx-run-to-string child rels) parts))
          ("br" (push " " parts))
          (_ nil))))
    (apply #'concat (nreverse parts))))

(defun office-to-org--pptx-para-bullet (p)
  "Return (LEVEL . ORDERED) when paragraph P is a bulleted list item, else nil.
An explicit a:buNone (or absence of a bullet) means a plain paragraph."
  (let* ((ppr (office-to-org--child p "pPr"))
         (lvl (string-to-number (or (and ppr (office-to-org--attr ppr "lvl")) "0"))))
    (when ppr
      (cond
       ((office-to-org--child ppr "buNone") nil)
       ((office-to-org--child ppr "buAutoNum") (cons lvl t))
       ((office-to-org--child ppr "buChar") (cons lvl nil))
       (t nil)))))

(defun office-to-org--pptx-txbody-blocks (txbody rels)
  "Convert a p:txBody node TXBODY into a list of blocks."
  (let ((blocks '()))
    (dolist (p (office-to-org--children txbody "p"))
      (let ((inline (office-to-org--pptx-para-inline p rels)))
        (unless (office-to-org--blank-p inline)
          (let ((bullet (office-to-org--pptx-para-bullet p)))
            (push (if bullet
                      (list :list-item (car bullet) (cdr bullet) inline)
                    (list :paragraph inline))
                  blocks)))))
    (nreverse blocks)))

(defun office-to-org--pptx-shape-title-p (sp)
  "Non-nil if shape SP is a title placeholder (type title or ctrTitle)."
  (let* ((nv (office-to-org--child sp "nvSpPr"))
         (nvpr (and nv (office-to-org--child nv "nvPr")))
         (ph (and nvpr (office-to-org--child nvpr "ph")))
         (type (and ph (office-to-org--attr ph "type"))))
    (and type (member type '("title" "ctrTitle")) t)))

(defun office-to-org--pptx-shape-title-text (sp rels)
  "Return the trimmed title text of title shape SP."
  (let ((txbody (office-to-org--child sp "txBody")))
    (when txbody
      (string-trim
       (mapconcat (lambda (p) (office-to-org--pptx-para-inline p rels))
                  (office-to-org--children txbody "p") " ")))))

(defun office-to-org--pptx-pic-embed (pic)
  "Return the r:embed relationship id of picture node PIC, or nil."
  (let* ((bf (office-to-org--child pic "blipFill"))
         (blip (and bf (office-to-org--child bf "blip"))))
    (and blip (office-to-org--attr blip "embed"))))

(defun office-to-org--pptx-graphicframe-table (gf rels)
  "Convert a p:graphicFrame node GF holding an a:tbl to a (:table ROWS) block."
  (let* ((g (office-to-org--child gf "graphic"))
         (gd (and g (office-to-org--child g "graphicData")))
         (tbl (and gd (office-to-org--child gd "tbl"))))
    (when tbl
      (let ((rows '()))
        (dolist (tr (office-to-org--children tbl "tr"))
          (let ((cells '()))
            (dolist (tc (office-to-org--children tr "tc"))
              (let ((txbody (office-to-org--child tc "txBody")))
                (push (string-trim
                       (mapconcat
                        (lambda (p) (office-to-org--pptx-para-inline p rels))
                        (and txbody (office-to-org--children txbody "p"))
                        " "))
                      cells)))
            (push (nreverse cells) rows)))
        (list :table (nreverse rows))))))

(defun office-to-org--pptx-slide-paths (path)
  "Return slide member paths of pptx PATH in presentation order."
  (let* ((pres (office-to-org--parse-xml-member path "ppt/presentation.xml"))
         (rels (office-to-org--parse-xml-member path "ppt/_rels/presentation.xml.rels"))
         (relmap (make-hash-table :test 'equal))
         (sldidlst (and pres (office-to-org--child pres "sldIdLst")))
         (paths '()))
    (dolist (rel (office-to-org--children rels "Relationship"))
      (let ((id (office-to-org--attr rel "Id"))
            (target (office-to-org--attr rel "Target")))
        (when (and id target) (puthash id target relmap))))
    (dolist (sld (office-to-org--children sldidlst "sldId"))
      (let* ((rid (or (office-to-org--attr-qualified sld "r:id")
                      ;; fall back: among local-name "id" attrs, the rId one
                      (cl-loop for (k . v) in (cadr sld)
                               when (and (string= (office-to-org--local-name k) "id")
                                         (string-prefix-p "rId" v))
                               return v)))
             (target (and rid (gethash rid relmap))))
        (when target (push (office-to-org--resolve-rel "ppt/" target) paths))))
    (nreverse paths)))

(defun office-to-org--pptx-slide-rels (path slide-path)
  "Return plist (:targets HASH :notes MEMBER) for SLIDE-PATH in pptx PATH.
TARGETS maps relationship id to its raw Target; NOTES is the resolved
notesSlide member, or nil."
  (let* ((dom (office-to-org--parse-xml-member
               path (office-to-org--rels-path slide-path)))
         (targets (make-hash-table :test 'equal))
         (base (file-name-directory slide-path))
         (notes nil))
    (dolist (rel (office-to-org--children dom "Relationship"))
      (let ((id (office-to-org--attr rel "Id"))
            (target (office-to-org--attr rel "Target"))
            (type (office-to-org--attr rel "Type")))
        (when (and id target) (puthash id target targets))
        (when (and type target (string-suffix-p "notesSlide" type))
          (setq notes (office-to-org--resolve-rel base target)))))
    (list :targets targets :notes notes)))

(defun office-to-org--pptx-notes-blocks (path notes-member)
  "Return the speaker-notes blocks (text only) from NOTES-MEMBER of PATH."
  (let* ((dom (office-to-org--parse-xml-member path notes-member))
         (csld (and dom (office-to-org--child dom "cSld")))
         (sptree (and csld (office-to-org--child csld "spTree")))
         (empty (make-hash-table :test 'equal))
         (blocks '()))
    (when sptree
      (dolist (sp (office-to-org--children sptree "sp"))
        (let* ((nv (office-to-org--child sp "nvSpPr"))
               (nvpr (and nv (office-to-org--child nv "nvPr")))
               (ph (and nvpr (office-to-org--child nvpr "ph")))
               (type (and ph (office-to-org--attr ph "type")))
               (txbody (office-to-org--child sp "txBody")))
          ;; Skip the auto slide-number / date / footer placeholders.
          (when (and txbody (not (member type '("sldNum" "dt" "ftr"))))
            (setq blocks
                  (append blocks
                          (office-to-org--pptx-txbody-blocks txbody empty)))))))
    blocks))

(defun office-to-org--pptx-slide-blocks (path slide-path index images)
  "Return the block list for one slide SLIDE-PATH at 1-based INDEX.
IMAGES is the shared member->relpath hash, mutated as pictures are seen."
  (let* ((dom (office-to-org--parse-xml-member path slide-path))
         (csld (and dom (office-to-org--child dom "cSld")))
         (sptree (and csld (office-to-org--child csld "spTree")))
         (relinfo (office-to-org--pptx-slide-rels path slide-path))
         (rels (plist-get relinfo :targets))
         (base (file-name-directory slide-path))
         (title nil)
         (body '()))
    (when sptree
      (dolist (node (cddr sptree))
        (when (consp node)
          (pcase (office-to-org--local-name (car node))
            ("sp"
             (cond
              ((and (not title) (office-to-org--pptx-shape-title-p node))
               (setq title (office-to-org--pptx-shape-title-text node rels)))
              ((office-to-org--child node "txBody")
               (setq body (append body
                                  (office-to-org--pptx-txbody-blocks
                                   (office-to-org--child node "txBody") rels))))))
            ("pic"
             (let* ((embed (office-to-org--pptx-pic-embed node))
                    (target (and embed (gethash embed rels)))
                    (member (and target (office-to-org--resolve-rel base target))))
               (when member
                 (setq body (append body
                                    (list (list :image
                                                (office-to-org--register-image
                                                 images member))))))))
            ("graphicFrame"
             (let ((tbl (office-to-org--pptx-graphicframe-table node rels)))
               (when tbl (setq body (append body (list tbl))))))
            (_ nil)))))
    (let* ((heading (if (and (eq office-to-org-slide-heading 'title-or-number)
                             (not (office-to-org--blank-p title)))
                        title
                      (format "Slide %d" index)))
           (blocks (cons (list :heading 1 heading) body)))
      (when (and office-to-org-include-notes (plist-get relinfo :notes))
        (let ((nb (office-to-org--pptx-notes-blocks
                   path (plist-get relinfo :notes))))
          (when nb
            (setq blocks (append blocks (list (list :heading 2 "Notes")) nb)))))
      blocks)))

(defun office-to-org--read-pptx (path)
  "Read pptx file PATH into a plist (:title :blocks :images)."
  (let ((slide-paths (office-to-org--pptx-slide-paths path))
        (images (make-hash-table :test 'equal))
        (blocks '())
        (index 0))
    (unless slide-paths
      (error "No slides found in %s" path))
    (dolist (sp slide-paths)
      (setq index (1+ index))
      (setq blocks (append blocks
                           (office-to-org--pptx-slide-blocks
                            path sp index images))))
    (let (image-alist)
      (maphash (lambda (m r) (push (cons m r) image-alist)) images)
      (list :title (office-to-org--ooxml-core-title path)
            :blocks blocks
            :images image-alist))))

;;;; ---------------------------------------------------------------------
;;;; odp (OpenDocument Presentation) reader
;;;; ---------------------------------------------------------------------

(defun office-to-org--odp-frame-text-blocks (frame style-map list-styles)
  "Collect blocks from a draw:frame FRAME's draw:text-box."
  (let ((tb (office-to-org--child frame "text-box"))
        (blocks '()))
    (when tb
      (dolist (child (cddr tb))
        (when (consp child)
          (pcase (office-to-org--local-name (car child))
            ((or "p" "h")
             (let ((inline (office-to-org--odt-inline child style-map)))
               (unless (office-to-org--blank-p inline)
                 (push (list :paragraph inline) blocks))))
            ("list"
             (dolist (b (office-to-org--odt-list child style-map list-styles 0))
               (push b blocks)))
            (_ nil)))))
    (nreverse blocks)))

(defun office-to-org--odp-frame-image (frame images)
  "Return an (:image RELPATH) block for draw:frame FRAME, registering in IMAGES."
  (let* ((img (office-to-org--child frame "image"))
         (href (and img (office-to-org--attr img "href"))))
    (when (and href (not (string-prefix-p "http" href)))
      (let ((member (if (string-prefix-p "/" href) (substring href 1) href)))
        (list :image (office-to-org--register-image images member))))))

(defun office-to-org--odp-page-blocks (page index style-map list-styles images)
  "Return the block list for one draw:page PAGE at 1-based INDEX."
  (let ((title nil) (body '()) (notes '()))
    (dolist (frame (office-to-org--children page "frame"))
      (let ((class (or (office-to-org--attr frame "class") "")))
        (cond
         ((office-to-org--child frame "image")
          (let ((img (office-to-org--odp-frame-image frame images)))
            (when img (setq body (append body (list img))))))
         ((office-to-org--child frame "table")
          (setq body (append body
                             (list (office-to-org--odt-table
                                    (office-to-org--child frame "table")
                                    style-map)))))
         ((and (string= class "title") (not title))
          (setq title (string-trim
                       (office-to-org--node-text
                        (office-to-org--child frame "text-box")))))
         (t
          (setq body (append body
                             (office-to-org--odp-frame-text-blocks
                              frame style-map list-styles)))))))
    (when office-to-org-include-notes
      (let ((notes-node (office-to-org--child page "notes")))
        (when notes-node
          (dolist (frame (office-to-org--children notes-node "frame"))
            (setq notes (append notes
                               (office-to-org--odp-frame-text-blocks
                                frame style-map list-styles)))))))
    (let* ((named (let ((nm (office-to-org--attr page "name")))
                    (and (not (office-to-org--blank-p nm)) nm)))
           (heading (if (eq office-to-org-slide-heading 'title-or-number)
                        (or (and (not (office-to-org--blank-p title)) title)
                            named
                            (format "Slide %d" index))
                      (format "Slide %d" index)))
           (blocks (cons (list :heading 1 heading) body)))
      (when (and office-to-org-include-notes notes)
        (setq blocks (append blocks (list (list :heading 2 "Notes")) notes)))
      blocks)))

(defun office-to-org--read-odp (path)
  "Read odp file PATH into a plist (:title :blocks :images)."
  (let* ((content (office-to-org--parse-xml-member path "content.xml"))
         (styles (office-to-org--parse-xml-member path "styles.xml"))
         (doms (delq nil (list content styles)))
         (style-map (office-to-org--odt-style-map doms))
         (list-styles (office-to-org--odt-list-styles doms))
         (body (and content (office-to-org--child content "body")))
         (pres (and body (office-to-org--child body "presentation")))
         (images (make-hash-table :test 'equal))
         (blocks '())
         (index 0))
    (unless pres
      (error "No content.xml office:presentation found in %s" path))
    (dolist (page (office-to-org--children pres "page"))
      (setq index (1+ index))
      (setq blocks (append blocks
                           (office-to-org--odp-page-blocks
                            page index style-map list-styles images))))
    (let (image-alist)
      (maphash (lambda (m r) (push (cons m r) image-alist)) images)
      (list :title (office-to-org--odt-title path)
            :blocks blocks
            :images image-alist))))

;;;; ---------------------------------------------------------------------
;;;; Renderer: blocks -> org text
;;;; ---------------------------------------------------------------------

(defun office-to-org--escape-cell (s)
  "Make string S safe for an org table cell."
  (let ((s (or s "")))
    (setq s (replace-regexp-in-string "[\r\n\t]+" " " s))
    (setq s (replace-regexp-in-string "|" "\\\\vert{}" s))
    (string-trim s)))

(defun office-to-org--table-to-org (rows)
  "Render ROWS (list of cell-string lists) as org table text."
  (if (null rows)
      ""
    (let ((ncol (apply #'max 1 (mapcar #'length rows)))
          (lines '())
          (first t))
      (dolist (row rows)
        (let* ((padded (append row (make-list (max 0 (- ncol (length row))) "")))
               (cells (mapcar #'office-to-org--escape-cell padded)))
          (push (concat "| " (mapconcat #'identity cells " | ") " |") lines)
          (when (and first office-to-org-first-row-is-header)
            (push (concat "|" (mapconcat (lambda (_) "---")
                                         (number-sequence 1 ncol) "+")
                          "|")
                  lines))
          (setq first nil)))
      (mapconcat #'identity (nreverse lines) "\n"))))

(defun office-to-org--reset-deeper-counters (counters level)
  "Remove entries in COUNTERS for nesting levels deeper than LEVEL."
  (let ((kill '()))
    (maphash (lambda (k _v) (when (> k level) (push k kill))) counters)
    (dolist (k kill) (remhash k counters))))

(defun office-to-org--list-item-text (block counters)
  "Render list-item BLOCK to a line, updating ordered COUNTERS in place."
  (cl-destructuring-bind (_ level ordered inline) block
    (setq inline (string-trim-right inline))
    (office-to-org--reset-deeper-counters counters level)
    (let ((indent (make-string (* level office-to-org-list-indent) ?\s)))
      (if ordered
          (let ((n (1+ (gethash level counters 0))))
            (puthash level n counters)
            (format "%s%d. %s" indent n inline))
        (format "%s- %s" indent inline)))))

(defun office-to-org--block-to-text (block counters)
  "Render BLOCK to its org text, threading ordered list COUNTERS."
  (pcase (car block)
    (:heading (format "%s %s" (make-string (max 1 (nth 1 block)) ?*)
                      (string-trim-right (nth 2 block))))
    (:paragraph (string-trim-right (nth 1 block)))
    (:list-item (office-to-org--list-item-text block counters))
    (:image (format "[[file:%s]]" (nth 1 block)))
    (:table (office-to-org--table-to-org (nth 1 block)))
    (:rule "-----")
    (_ "")))

(defun office-to-org--blocks-to-org-string (title blocks &optional inline-images)
  "Render BLOCKS to an org buffer string, optionally headed by TITLE.
When INLINE-IMAGES is non-nil and `office-to-org-emit-startup-inline-images'
is set, prepend a `#+startup: inlineimages' keyword."
  (let ((entries '())
        (counters (make-hash-table :test 'eql)))
    (when (and inline-images office-to-org-emit-startup-inline-images)
      (push (cons :meta "#+startup: inlineimages") entries))
    (when (and office-to-org-emit-title (not (office-to-org--blank-p title)))
      (push (cons :meta (format "#+title: %s" (string-trim title))) entries))
    (dolist (block blocks)
      (unless (eq (car block) :list-item) (clrhash counters))
      (push (cons (car block)
                  (office-to-org--block-to-text block counters))
            entries))
    (setq entries (nreverse entries))
    ;; Join with a blank line between blocks, except between adjacent list
    ;; items (one list) and between adjacent meta keywords (file header).
    (let ((out '()) (prev nil))
      (dolist (e entries)
        (when (and prev
                   (not (and (eq (car prev) :list-item) (eq (car e) :list-item)))
                   (not (and (eq (car prev) :meta) (eq (car e) :meta))))
          (push "" out))
        (push (cdr e) out)
        (setq prev e))
      (concat (mapconcat #'identity (nreverse out) "\n") "\n"))))

(defun office-to-org--align-all-tables ()
  "Align every org table in the current buffer."
  (when (derived-mode-p 'org-mode)
    (require 'org-table)
    (when (fboundp 'org-table-map-tables)
      (org-table-map-tables #'org-table-align t))))

;;;; ---------------------------------------------------------------------
;;;; Public conversion + dired integration
;;;; ---------------------------------------------------------------------

(defconst office-to-org--presentation-extensions '("pptx" "odp")
  "Extensions whose output is a media folder rather than a sibling .org file.")

(defun office-to-org--read (file ext)
  "Dispatch FILE (with lowercase EXT) to its reader, returning a data plist."
  (pcase ext
    ("docx" (office-to-org--read-docx file))
    ("odt"  (office-to-org--read-odt file))
    ("xlsx" (office-to-org--read-xlsx file))
    ("csv"  (office-to-org--read-csv file))
    ("pptx" (office-to-org--read-pptx file))
    ("odp"  (office-to-org--read-odp file))
    (_ (user-error "Unsupported extension: .%s" ext))))

;;;###autoload
(defun office-to-org-file-p (file)
  "Non-nil if FILE has an extension in `office-to-org-extensions'."
  (and file
       (member (downcase (or (file-name-extension file) ""))
               office-to-org-extensions)
       t))

;;;###autoload
(defun office-to-org-convert-file (file &optional target)
  "Convert office FILE into an org file and visit it.
Documents (.docx/.odt) and spreadsheets (.xlsx/.csv) write a sibling
.org file (FILE's extension replaced by \".org\").  Presentations
\(.pptx/.odp) write a folder named after FILE's slugified base name,
holding the .org file and any extracted inline images side-by-side.

TARGET, if given, overrides the org file path (its directory becomes the
media folder for presentations).  When the org file already exists,
`office-to-org-overwrite' decides whether to regenerate or just visit it."
  (interactive
   (list (or (and (derived-mode-p 'dired-mode) (dired-get-filename nil t))
             (read-file-name "Office file: " nil nil t))))
  (setq file (expand-file-name file))
  (unless (file-readable-p file)
    (user-error "Cannot read file: %s" file))
  (let* ((ext (downcase (or (file-name-extension file) "")))
         (presentation (and (member ext office-to-org--presentation-extensions) t))
         (slug (office-to-org--slugify (file-name-base file)))
         (dir (cond
               (target (file-name-directory (expand-file-name target)))
               (presentation (file-name-as-directory
                              (expand-file-name slug (file-name-directory file))))
               (t (file-name-directory file))))
         (org (cond
               (target (expand-file-name target))
               (presentation (expand-file-name (concat slug ".org") dir))
               (t (concat (file-name-sans-extension file) ".org"))))
         (proceed (or (not (file-exists-p org))
                      (pcase office-to-org-overwrite
                        ('prompt (y-or-n-p
                                  (format "%s exists.  Regenerate from %s? "
                                          (file-name-nondirectory org)
                                          (file-name-nondirectory file))))
                        ('nil nil)
                        (_ t)))))
    (if (not proceed)
        (find-file org)
      (let* ((data
              (condition-case err
                  (office-to-org--read file ext)
                (error (user-error "Failed to convert %s: %s"
                                   (file-name-nondirectory file)
                                   (error-message-string err)))))
             ;; Spreadsheets carry no document title; everything else falls
             ;; back to the base name when no stored title is present.
             (title (or (plist-get data :title)
                        (unless (member ext '("xlsx" "csv"))
                          (file-name-base file))))
             (images (plist-get data :images))
             (content (office-to-org--blocks-to-org-string
                       title (plist-get data :blocks) presentation))
             (existing (find-buffer-visiting org)))
        (when presentation (make-directory dir t))
        (dolist (pair images)
          (office-to-org--extract-member-to-file
           file (car pair) (expand-file-name (cdr pair) dir)))
        (with-temp-file org (insert content))
        (when existing
          (with-current-buffer existing (revert-buffer t t t)))
        (let ((buf (find-file org)))
          (office-to-org--align-all-tables)
          (when (and presentation office-to-org-emit-startup-inline-images)
            (ignore-errors (org-display-inline-images)))
          (when (buffer-modified-p) (save-buffer))
          buf)))))

;;;###autoload
(defun office-to-org-dired-find-file ()
  "In dired, convert the file at point if convertible, else open normally."
  (interactive)
  (let ((file (dired-get-filename nil t)))
    (if (and file (office-to-org-file-p file) (not (file-directory-p file)))
        (office-to-org-convert-file file)
      (dired-find-file))))

(defun office-to-org--dired-find-file-advice (orig &rest args)
  "Around advice for `dired-find-file': intercept convertible files.
ORIG is the original function, ARGS its arguments."
  (let ((file (and (derived-mode-p 'dired-mode)
                   (dired-get-filename nil t))))
    (if (and file
             (office-to-org-file-p file)
             (not (file-directory-p file)))
        (office-to-org-convert-file file)
      (apply orig args))))

;;;###autoload
(define-minor-mode office-to-org-mode
  "Global minor mode: RET on a convertible office file in dired converts it."
  :global t
  :group 'office-to-org
  (if office-to-org-mode
      (advice-add 'dired-find-file :around
                  #'office-to-org--dired-find-file-advice)
    (advice-remove 'dired-find-file
                   #'office-to-org--dired-find-file-advice)))

(provide 'office-to-org)
;;; office-to-org.el ends here
