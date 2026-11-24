;;; jsonyter-script.el --- Script cells (# %%) -*- lexical-binding: t; -*-

;; Author: Ethan Guthrie
;; Assisted-by: Claude:claude-fable-5
;; Assisted-by: Claude:claude-sonnet-5
;; Keywords: languages, processes, jupyter
;; URL: https://github.com/EGuthrieWasTaken/jsonyter.el

;; Copyright (C) 2026 Ethan Guthrie

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Script cells (# %%).  One part of jsonyter.el, which loads
;; every part; see jsonyter.el for the overview and the entry points.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'jsonyter-notebook)
(require 'jsonyter-complete)
(require 'jsonyter-sync)

;;;; Script cells (# %%)

;; The same execute-and-show-results-inline experience in an ordinary
;; script.  Cells are delimited by `# %%' markers rather than by a
;; notebook's structure, and outputs are overlays exactly as in a
;; notebook — so a script buffer's text is never touched and saving it
;; stays completely ordinary.

(defcustom jsonyter-script-cell-regexp
  "^[ \t]*\\(?:#\\|//\\|;;\\|%\\)+[ \t]*%%"
  "Regexp matching a cell boundary in a script.
Covers the `# %%' convention used by Jupytext, VS Code and Spyder, and
its comment-syntax variants."
  :type 'regexp
  :group 'jsonyter)

(defcustom jsonyter-script-languages
  (append
   '((python-mode . "python")
     (ess-r-mode . "R")
     (R-mode . "R")
     (julia-mode . "julia")
     (SAS-mode . "sas")
     (sas-mode . "sas"))
   ;; The tree-sitter major modes (Emacs 29+) are added only when they
   ;; actually exist, and via `intern-soft' on a string rather than as
   ;; literal symbols above, so this package's own Package-Requires can
   ;; stay at 27.1 -- a literal `python-ts-mode' anywhere in the source
   ;; would otherwise commit the whole package to requiring 29.1, for a
   ;; default-value entry that does nothing at all on anything older.
   (delq nil
         (mapcar (lambda (name.lang)
                   (let ((mode (intern-soft (car name.lang))))
                     (and mode (fboundp mode) (cons mode (cdr name.lang)))))
                 '(("python-ts-mode" . "python")
                   ("julia-ts-mode" . "julia")))))
  "Alist mapping a major mode to the kernel language to run its cells with.
On Emacs 29 and newer this also includes `python-ts-mode' and
`julia-ts-mode', so tree-sitter major modes work without configuration."
  :type '(alist :key-type symbol :value-type string)
  :group 'jsonyter)

(defvar-local jsonyter--script-cells nil
  "Overlays holding output for script cells, keyed by cell start.")

(defun jsonyter--script-language ()
  "Kernel language for this script buffer."
  (or (cdr (assq major-mode jsonyter-script-languages))
      (user-error "jsonyter: don't know which kernel runs %s" major-mode)))

(defun jsonyter--script-cell-bounds ()
  "Return (START . END) of the script cell surrounding point."
  (save-excursion
    (let* ((start (progn
                    (end-of-line)
                    (if (re-search-backward jsonyter-script-cell-regexp nil t)
                        (progn (forward-line 1) (point))
                      (point-min))))
           (end (progn
                  (goto-char start)
                  (if (re-search-forward jsonyter-script-cell-regexp nil t)
                      (line-beginning-position)
                    (point-max)))))
      (cons start end))))

(defun jsonyter--script-cell-output-overlay (end)
  "The existing output overlay of the script cell ending at END, or nil."
  (seq-find (lambda (o) (overlay-get o 'jsonyter-script-cell))
            (overlays-in (max (point-min) (1- end)) end)))

(defun jsonyter--script-output-overlay (start end)
  "The output overlay for the cell spanning START..END, creating it once."
  (or (jsonyter--script-cell-output-overlay end)
      (let ((ov (make-overlay (max start (1- end)) end)))
        (overlay-put ov 'jsonyter-script-cell t)
        (push ov jsonyter--script-cells)
        ov)))

(defun jsonyter--script-stale-after-change (beg end _len)
  "After an edit from BEG to END, re-judge the affected cells' outputs.
On `after-change-functions' in `jsonyter-script-mode' buffers; a no-op
until some cell has produced output.  The source is trimmed exactly as
`jsonyter-script-run-cell' trims it before executing, so an edit to
nothing but surrounding blank lines is not called a change."
  (when jsonyter--script-cells
    (save-excursion
      (let (seen)
        (dolist (pos (list beg end))
          (goto-char pos)
          (pcase-let* ((`(,start . ,cell-end) (jsonyter--script-cell-bounds))
                       (ov (jsonyter--script-cell-output-overlay cell-end)))
            (when (and ov (not (memq ov seen)))
              (push ov seen)
              (jsonyter--output-update-stale
               ov (string-trim
                   (buffer-substring-no-properties start cell-end))))))))))

(defun jsonyter--script-code-context ()
  "The code context at point in a script: the `# %%' cell's code.
nil on a cell's own `# %%' marker line, which is not code."
  (pcase-let ((`(,start . ,end) (jsonyter--script-cell-bounds)))
    (when (and (>= (point) start) (<= (point) end))
      (list :code (buffer-substring-no-properties start end)
            :pos (- (point) start)
            :start start
            :session (jsonyter--session)))))

(defun jsonyter-script-run-cell (&optional advance)
  "Execute the script cell at point, showing its output inline.
With ADVANCE, move to the next cell afterwards."
  (interactive)
  (when (jsonyter--busy-p)
    (user-error "jsonyter: kernel is busy (C-c C-c to interrupt)"))
  (unless (jsonyter--live-p)
    (jsonyter--connect-kernel (cons (jsonyter--script-language) "")))
  (let ((session (jsonyter--session)))
   (pcase-let* ((`(,start . ,end) (jsonyter--script-cell-bounds))
                (code (string-trim (buffer-substring-no-properties start end)))
                (ov (jsonyter--script-output-overlay start end)))
    (if (string-blank-p code)
        (message "jsonyter: empty cell")
      ;; Pair the output about to arrive with the source being sent, so
      ;; later edits flag the output stale.
      (overlay-put ov 'jsonyter-source-hash (jsonyter--source-hash code))
      (overlay-put ov 'jsonyter-output-stale nil)
      (overlay-put ov 'jsonyter-output-string "")
      (jsonyter--nb-refresh-output ov)
      (setf (jsonyter--session-busy session) t)
      (force-mode-line-update)
      (jsonyter--send
       "execute"
       (append (list :kernel_id (jsonyter--session-kernel-id session) :code code)
               (and jsonyter-stream-output '(:stream t)))
       (list
        :output (lambda (output) (jsonyter--nb-append-output ov output))
        :result (lambda (msg)
                  (setf (jsonyter--session-busy session) nil)
                  (force-mode-line-update)
                  (let ((err (plist-get msg :error))
                        (result (plist-get msg :result)))
                    (cond
                     (err (jsonyter--nb-set-output
                           ov (format "[execute failed: %s]\n"
                                      (jsonyter--error-message err))))
                     (result
                      (let ((drawn (overlay-get ov 'jsonyter-output-string)))
                        (when (and (or (null drawn) (string-empty-p drawn))
                                   (plist-get result :outputs))
                          (dolist (o (plist-get result :outputs))
                            (jsonyter--nb-append-output ov o)))))))))))))
  (when advance (jsonyter-script-next-cell)))

(defun jsonyter-script-run-cell-and-advance ()
  "Execute the script cell at point, then move to the next one."
  (interactive)
  (jsonyter-script-run-cell t))

(defun jsonyter-script-next-cell ()
  "Move to the next script cell."
  (interactive)
  (end-of-line)
  (if (re-search-forward jsonyter-script-cell-regexp nil t)
      (forward-line 1)
    (goto-char (point-max))))

(defun jsonyter-script-previous-cell ()
  "Move to the previous script cell."
  (interactive)
  (goto-char (car (jsonyter--script-cell-bounds)))
  ;; Step back over this cell's own `# %%' marker line, not merely onto
  ;; it.  `jsonyter--script-cell-bounds' called from a marker line
  ;; resolves to the cell that marker introduces -- the one point is
  ;; already in -- so stopping there left point exactly where it started
  ;; and this command never moved at all, from anywhere in the buffer.
  (forward-line -1)
  (unless (bobp) (forward-line -1))
  (goto-char (car (jsonyter--script-cell-bounds))))

(defun jsonyter-script-clear-all-output ()
  "Discard every inline output in this script buffer."
  (interactive)
  (dolist (ov jsonyter--script-cells)
    (when (overlay-buffer ov) (delete-overlay ov)))
  (setq jsonyter--script-cells nil)
  (message "jsonyter: cleared all output"))

(defvar jsonyter-script-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "<C-return>") #'jsonyter-script-run-cell)
    (define-key map (kbd "<S-return>") #'jsonyter-script-run-cell-and-advance)
    (define-key map (kbd "C-c C-e") #'jsonyter-script-run-cell)
    (define-key map (kbd "C-c C-n") #'jsonyter-script-next-cell)
    (define-key map (kbd "C-c C-p") #'jsonyter-script-previous-cell)
    (define-key map (kbd "C-c C-c") #'jsonyter-interrupt)
    (define-key map (kbd "C-c C-r") #'jsonyter-restart)
    (define-key map (kbd "C-c C-l") #'jsonyter-kernel-reconnect)
    (define-key map (kbd "C-c C-j") #'jsonyter-kernel-connect)
    (define-key map (kbd "C-c M-h") #'jsonyter-kernel-history)
    (define-key map (kbd "C-c M-O") #'jsonyter-script-clear-all-output)
    (define-key map (kbd "C-c C-y") #'jsonyter-sync)
    (define-key map (kbd "C-c C-d") #'jsonyter-inspect)
    map)
  "Keymap for `jsonyter-script-mode'.")

;;;###autoload
(define-minor-mode jsonyter-script-mode
  "Run `# %%' cells in an ordinary script against a Jupyter kernel.

Output is shown inline in overlays, so the buffer's text — the file you
actually save — is never touched.

\\{jsonyter-script-mode-map}"
  :group 'jsonyter
  :lighter " Cells"
  :keymap jsonyter-script-mode-map
  (if jsonyter-script-mode
      (progn
        (setq-local jsonyter--callbacks (make-hash-table :test #'eql))
        (setq mode-line-process '(:eval (jsonyter--mode-line-string)))
        (add-hook 'kill-buffer-hook #'jsonyter--cleanup nil t)
        (add-hook 'after-change-functions
                  #'jsonyter--script-stale-after-change nil t)
        ;; TAB completion, call hints and `C-c C-d' from the live kernel;
        ;; see `jsonyter-completion-at-point'.
        (jsonyter--completion-enable #'jsonyter--script-code-context)
        (jsonyter-mode 1))
    (jsonyter-script-clear-all-output)
    (remove-hook 'kill-buffer-hook #'jsonyter--cleanup t)
    (remove-hook 'after-change-functions #'jsonyter--script-stale-after-change t)
    (jsonyter--completion-disable)
    (jsonyter-mode -1)))

;;;###autoload
(defun jsonyter-script-mode-maybe ()
  "Enable `jsonyter-script-mode' if this buffer has any `# %%' markers.
Suitable for a language mode hook."
  (when (and buffer-file-name
             (assq major-mode jsonyter-script-languages)
             (save-excursion
               (goto-char (point-min))
               (re-search-forward jsonyter-script-cell-regexp nil t)))
    (jsonyter-script-mode 1)))

(provide 'jsonyter-script)
;;; jsonyter-script.el ends here
