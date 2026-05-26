;;; spreadsheet-to-org.el --- Convert .xlsx/.csv to org tables  -*- lexical-binding: t; -*-

;; Author: Ben H. W.
;; Keywords: convenience, files, data
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Read .xlsx and .csv files and render their contents as native
;; org-mode tables.  The headline feature: with `spreadsheet-to-org-mode'
;; enabled, pressing RET on a .xlsx or .csv file in a dired buffer creates
;; a sibling .org file holding the data as org table(s) and visits it.
;;
;; .xlsx is a ZIP of XML parts.  We extract individual members with the
;; `unzip' program and parse them with `libxml-parse-xml-region' (Emacs
;; must be built with libxml2 -- it is on this machine).  The cell-value
;; semantics (shared strings, numbers, booleans, inline strings, and date
;; serials gated by cell styles) mirror the cl-excel Common Lisp reader.
;;
;; Usage:
;;   (load! "private-packages/spreadsheet-to-org.el")
;;   (spreadsheet-to-org-mode +1)
;; then press RET on a .xlsx/.csv in dired, or
;;   M-x spreadsheet-to-org-convert-file

;;; Code:

(require 'cl-lib)
(require 'dired)

(declare-function org-table-map-tables "org-table" (function &optional quietly))
(declare-function org-table-align "org-table" ())

;;;; Customization

(defgroup spreadsheet-to-org nil
  "Convert spreadsheets and CSV files to org-mode tables."
  :group 'convenience
  :prefix "spreadsheet-to-org-")

(defcustom spreadsheet-to-org-extensions '("xlsx" "csv")
  "File extensions (lowercase, no dot) treated as convertible spreadsheets."
  :type '(repeat string))

(defcustom spreadsheet-to-org-csv-separator ?,
  "Field separator character used when parsing CSV files."
  :type 'character)

(defcustom spreadsheet-to-org-first-row-is-header t
  "When non-nil, emit an org hline after the first row of each table."
  :type 'boolean)

(defcustom spreadsheet-to-org-date-format "%Y-%m-%d"
  "`format-time-string' format for date-styled cells.
Times are formatted in UTC to match the workbook's stored serials."
  :type 'string)

(defcustom spreadsheet-to-org-include-time t
  "When non-nil, append \" %H:%M\" to dates whose serial has a time fraction."
  :type 'boolean)

(defcustom spreadsheet-to-org-overwrite 'prompt
  "What to do when the target .org file already exists.
`prompt' asks before regenerating; t always regenerates; nil never
regenerates (just visits the existing file)."
  :type '(choice (const :tag "Ask" prompt)
                 (const :tag "Always regenerate" t)
                 (const :tag "Never regenerate" nil)))

;;;; ZIP + XML helpers

(defun spreadsheet-to-org--unzip-member (zipfile member)
  "Return the contents of MEMBER inside ZIPFILE as a UTF-8 string, or nil."
  (with-temp-buffer
    (let* ((coding-system-for-read 'utf-8)
           (exit (call-process "unzip" nil (list t nil) nil
                               "-p" (expand-file-name zipfile) member)))
      (when (and (integerp exit) (zerop exit) (> (buffer-size) 0))
        (buffer-string)))))

(defun spreadsheet-to-org--parse-xml-member (zipfile member)
  "Parse XML MEMBER of ZIPFILE into a libxml tree, or nil if absent."
  (let ((text (spreadsheet-to-org--unzip-member zipfile member)))
    (when text
      (with-temp-buffer
        (insert text)
        (libxml-parse-xml-region (point-min) (point-max))))))

(defun spreadsheet-to-org--local-name (tag)
  "Return the local part of TAG (a symbol or string), dropping any ns prefix."
  (let ((s (if (symbolp tag) (symbol-name tag) tag)))
    (if (string-match ":\\([^:]+\\)\\'" s)
        (match-string 1 s)
      s)))

(defun spreadsheet-to-org--children (node local-name)
  "Return direct child elements of NODE whose local name equals LOCAL-NAME."
  (when (consp node)
    (cl-loop for child in (cddr node)
             when (and (consp child)
                       (symbolp (car child))
                       (string= (spreadsheet-to-org--local-name (car child))
                                local-name))
             collect child)))

(defun spreadsheet-to-org--child (node local-name)
  "Return the first direct child element of NODE named LOCAL-NAME, or nil."
  (car (spreadsheet-to-org--children node local-name)))

(defun spreadsheet-to-org--attr (node name)
  "Return the value of NODE's attribute whose local name equals NAME, or nil."
  (when (consp node)
    (cl-loop for (k . v) in (cadr node)
             when (string= (spreadsheet-to-org--local-name k) name)
             return v)))

(defun spreadsheet-to-org--node-text (node)
  "Concatenate all descendant text content of NODE."
  (cond
   ((stringp node) node)
   ((consp node)
    (mapconcat #'spreadsheet-to-org--node-text (cddr node) ""))
   (t "")))

;;;; References and date math (port of refs.lisp / sheet-read.lisp)

(defun spreadsheet-to-org--col-of-ref (ref)
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

(defun spreadsheet-to-org--excel-serial-to-string (serial)
  "Convert an Excel SERIAL date (1900 system) to a formatted string.
Uses the epoch 1899-12-30, correct for all modern dates."
  (let* ((base (encode-time (list 0 0 0 30 12 1899 nil -1 t)))
         (secs (round (* serial 86400)))
         (tm (time-add base secs))
         (frac (- serial (floor serial))))
    (format-time-string
     (if (and spreadsheet-to-org-include-time (> frac 0))
         (concat spreadsheet-to-org-date-format " %H:%M")
       spreadsheet-to-org-date-format)
     tm t)))

;;;; Styles (port of styles.lisp)

(defun spreadsheet-to-org--read-styles (zipfile)
  "Read xl/styles.xml from ZIPFILE into a plist (:num-fmts HASH :cell-xfs VEC)."
  (let ((dom (spreadsheet-to-org--parse-xml-member zipfile "xl/styles.xml"))
        (num-fmts (make-hash-table :test 'eql))
        (cell-xfs '()))
    (when dom
      (let ((nfs (spreadsheet-to-org--child dom "numFmts")))
        (dolist (nf (spreadsheet-to-org--children nfs "numFmt"))
          (let ((id (spreadsheet-to-org--attr nf "numFmtId"))
                (code (spreadsheet-to-org--attr nf "formatCode")))
            (when id (puthash (string-to-number id) code num-fmts)))))
      (let ((xfs (spreadsheet-to-org--child dom "cellXfs")))
        (dolist (xf (spreadsheet-to-org--children xfs "xf"))
          (let ((nid (spreadsheet-to-org--attr xf "numFmtId")))
            (push (if nid (string-to-number nid) 0) cell-xfs)))))
    (list :num-fmts num-fmts :cell-xfs (vconcat (nreverse cell-xfs)))))

(defun spreadsheet-to-org--date-format-code-p (code)
  "Heuristic: non-nil if format CODE represents a date/time."
  (when (stringp code)
    (let ((c (downcase code)))
      (or (string-match-p "yy" c) (string-match-p "mm" c)
          (string-match-p "dd" c) (string-match-p "hh" c)
          (string-match-p "ss" c) (string-match-p "m/d" c)
          (string-match-p "d-m" c)))))

(defun spreadsheet-to-org--date-style-p (styles style-id)
  "Non-nil if STYLE-ID in STYLES designates a date number format."
  (when (and styles style-id)
    (let ((xfs (plist-get styles :cell-xfs))
          (num-fmts (plist-get styles :num-fmts)))
      (when (and (>= style-id 0) (< style-id (length xfs)))
        (let ((nid (aref xfs style-id)))
          (or (and (>= nid 14) (<= nid 22))
              (and (>= nid 45) (<= nid 47))
              (spreadsheet-to-org--date-format-code-p (gethash nid num-fmts))))))))

;;;; Shared strings (port of read-shared-strings)

(defun spreadsheet-to-org--si-text (node)
  "Concatenate text of all <t> elements within NODE (handles rich-text runs)."
  (let ((parts '()))
    (dolist (tn (spreadsheet-to-org--children node "t"))
      (push (spreadsheet-to-org--node-text tn) parts))
    (dolist (r (spreadsheet-to-org--children node "r"))
      (dolist (tn (spreadsheet-to-org--children r "t"))
        (push (spreadsheet-to-org--node-text tn) parts)))
    (apply #'concat (nreverse parts))))

(defun spreadsheet-to-org--read-shared-strings (zipfile)
  "Read xl/sharedStrings.xml from ZIPFILE into a vector of strings."
  (let ((dom (spreadsheet-to-org--parse-xml-member zipfile "xl/sharedStrings.xml"))
        (items '()))
    (dolist (si (spreadsheet-to-org--children dom "si"))
      (push (spreadsheet-to-org--si-text si) items))
    (vconcat (nreverse items))))

;;;; Worksheet -> grid

(defun spreadsheet-to-org--render-number (raw style-id styles)
  "Render numeric RAW string, converting to a date when STYLE-ID is a date style."
  (if (spreadsheet-to-org--date-style-p styles style-id)
      (spreadsheet-to-org--excel-serial-to-string (string-to-number raw))
    raw))

(defun spreadsheet-to-org--cell-value (c shared-strings styles)
  "Return the display string for cell node C."
  (let* ((type (or (spreadsheet-to-org--attr c "t") "n"))
         (s-attr (spreadsheet-to-org--attr c "s"))
         (style-id (and s-attr (string-to-number s-attr)))
         (v (spreadsheet-to-org--child c "v")))
    (cond
     ((string= type "s")
      (let ((idx (and v (string-to-number (spreadsheet-to-org--node-text v)))))
        (if (and idx (>= idx 0) (< idx (length shared-strings)))
            (aref shared-strings idx)
          "")))
     ((string= type "inlineStr")
      (let ((is (spreadsheet-to-org--child c "is")))
        (if is (spreadsheet-to-org--si-text is) "")))
     ((string= type "str") (if v (spreadsheet-to-org--node-text v) ""))
     ((string= type "b")
      (if (and v (string= (spreadsheet-to-org--node-text v) "1")) "TRUE" "FALSE"))
     ((string= type "e") (if v (spreadsheet-to-org--node-text v) ""))
     (t
      (let ((raw (and v (spreadsheet-to-org--node-text v))))
        (if (and raw (> (length raw) 0))
            (spreadsheet-to-org--render-number raw style-id styles)
          ""))))))

(defun spreadsheet-to-org--row-empty-p (row)
  "Non-nil if every cell of ROW is blank after trimming."
  (cl-every (lambda (cell) (string= (string-trim cell) "")) row))

(defun spreadsheet-to-org--trim-empty-rows (rows)
  "Drop trailing all-empty rows from ROWS."
  (let ((rev (reverse rows)))
    (while (and rev (spreadsheet-to-org--row-empty-p (car rev)))
      (setq rev (cdr rev)))
    (nreverse rev)))

(defun spreadsheet-to-org--trim-empty-cols (rows)
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

(defun spreadsheet-to-org--read-sheet-grid (zipfile sheet-path shared-strings styles)
  "Read worksheet SHEET-PATH in ZIPFILE into a rectangular list of string rows."
  (let* ((dom (spreadsheet-to-org--parse-xml-member zipfile sheet-path))
         (sheet-data (and dom (spreadsheet-to-org--child dom "sheetData")))
         (rows '())
         (max-col 0)
         (last-row 0))
    (dolist (row-node (spreadsheet-to-org--children sheet-data "row"))
      (let* ((r-attr (spreadsheet-to-org--attr row-node "r"))
             (rnum (if r-attr (string-to-number r-attr) (1+ last-row))))
        ;; Fill gaps between rows with empty rows.
        (when (> rnum (1+ last-row))
          (dotimes (_ (- rnum last-row 1)) (push nil rows)))
        (setq last-row rnum)
        (let ((cells '()) (last-col 0))
          (dolist (c (spreadsheet-to-org--children row-node "c"))
            (let* ((ref (spreadsheet-to-org--attr c "r"))
                   (col (if ref (spreadsheet-to-org--col-of-ref ref) (1+ last-col))))
              (when (> col (1+ last-col))
                (dotimes (_ (- col last-col 1)) (push "" cells)))
              (setq last-col col)
              (push (spreadsheet-to-org--cell-value c shared-strings styles) cells)))
          (setq cells (nreverse cells))
          (setq max-col (max max-col (length cells)))
          (push cells rows))))
    (setq rows (nreverse rows))
    (setq rows (mapcar (lambda (r)
                         (append r (make-list (max 0 (- max-col (length r))) "")))
                       rows))
    (spreadsheet-to-org--trim-empty-cols
     (spreadsheet-to-org--trim-empty-rows rows))))

;;;; Workbook driver (port of read-xlsx)

(defun spreadsheet-to-org--resolve-target (target)
  "Resolve a workbook-relationship TARGET to a path inside the ZIP."
  (when target
    (cond
     ((string-prefix-p "/" target) (substring target 1))
     ((string-prefix-p "../" target) (concat "xl/" (substring target 3)))
     (t (concat "xl/" target)))))

(defun spreadsheet-to-org--read-xlsx (path)
  "Read xlsx file PATH into a list of (SHEET-NAME . GRID) pairs in workbook order."
  (let* ((wb (spreadsheet-to-org--parse-xml-member path "xl/workbook.xml"))
         (rels (spreadsheet-to-org--parse-xml-member path "xl/_rels/workbook.xml.rels"))
         (rel-map (make-hash-table :test 'equal))
         (shared (spreadsheet-to-org--read-shared-strings path))
         (styles (spreadsheet-to-org--read-styles path))
         (result '()))
    (unless wb
      (error "No xl/workbook.xml found in %s" path))
    (dolist (rel (spreadsheet-to-org--children rels "Relationship"))
      (let ((id (spreadsheet-to-org--attr rel "Id"))
            (target (spreadsheet-to-org--attr rel "Target")))
        (when (and id target) (puthash id target rel-map))))
    (let ((sheets-node (spreadsheet-to-org--child wb "sheets")))
      (dolist (sheet (spreadsheet-to-org--children sheets-node "sheet"))
        (let* ((name (or (spreadsheet-to-org--attr sheet "name") "Sheet"))
               (rid (spreadsheet-to-org--attr sheet "id"))   ; local name of r:id
               (target (and rid (gethash rid rel-map)))
               (sheet-path (spreadsheet-to-org--resolve-target target)))
          (when sheet-path
            (push (cons name (spreadsheet-to-org--read-sheet-grid
                              path sheet-path shared styles))
                  result)))))
    (nreverse result)))

;;;; CSV reader

(defun spreadsheet-to-org--read-csv-string (text sep)
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

(defun spreadsheet-to-org--rectangularize (rows)
  "Right-pad each row in ROWS with empty strings to the maximum row width."
  (let ((max-col (apply #'max 0 (mapcar #'length rows))))
    (mapcar (lambda (r) (append r (make-list (- max-col (length r)) ""))) rows)))

(defun spreadsheet-to-org--read-csv (path)
  "Read CSV file PATH into a one-element list of (NAME . GRID)."
  (let* ((text (with-temp-buffer
                 (let ((coding-system-for-read 'utf-8))
                   (insert-file-contents path))
                 (buffer-string)))
         (grid (spreadsheet-to-org--read-csv-string
                text spreadsheet-to-org-csv-separator))
         (grid (spreadsheet-to-org--rectangularize grid))
         (grid (spreadsheet-to-org--trim-empty-cols
                (spreadsheet-to-org--trim-empty-rows grid))))
    (list (cons (file-name-base path) grid))))

;;;; Grid -> org text

(defun spreadsheet-to-org--escape-cell (s)
  "Make string S safe for an org table cell."
  (let ((s (or s "")))
    (setq s (replace-regexp-in-string "[\r\n\t]+" " " s))
    (setq s (replace-regexp-in-string "|" "\\\\vert{}" s))
    (string-trim s)))

(defun spreadsheet-to-org--grid-to-org-table (grid)
  "Render GRID (list of string rows) as org table text, header hline optional."
  (if (null grid)
      ""
    (let ((ncol (apply #'max 1 (mapcar #'length grid)))
          (lines '())
          (first t))
      (dolist (row grid)
        (let* ((padded (append row (make-list (max 0 (- ncol (length row))) "")))
               (cells (mapcar #'spreadsheet-to-org--escape-cell padded)))
          (push (concat "| " (mapconcat #'identity cells " | ") " |") lines)
          (when (and first spreadsheet-to-org-first-row-is-header)
            (push (concat "|" (mapconcat (lambda (_) "---")
                                         (number-sequence 1 ncol) "+")
                          "|")
                  lines))
          (setq first nil)))
      (concat (mapconcat #'identity (nreverse lines) "\n") "\n"))))

(defun spreadsheet-to-org--sheets-to-org-string (sheets)
  "Render SHEETS (list of (NAME . GRID)) into an org buffer string."
  (mapconcat
   (lambda (pair)
     (concat "* " (car pair) "\n\n"
             (spreadsheet-to-org--grid-to-org-table (cdr pair))
             "\n"))
   sheets
   ""))

(defun spreadsheet-to-org--align-all-tables ()
  "Align every org table in the current buffer."
  (when (derived-mode-p 'org-mode)
    (require 'org-table)
    (when (fboundp 'org-table-map-tables)
      (org-table-map-tables #'org-table-align t))))

;;;; Public conversion + dired integration

;;;###autoload
(defun spreadsheet-to-org-file-p (file)
  "Non-nil if FILE has an extension in `spreadsheet-to-org-extensions'."
  (and file
       (member (downcase (or (file-name-extension file) ""))
               spreadsheet-to-org-extensions)
       t))

;;;###autoload
(defun spreadsheet-to-org-convert-file (file &optional target)
  "Convert spreadsheet/CSV FILE into an org file TARGET and visit it.
TARGET defaults to FILE with its extension replaced by \".org\".  When
TARGET already exists, `spreadsheet-to-org-overwrite' decides whether to
regenerate or simply visit it."
  (interactive
   (list (or (and (derived-mode-p 'dired-mode) (dired-get-filename nil t))
             (read-file-name "Spreadsheet/CSV file: " nil nil t))))
  (setq file (expand-file-name file))
  (unless (file-readable-p file)
    (user-error "Cannot read file: %s" file))
  (let* ((ext (downcase (or (file-name-extension file) "")))
         (target (or target (concat (file-name-sans-extension file) ".org")))
         (proceed (or (not (file-exists-p target))
                      (pcase spreadsheet-to-org-overwrite
                        ('prompt (y-or-n-p
                                  (format "%s exists.  Regenerate from %s? "
                                          (file-name-nondirectory target)
                                          (file-name-nondirectory file))))
                        ('nil nil)
                        (_ t)))))
    (if (not proceed)
        (find-file target)
      (let* ((sheets
              (condition-case err
                  (cond
                   ((string= ext "csv") (spreadsheet-to-org--read-csv file))
                   ((string= ext "xlsx") (spreadsheet-to-org--read-xlsx file))
                   (t (user-error "Unsupported extension: .%s" ext)))
                (error (user-error "Failed to convert %s: %s"
                                   (file-name-nondirectory file)
                                   (error-message-string err)))))
             (content (spreadsheet-to-org--sheets-to-org-string sheets))
             (existing (find-buffer-visiting target)))
        (with-temp-file target (insert content))
        (when existing
          (with-current-buffer existing (revert-buffer t t t)))
        (let ((buf (find-file target)))
          (spreadsheet-to-org--align-all-tables)
          (when (buffer-modified-p) (save-buffer))
          buf)))))

;;;###autoload
(defun spreadsheet-to-org-dired-find-file ()
  "In dired, convert the file at point if convertible, else open normally."
  (interactive)
  (let ((file (dired-get-filename nil t)))
    (if (and file (spreadsheet-to-org-file-p file) (not (file-directory-p file)))
        (spreadsheet-to-org-convert-file file)
      (dired-find-file))))

(defun spreadsheet-to-org--dired-find-file-advice (orig &rest args)
  "Around advice for `dired-find-file': intercept convertible files.
ORIG is the original function, ARGS its arguments."
  (let ((file (and (derived-mode-p 'dired-mode)
                   (dired-get-filename nil t))))
    (if (and file
             (spreadsheet-to-org-file-p file)
             (not (file-directory-p file)))
        (spreadsheet-to-org-convert-file file)
      (apply orig args))))

;;;###autoload
(define-minor-mode spreadsheet-to-org-mode
  "Global minor mode: RET on a .xlsx/.csv in dired converts it to org tables."
  :global t
  :group 'spreadsheet-to-org
  (if spreadsheet-to-org-mode
      (advice-add 'dired-find-file :around
                  #'spreadsheet-to-org--dired-find-file-advice)
    (advice-remove 'dired-find-file
                   #'spreadsheet-to-org--dired-find-file-advice)))

(provide 'spreadsheet-to-org)
;;; spreadsheet-to-org.el ends here
