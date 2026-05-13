;;; find-free-time.el --- Find available time blocks in an org-agenda view lexical-binding: t; -*-

;;; Commentary:
;; This script provides an interactive function `bda/find-agenda-free-time'
;; that can be run from an org-mode agenda buffer. It parses the schedule,
;; finds the gaps between appointments, and then breaks those gaps into
;; blocks of a user-specified length. The results are printed to the
;; minibuffer.
;;
;; The user is prompted for a start and end time to constrain the search,
;; and whether to include weekend days.
;;
;; This version iterates over buffer lines as a list, avoiding manual
;; point movement with `forward-line`.
;;
;; Modified to sort the output by day with the least scheduled effort first.

;;; Code:

(require 'org-agenda)

(defun bda/time-string-to-minutes (time-str)
  "Convert HH:MM string to minutes from midnight."
  (unless (string-match "\\`\\([0-9]+\\):\\([0-9]+\\)\\'" time-str)
    (error "Invalid time string format: %s" time-str))
  (let ((h (string-to-number (match-string 1 time-str)))
        (m (string-to-number (match-string 2 time-str))))
    (+ (* h 60) m)))

(defun bda/minutes-to-time-string (minutes)
  "Convert minutes from midnight to HH:MM string."
  (format "%02d:%02d" (/ minutes 60) (% minutes 60)))

(defun bda/find-agenda-free-time (effort-length start-time-str end-time-str include-weekends)
  "Parse the agenda buffer to find free time slots of EFFORT-LENGTH minutes.
  Slots are constrained between START-TIME-STR and END-TIME-STR.
  User is prompted whether to INCLUDE-WEEKENDS.
  Days are sorted by the least amount of scheduled time (effort) first."
  (interactive
   (list (read-number "Effort length (minutes): " 60)
         (read-string "Start time (HH:MM): " "06:00")
         (read-string "End time (HH:MM): " "23:00")
         (y-or-n-p "Include weekends? ")))
  (unless (derived-mode-p 'org-agenda-mode)
    (error "This command must be run from an org-agenda buffer"))

  (let ((all-days-data '())
        (current-day-entry nil)
        (start-of-day-minutes (bda/time-string-to-minutes start-time-str))
        (end-of-day-minutes (bda/time-string-to-minutes end-time-str))
        (date-regexp "^\\([A-Za-z]+[ \t]+[0-9]+[ \t]+[A-Za-z]+[ \t]+[0-9]\\{4\\}\\)")
        (time-regexp "\\([0-9]\\{1,2\\}:[0-9]\\{2\\}\\)-\\([0-9]\\{1,2\\}:[0-9]\\{2\\}\\)"))

    ;; 1. Parse buffer to gather busy times for each day.
    (let ((lines (split-string (buffer-string) "\n" t)))
      (dolist (line lines)
        (cond
         ((string-match date-regexp line)
          (let* ((day-name (match-string 1 line))
                 (is-weekend (or (string-match-p "^Saturday" day-name)
                                 (string-match-p "^Sunday" day-name))))
            ;; Set current-day-entry to a new list *only* if it passes the filter.
            ;; Otherwise, set it to nil to ignore subsequent time entries.
            (setq current-day-entry
                  (if (or include-weekends (not is-weekend))
                      (list day-name '())
                    nil))
            ;; Only push if it's not nil.
            (when current-day-entry
              (push current-day-entry all-days-data))))
         ((and current-day-entry (string-match time-regexp line))
          (let* ((start-str (match-string 1 line))
                 (end-str (match-string 2 line))
                 (start-min (bda/time-string-to-minutes start-str))
                 (end-min (bda/time-string-to-minutes end-str)))
            (setf (cadr current-day-entry)
                  (cons (cons start-min end-min)
                        (cadr current-day-entry))))))))

    (setq all-days-data (nreverse all-days-data))

    ;; 2. Process data: merge intervals, calculate total effort, then sort by effort.
    (let* ((processed-days-data
            (mapcar
             (lambda (day-data)
               (let* ((day-name (car day-data))
                      (busy-times (cadr day-data))
                      (merged-times '())
                      (total-effort 0))
                 (when busy-times
                   ;; Merge overlapping/adjacent busy intervals.
                   (let* ((sorted-times (sort busy-times (lambda (a b) (< (car a) (car b)))))
                          (current-start (caar sorted-times))
                          (current-end (cdar sorted-times)))
                     (dolist (next-interval (cdr sorted-times))
                       (if (<= (car next-interval) current-end)
                           (setq current-end (max current-end (cdr next-interval)))
                         (push (cons current-start current-end) merged-times)
                         (setq current-start (car next-interval))
                         (setq current-end (cdr next-interval))))
                     (push (cons current-start current-end) merged-times)
                     (setq merged-times (nreverse merged-times)))

                   ;; Sum the durations of the merged intervals for total effort.
                   (dolist (interval merged-times)
                     (setq total-effort (+ total-effort (- (cdr interval) (car interval))))))
                 ;; Return a new structure: (list day-name merged-intervals total-effort)
                 (list day-name merged-times total-effort)))
             all-days-data))
           (sorted-days-data
            (sort processed-days-data (lambda (day1 day2)
                                        (< (caddr day1) (caddr day2))))))

      ;; 3. Generate output string from sorted data.
      (let ((output-string ""))
        (dolist (day-data sorted-days-data)
          (let* ((day-name (car day-data))
                 (merged-times (cadr day-data))
                 (total-effort (caddr day-data))
                 (day-header (format "%s (%s)"
                                     day-name
                                     (bda/minutes-to-time-string total-effort)))
                 (free-slots '()))

            ;; Find all free slots of EFFORT-LENGTH for the current day.
            (if merged-times
                ;; --- Logic for days WITH appointments ---
                (let ((time-cursor start-of-day-minutes))
                  ;; a. Find gaps between merged intervals.
                  (dolist (busy-interval merged-times)
                    (let ((free-end (min (car busy-interval) end-of-day-minutes))
                          (slot-start time-cursor))
                      (while (<= (+ slot-start effort-length) free-end)
                        (push (format "%s-%s"
                                      (bda/minutes-to-time-string slot-start)
                                      (bda/minutes-to-time-string (+ slot-start effort-length)))
                              free-slots)
                        (setq slot-start (+ slot-start effort-length))))
                    (setq time-cursor (max time-cursor (cdr busy-interval))))
                  ;; b. Handle the final gap from the last task until the end of the day.
                  (let ((slot-start time-cursor))
                    (while (<= (+ slot-start effort-length) end-of-day-minutes)
                      (push (format "%s-%s"
                                    (bda/minutes-to-time-string slot-start)
                                    (bda/minutes-to-time-string (+ slot-start effort-length)))
                            free-slots)
                      (setq slot-start (+ slot-start effort-length)))))
              ;; --- Logic for completely FREE days ---
              (let ((slot-start start-of-day-minutes))
                (while (<= (+ slot-start effort-length) end-of-day-minutes)
                  (push (format "%s-%s"
                                (bda/minutes-to-time-string slot-start)
                                (bda/minutes-to-time-string (+ slot-start effort-length)))
                        free-slots)
                  (setq slot-start (+ slot-start effort-length)))))

            (when free-slots
              (setq output-string
                    (concat output-string
                            (format "%s\n" day-header)
                            (mapconcat 'identity (nreverse free-slots) "\n")
                            "\n")))))

        ;; 4. Display the final result in the minibuffer.
        (message "%s" (if (string-empty-p output-string)
                          "No free slots found."
                        (substring output-string 0 -1)))))))

(provide 'org-agenda-find-free-time)

;;; org-agenda-find-free-time.el ends here
