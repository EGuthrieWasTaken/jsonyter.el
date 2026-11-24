;;; jsonyter-org.el --- Org-mode source blocks (jy: sessions) -*- lexical-binding: t; -*-

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

;; Org-mode source blocks (jy: sessions).  One part of jsonyter.el, which loads
;; every part; see jsonyter.el for the overview and the entry points.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'jsonyter-notebook)
(require 'jsonyter-script)
(require 'jsonyter-complete)

;;;; Org-mode source blocks (jy: sessions)

;; A `#+begin_src' block whose `:session' header argument starts with
;; `jy:' becomes an executable jsonyter cell: `C-RET' runs it against a
;; kernel, output streams into an overlay beneath the block, and `C-c
;; C-s' commits that output to a `#+RESULTS:' drawer when you want it in
;; the file.  Anything without a `jy:' session behaves exactly as it does
;; today, so enabling this mode changes no existing Org file.
;;
;; Sessions are keyed (LANGUAGE . NAME) in the one buffer-wide session
;; table built for the REPL/notebook/script surfaces, so a variable a
;; `C-RET' run defines is visible to every later run in the same session,
;; and Python, R and SAS blocks in one file are simply three entries.
;; The buffer's `jsonyter--session-key' stays nil -- an Org buffer has no
;; single "current" session; each command resolves the session of the
;; block at point.
;;
;; Output lives in an overlay `after-string', exactly as a `# %%' script
;; cell's does: buffer text is untouched, so an exploratory run leaves
;; the file clean and out of `git diff'.  Org's own visibility cycling
;; hides a folded block's output for free (the overlay is anchored inside
;; the folded region); `org-indent-mode' does not prefix overlay strings,
;; so under a deeply nested heading the output frame sits a couple of
;; columns left of the code -- cosmetic, and only there.
;;
;; NOTE: `C-c C-c' here interrupts the session at point, matching the
;; REPL/notebook/script maps and the feature request's key table.  The
;; org-babel execution path (`C-c C-c' routed through
;; `org-babel-execute:LANG', export, tangle) is a later milestone; until
;; it lands, run blocks with `C-RET'/`S-RET', never `C-c C-c'.
;;
;; `org' is loaded lazily, when `jsonyter-org-mode' is first turned on,
;; so a REPL/notebook/script user never pays for it.

(defcustom jsonyter-org-image-directory "./.jsonyter/"
  "Directory, relative to the Org file, that committed figures are written to.
`jsonyter-org-commit-block' writes each image output to a
content-addressed file here and links it with `[[file:...]]'.  Set to
e.g. \"./images/\" to keep figures version-controlled beside the
document; with the default, add \".jsonyter/\" to `.gitignore'."
  :type 'directory
  :group 'jsonyter)

(defcustom jsonyter-org-stamp-results t
  "If non-nil, stamp a committed `#+RESULTS:' with its block's source hash.
Written as org's own `#+RESULTS[<hash>]:' slot, so a result reopened cold
knows which source produced it and jsonyter can flag it stale before any
kernel starts.  This is the same slot babel's `:cache yes' uses; the two
are mutually exclusive per block, so turn this off where you rely on
`:cache'."
  :type 'boolean
  :group 'jsonyter)

(defcustom jsonyter-org-mode-lighter " Jy"
  "Mode-line lighter for `jsonyter-org-mode'."
  :type 'string
  :group 'jsonyter)

(declare-function org-element-at-point "org-element" (&optional pom cached-only))
(declare-function org-element-type "org-element-ast" (node &optional anonymous))
(declare-function org-element-property "org-element-ast" (property node))
(declare-function org-babel-get-src-block-info "ob-core" (&optional light datum))
(declare-function org-babel-where-is-src-block-result "ob-core" (&optional insert info hash))
(declare-function org-babel-remove-result "ob-core" (&optional info keep-keyword))
(declare-function org-babel-next-src-block "ob-core" (&optional arg))
(declare-function org-babel-previous-src-block "ob-core" (&optional arg))
(defvar org-babel-src-block-regexp)

(defvar jsonyter-org-mode)              ; the minor-mode flag, defined below

(defvar-local jsonyter--org-cells nil
  "Output overlays for Org src blocks in this buffer, newest first.")
(defvar-local jsonyter--org-committed nil
  "Overlays framing committed `#+RESULTS:' drawers found stale on reload.")

(defconst jsonyter--org-results-re
  "^[ \t]*#\\+RESULTS\\(?:\\[\\([0-9a-f]+\\)\\]\\)?:[ \t]*$"
  "Matches a `#+RESULTS:' line, capturing its `[hash]' stamp if present.")

;;; Opting in and resolving the session

(defun jsonyter--org-block-info ()
  "`org-babel-get-src-block-info' for the block at point, or nil.
LIGHT, so noweb is not expanded and no kernel-language code runs."
  (ignore-errors (org-babel-get-src-block-info 'light)))

(defun jsonyter--org-session-key (info)
  "The (LANGUAGE . NAME) session key INFO opts into, or nil.

A block opts in when its `:session' header argument starts with `jy:'.
`jy:NAME' is a named session; bare `jy:' is the language's default
session for the buffer; `jy:@KERNEL-ID' attaches to a kernel already
running on the server.  Keyed by (language, name) to match org-babel's
own session identity, so `jy:main' in Python and in R are two kernels."
  (let ((session (and info (cdr (assq :session (nth 2 info))))))
    (when (and (stringp session) (string-prefix-p "jy:" session))
      (cons (nth 0 info) (substring session 3)))))

(defun jsonyter--org-key-at-point ()
  "The session key for the jy: block at point, or nil."
  (jsonyter--org-session-key (jsonyter--org-block-info)))

(defun jsonyter--org-in-jy-block-p ()
  "Non-nil when point is inside a src block that opts into jsonyter."
  (and (jsonyter--org-key-at-point) t))

(defun jsonyter--org-session-at-point (&optional noerror)
  "The `jsonyter--session' for the jy: block at point.
Returns nil, or signals unless NOERROR, when point is not in a jy: block
or that block has no session entry yet."
  (let ((key (jsonyter--org-key-at-point)))
    (cond
     ((and key (jsonyter--session key)))
     (noerror nil)
     ((null key)
      (user-error "jsonyter: point is not in a `:session jy:...' source block"))
     (t (user-error
         "jsonyter: no kernel session for this block yet (C-RET starts one)")))))

(defun jsonyter--org-connect (key &optional kernel-name)
  "Connect session KEY, honouring a `@KERNEL-ID' name as attach-not-start.
KERNEL-NAME pins the kernelspec for a started kernel.  Returns the session."
  (jsonyter--ensure-live-bridge)
  (let ((name (cdr key)))
    (if (string-prefix-p "@" name)
        (let ((session (jsonyter--session-put key)))
          (unless (jsonyter--live-p session)
            (jsonyter-kernel-connect (substring name 1) session))
          session)
      (jsonyter--connect-kernel key kernel-name))))

(defun jsonyter--org-ensure-session-at-point (&optional no-kernel)
  "Resolve and return the session for the jy: block at point.
With NO-KERNEL, register the session but do not start or attach a kernel."
  (let* ((info (or (jsonyter--org-block-info)
                   (user-error "jsonyter: no source block at point")))
         (key (or (jsonyter--org-session-key info)
                  (user-error "jsonyter: this block has no `:session jy:...'")))
         (kernel-name (cdr (assq :kernel (nth 2 info)))))
    (if no-kernel
        (jsonyter--session-put key)
      (jsonyter--org-connect key kernel-name))))

(defun jsonyter--org-buffer-has-jy-p ()
  "Non-nil if this buffer has any `:session jy:' -- inline or via a property."
  (save-excursion
    (goto-char (point-min))
    (re-search-forward ":session[ \t]+jy:" nil t)))

;;; Block geometry and the output overlay

(defun jsonyter--org-block-region ()
  "Return (BODY . ANCHOR) for the src block at point.
BODY is the block's source, trimmed.  ANCHOR is the position just after
the `#+end_src' line, where the output overlay hangs its `after-string'."
  (let* ((el (org-element-at-point))
         (begin (org-element-property :begin el))
         (body (string-trim (or (org-element-property :value el) "")))
         (anchor (save-excursion
                   (goto-char begin)
                   (if (re-search-forward "^[ \t]*#\\+end_src.*\n"
                                          (org-element-property :end el) t)
                       (point)
                     (org-element-property :end el)))))
    (cons body anchor)))

(defun jsonyter--org-cell-overlay (anchor &optional create)
  "The output overlay ending at ANCHOR, made when CREATE and absent."
  (or (seq-find (lambda (o) (overlay-get o 'jsonyter-org-cell))
                (overlays-in (max (point-min) (1- anchor)) anchor))
      (and create
           (let ((ov (make-overlay (max (point-min) (1- anchor)) anchor nil nil t)))
             (overlay-put ov 'jsonyter-org-cell t)
             (overlay-put ov 'evaporate nil)
             (push ov jsonyter--org-cells)
             ov))))

(defun jsonyter--org-cell-at (&optional pos)
  "The output overlay of the src block containing POS (default point), or nil."
  (save-excursion
    (when pos (goto-char pos))
    (when (jsonyter--org-block-info)
      (jsonyter--org-cell-overlay (cdr (jsonyter--org-block-region))))))

;;; Staleness of shown output

(defun jsonyter--org-stale-after-change (beg end _len)
  "Re-judge the output of any src block touched by an edit from BEG to END.
On `after-change-functions'; a no-op until some block has run."
  (when (or jsonyter--org-cells jsonyter--org-committed)
    (save-excursion
      (let (seen)
        (dolist (pos (list beg end))
          (goto-char pos)
          (let ((info (jsonyter--org-block-info)))
            (when info
              (pcase-let* ((`(,body . ,anchor) (jsonyter--org-block-region))
                           (ov (jsonyter--org-cell-overlay anchor)))
                (when (and ov (not (memq ov seen)))
                  (push ov seen)
                  (jsonyter--output-update-stale ov body))
                (jsonyter--org-refresh-committed-frame info body)))))))))

;;; Running a block

(defun jsonyter-org-run-block (&optional advance)
  "Run the jy: src block at point against its kernel, output inline.
With ADVANCE (\\[jsonyter-org-run-block-and-advance]) move to the next
jy: block afterwards.  Starts the block's session on first use."
  (interactive)
  (let* ((info (or (jsonyter--org-block-info)
                   (user-error "jsonyter: no source block at point")))
         (key (or (jsonyter--org-session-key info)
                  (user-error
                   "jsonyter: this block has no `:session jy:...' -- nothing to run")))
         (session (jsonyter--org-connect key (cdr (assq :kernel (nth 2 info))))))
    (when (jsonyter--session-busy session)
      (user-error "jsonyter: session %s is busy (C-c C-c to interrupt)"
                  (jsonyter--session-name session)))
    (pcase-let* ((`(,code . ,anchor) (jsonyter--org-block-region))
                 (ov (jsonyter--org-cell-overlay anchor t)))
      (if (string-blank-p code)
          (message "jsonyter: empty block")
        (overlay-put ov 'jsonyter-source-hash (jsonyter--source-hash code))
        (overlay-put ov 'jsonyter-output-stale nil)
        (overlay-put ov 'jsonyter-output-string "")
        (overlay-put ov 'jsonyter-raw-outputs nil)
        (jsonyter--nb-refresh-output ov)
        (setf (jsonyter--session-busy session) t)
        (force-mode-line-update)
        (jsonyter--send
         "execute"
         (append (list :kernel_id (jsonyter--session-kernel-id session) :code code)
                 (and jsonyter-stream-output '(:stream t)))
         (list
          :output (lambda (output) (jsonyter--nb-append-output ov output))
          :result
          (lambda (msg)
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
                      (jsonyter--nb-append-output ov o))))
                (when (equal (plist-get result :status) "aborted")
                  (jsonyter--nb-append-output
                   ov (list :type "stream" :name "stderr"
                            :text "[execution aborted]\n")))))))))))
    (when advance (jsonyter-org-next-block))))

(defun jsonyter-org-run-block-and-advance ()
  "Run the jy: block at point, then move to the next one."
  (interactive)
  (jsonyter-org-run-block t))

;; Org's own vocabulary for a `#+begin_src' unit is "block", not "cell",
;; so the primary names above say "block" -- but a user coming from the
;; notebook or script surface, where the vocabulary is "cell", reaches
;; for `jsonyter-org-run-cell(-and-advance)' by analogy and finds nothing.
;; These cost nothing and remove that papercut.
;;;###autoload
(defalias 'jsonyter-org-run-cell #'jsonyter-org-run-block
  "Run the jy: src block at point against its kernel, output inline.
An alias for `jsonyter-org-run-block', named for anyone reaching for it
by analogy with `jsonyter-notebook-run-cell' / `jsonyter-script-run-cell'.
Org's own vocabulary for a `#+begin_src' unit is \"block\", which is why
that stays the primary name.")
;;;###autoload
(defalias 'jsonyter-org-run-cell-and-advance #'jsonyter-org-run-block-and-advance
  "Run the jy: block at point, then move to the next one.
An alias for `jsonyter-org-run-block-and-advance'; see `jsonyter-org-run-cell'.")

(defun jsonyter-org-run-buffer ()
  "Run every jy: src block in the buffer, in order, waiting for each."
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (let ((seen 0))
      (while (jsonyter--org-goto-next-jy-block)
        (cl-incf seen)
        (jsonyter-org-run-block)
        (let* ((session (jsonyter--org-session-at-point 'noerror))
               (deadline (+ (float-time) 3600)))
          (while (and session (jsonyter--session-busy session)
                      (< (float-time) deadline))
            (accept-process-output jsonyter--process 0.05))))
      (message "jsonyter: ran %d jy: block%s" seen (if (= seen 1) "" "s")))))

;;; Navigation

(defun jsonyter--org-goto-next-jy-block ()
  "Move to the head of the next jy: block after point; return point or nil."
  (let ((found nil))
    (while (and (not found) (ignore-errors (org-babel-next-src-block) t))
      (when (jsonyter--org-in-jy-block-p) (setq found (point))))
    found))

(defun jsonyter-org-next-block ()
  "Move to the next jy: src block."
  (interactive)
  (or (jsonyter--org-goto-next-jy-block)
      (message "jsonyter: no further jy: block")))

(defun jsonyter-org-previous-block ()
  "Move to the previous jy: src block."
  (interactive)
  (let ((start (point)) (found nil))
    (while (and (not found) (ignore-errors (org-babel-previous-src-block) t))
      (when (jsonyter--org-in-jy-block-p) (setq found (point))))
    (unless found
      (goto-char start)
      (message "jsonyter: no earlier jy: block"))))

;;; Kernel control for the session at point

(defun jsonyter-org-interrupt ()
  "Interrupt the kernel of the jy: session at point."
  (interactive)
  (jsonyter-interrupt (jsonyter--org-session-at-point)))

(defun jsonyter-org-restart ()
  "Restart the kernel of the jy: session at point."
  (interactive)
  (jsonyter-restart (jsonyter--org-session-at-point)))

(defun jsonyter-org-reconnect ()
  "Reconnect the jy: session at point to the kernel it was last using."
  (interactive)
  (let* ((session (jsonyter--org-ensure-session-at-point 'no-kernel))
         (id (or (jsonyter--session-kernel-id session)
                 (plist-get (jsonyter--session-last-kernel session) :id))))
    (unless id
      (user-error "jsonyter: this session has no kernel to reconnect to"))
    (jsonyter-kernel-connect id session)))

(defun jsonyter-org-connect-kernel (kernel-id)
  "Attach the jy: session at point to KERNEL-ID, a kernel on the server."
  (interactive
   (list (progn (jsonyter--ensure-live-bridge)
                (jsonyter--read-kernel "Attach this block's session to kernel: "))))
  (jsonyter-kernel-connect kernel-id (jsonyter--org-ensure-session-at-point 'no-kernel)))

(defun jsonyter-org-kernel-history (&optional n)
  "Show the kernel history of the jy: session at point (N commands)."
  (interactive "P")
  (let ((session (jsonyter--org-session-at-point)))
    (jsonyter-kernel-history (and n (prefix-numeric-value n))
                             (jsonyter--session-kernel-id session))))

(defun jsonyter--org-code-context ()
  "The code context at point in an Org buffer: the body of a `jy:' block.
nil outside such a block, in its header and footer lines, and when the
block's session has not been created yet."
  (when (jsonyter--org-in-jy-block-p)
    (let ((el (org-element-at-point)))
      (when (eq (org-element-type el) 'src-block)
        (let* ((body-beg (save-excursion
                           (goto-char (org-element-property :post-affiliated el))
                           (forward-line 1)
                           (point)))
               (code (or (org-element-property :value el) ""))
               (pos (- (point) body-beg))
               (session (jsonyter--org-session-at-point 'noerror)))
          (when (and session (>= pos 0) (<= pos (length code)))
            (list :code code :pos pos :start body-beg :session session)))))))

(defun jsonyter-org-inspect (&optional detailed)
  "Show kernel documentation for the thing at point in a jy: block.
With a prefix argument DETAILED, ask for more detail."
  (interactive "P")
  (let ((session (jsonyter--org-session-at-point)))
    (unless (jsonyter--live-p session)
      (user-error "jsonyter: this block's kernel is not running"))
    (jsonyter-inspect detailed)))

;;; Clearing shown output

(defun jsonyter-org-clear-block-output ()
  "Discard the overlay output shown beneath the src block at point."
  (interactive)
  (let ((ov (jsonyter--org-cell-at)))
    (unless ov (user-error "jsonyter: no output at this block"))
    (setq jsonyter--org-cells (delq ov jsonyter--org-cells))
    (delete-overlay ov)
    (message "jsonyter: output cleared")))

(defun jsonyter-org-clear-all-output ()
  "Discard every overlay output in this buffer.
Committed `#+RESULTS:' drawers are buffer text and are left untouched."
  (interactive)
  (dolist (ov jsonyter--org-cells)
    (when (overlay-buffer ov) (delete-overlay ov)))
  (setq jsonyter--org-cells nil)
  (message "jsonyter: cleared all overlay output"))

;;; Committing output to a #+RESULTS: drawer  (M4)

(defun jsonyter--org-image-dir ()
  "Absolute path of the managed image directory for this buffer's file."
  (expand-file-name jsonyter-org-image-directory
                    (file-name-directory (or buffer-file-name
                                             default-directory))))

(defun jsonyter--org-managed-file-p (path)
  "Non-nil if PATH is inside this buffer's managed image directory."
  (let ((dir (file-name-as-directory (jsonyter--org-image-dir))))
    (string-prefix-p dir (expand-file-name path))))

(defun jsonyter--org-write-image (base64 ext)
  "Decode BASE64 and write the bytes to a content-addressed .EXT file.
Returns the file's path, relative to the Org file when it can be so the
`[[file:...]]' link stays portable."
  (let* ((bytes (base64-decode-string
                 (replace-regexp-in-string "[ \t\r\n]" "" base64)))
         (name (format "plot-%s.%s" (substring (secure-hash 'sha1 bytes) 0 12) ext))
         (dir (jsonyter--org-image-dir))
         (abs (expand-file-name name dir)))
    (make-directory dir t)
    (unless (file-exists-p abs)          ; content-addressed: identical => no write
      (let ((coding-system-for-write 'binary))
        (write-region bytes nil abs nil 'quiet)))
    (if buffer-file-name
        (file-relative-name abs (file-name-directory buffer-file-name))
      abs)))

(defun jsonyter--org-result-body (raw-outputs)
  "Render RAW-OUTPUTS (kernel-shape plists) as `#+RESULTS:' drawer lines.
Returns a string: fixed-width `: ' lines for text, `[[file:...]]' links
for images, each image also written to disk as a side effect."
  (let (lines)
    (dolist (o raw-outputs)
      (pcase (plist-get o :type)
        ("stream"
         (dolist (l (split-string (or (plist-get o :text) "") "\n"))
           (push (if (string-empty-p l) ":" (concat ": " l)) lines)))
        ((or "execute_result" "display_data" "update_display_data")
         (let* ((data (plist-get o :data))
                (png (jsonyter--mime data :image/png))
                (jpeg (jsonyter--mime data :image/jpeg))
                (svg (jsonyter--mime data :image/svg+xml))
                (txt (jsonyter--mime data :text/plain)))
           (cond
            (png  (push (format "[[file:%s]]" (jsonyter--org-write-image png "png")) lines))
            (jpeg (push (format "[[file:%s]]" (jsonyter--org-write-image jpeg "jpg")) lines))
            (svg  (push (format "[[file:%s]]"
                                (jsonyter--org-write-image (base64-encode-string
                                                            (encode-coding-string svg 'utf-8))
                                                           "svg"))
                        lines))
            (txt (dolist (l (split-string (ansi-color-filter-apply txt) "\n"))
                   (push (if (string-empty-p l) ":" (concat ": " l)) lines))))))
        ("error"
         (dolist (l (split-string
                     (ansi-color-filter-apply
                      (mapconcat #'identity (plist-get o :traceback) "\n"))
                     "\n"))
           (push (if (string-empty-p l) ":" (concat ": " l)) lines)))
        (_ nil)))
    (string-join (nreverse lines) "\n")))

(defun jsonyter--org-result-images (info)
  "Absolute paths of managed image files linked by INFO's current `#+RESULTS:'."
  (let ((pos (save-excursion (org-babel-where-is-src-block-result nil info))))
    (when pos
      (save-excursion
        (goto-char pos)
        (let* ((el (org-element-at-point))
               (end (org-element-property :end el))
               files)
          (while (re-search-forward "\\[\\[file:\\([^]]+\\)\\]\\]" end t)
            (let ((f (expand-file-name (match-string 1))))
              (when (jsonyter--org-managed-file-p f) (push f files))))
          files)))))

(defun jsonyter--org-commit-1 (info hash raw-outputs)
  "Replace INFO's block's `#+RESULTS:' with RAW-OUTPUTS, stamped HASH.
Deletes managed image files the previous result referenced but the new
one does not.  Point must be in the block."
  (let* ((old-images (jsonyter--org-result-images info))
         (body (jsonyter--org-result-body raw-outputs)) ; writes the image files
         (new-images (jsonyter--org-result-images info))
         ;; The old result sits *below* `#+end_src', so removing it never
         ;; shifts this anchor -- compute it once, up front.
         (anchor (save-excursion
                   (goto-char (org-element-property :end (org-element-at-point)))
                   (skip-chars-backward "\n \t")
                   (line-beginning-position 2))))
    (org-babel-remove-result info)
    (save-excursion
      (goto-char (min anchor (point-max)))
      (unless (bolp) (insert "\n"))
      (insert (if (and jsonyter-org-stamp-results hash)
                  (format "#+RESULTS[%s]:\n" (substring hash 0 7))
                "#+RESULTS:\n")
              ":results:\n"
              (if (string-empty-p body) "" (concat body "\n"))
              ":end:\n"))
    (dolist (f old-images)
      (unless (member f new-images)
        (ignore-errors (delete-file f))))))

(defun jsonyter-org-commit-block ()
  "Commit the shown output of the src block at point to a `#+RESULTS:' drawer.
Overlay output is session-only until this is run; afterwards it is in the
file, exportable, and stamped with the source hash it came from."
  (interactive)
  (let* ((info (or (jsonyter--org-block-info)
                   (user-error "jsonyter: no source block at point")))
         (ov (jsonyter--org-cell-at))
         (raw (and ov (overlay-get ov 'jsonyter-raw-outputs))))
    (unless raw
      (user-error "jsonyter: this block has no shown output to commit"))
    (jsonyter--org-commit-1 info (overlay-get ov 'jsonyter-source-hash) raw)
    ;; The committed text now IS the result; drop the overlay so the two
    ;; are not shown twice.
    (setq jsonyter--org-cells (delq ov jsonyter--org-cells))
    (delete-overlay ov)
    (message "jsonyter: committed output to #+RESULTS:")))

(defun jsonyter-org-commit-buffer ()
  "Commit every block's shown overlay output to its `#+RESULTS:' drawer.
Blocks with no shown output this session are left exactly as they were."
  (interactive)
  (let ((n 0))
    (dolist (ov (copy-sequence jsonyter--org-cells))
      (when (and (overlay-buffer ov) (overlay-get ov 'jsonyter-raw-outputs))
        (save-excursion
          (goto-char (overlay-start ov))
          (let ((info (jsonyter--org-block-info)))
            (when info
              (jsonyter--org-commit-1 info (overlay-get ov 'jsonyter-source-hash)
                                      (overlay-get ov 'jsonyter-raw-outputs))
              (cl-incf n)))
          (setq jsonyter--org-cells (delq ov jsonyter--org-cells))
          (delete-overlay ov))))
    (message "jsonyter: committed %d block%s" n (if (= n 1) "" "s"))))

(defun jsonyter-org-clean-images ()
  "Delete managed image files no `#+RESULTS:' in this buffer still links."
  (interactive)
  (let ((dir (jsonyter--org-image-dir))
        (linked (make-hash-table :test #'equal))
        (removed 0))
    (unless (file-directory-p dir)
      (user-error "jsonyter: no managed image directory at %s" dir))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "\\[\\[file:\\([^]]+\\)\\]\\]" nil t)
        (puthash (expand-file-name (match-string 1)) t linked)))
    (dolist (f (directory-files dir t "\\`plot-.*\\.\\(png\\|jpg\\|svg\\)\\'"))
      (unless (gethash f linked)
        (ignore-errors (delete-file f) (cl-incf removed))))
    (message "jsonyter: removed %d unreferenced image%s"
             removed (if (= removed 1) "" "s"))))

;;; Staleness of a committed result, known before any kernel starts  (M4)

(defun jsonyter--org-refresh-committed-frame (info body)
  "Frame INFO's committed `#+RESULTS:' as stale when its stamp != BODY's hash."
  (when jsonyter-org-stamp-results
    (let ((pos (save-excursion (org-babel-where-is-src-block-result nil info))))
      (when pos
        (save-excursion
          (goto-char pos)
          (when (looking-at jsonyter--org-results-re)
            (let* ((stamp (match-string 1))
                   (el (org-element-at-point))
                   (beg (line-beginning-position))
                   (end (org-element-property :end el))
                   (stale (and stamp
                               (not (equal stamp
                                           (substring (jsonyter--source-hash body)
                                                      0 (length stamp))))))
                   (ov (seq-find (lambda (o) (overlay-get o 'jsonyter-org-committed))
                                 (overlays-in beg (1+ beg)))))
              (cond
               ((and stale (not ov))
                (setq ov (make-overlay beg end))
                (overlay-put ov 'jsonyter-org-committed t)
                (overlay-put ov 'evaporate t)
                (overlay-put ov 'face 'jsonyter-output-border-stale-face)
                (overlay-put ov 'help-echo
                             "Source edited since this result was committed — re-run and re-commit")
                (push ov jsonyter--org-committed))
               ((and ov (not stale))
                (setq jsonyter--org-committed (delq ov jsonyter--org-committed))
                (delete-overlay ov))
               ((and ov stale)
                (move-overlay ov beg end))))))))))

(defun jsonyter--org-scan-committed ()
  "On mode start, frame every committed `#+RESULTS:' whose jy: block has changed.
Walks the jy: blocks forward -- from a block one can always find its own
result, where the reverse is not reliable."
  (save-excursion
    (goto-char (point-min))
    (while (jsonyter--org-goto-next-jy-block)
      (let ((info (jsonyter--org-block-info)))
        (when info
          (jsonyter--org-refresh-committed-frame
           info (string-trim (or (org-element-property
                                  :value (org-element-at-point))
                                 ""))))))))

;;; The minor mode

(defun jsonyter--org-fallthrough ()
  "Run the command this key would run with `jsonyter-org-mode' off."
  (let* ((jsonyter-org-mode nil)
         (cmd (key-binding (this-command-keys-vector) t)))
    (if (commandp cmd)
        (progn (setq this-command cmd) (call-interactively cmd))
      (ding))))

(defmacro jsonyter--org-defkey (name jy-command doc)
  "Define command NAME with docstring DOC.
In a jy: src block it runs JY-COMMAND; anywhere else it falls through to
whatever the invoking key does with `jsonyter-org-mode' off."
  `(defun ,name ()
     ,doc
     (interactive)
     (if (jsonyter--org-in-jy-block-p)
         (call-interactively #',jy-command)
       (jsonyter--org-fallthrough))))

(jsonyter--org-defkey jsonyter-org-C-RET jsonyter-org-run-block
  "Run the jy: block at point, else `org-insert-heading-respect-content'.")
(jsonyter--org-defkey jsonyter-org-S-RET jsonyter-org-run-block-and-advance
  "Run the jy: block at point and advance, else org's own `S-RET'.")
(jsonyter--org-defkey jsonyter-org-C-c-C-c jsonyter-org-interrupt
  "Interrupt the jy: session at point, else `org-ctrl-c-ctrl-c'.")
(jsonyter--org-defkey jsonyter-org-C-c-C-r jsonyter-org-restart
  "Restart the jy: session at point, else `org-ctrl-c-ctrl-r'.")
(jsonyter--org-defkey jsonyter-org-C-c-C-l jsonyter-org-reconnect
  "Reconnect the jy: session at point, else `org-insert-link'.")
(jsonyter--org-defkey jsonyter-org-C-c-C-j jsonyter-org-connect-kernel
  "Attach the jy: session at point to a kernel, else `org-goto'.")
(jsonyter--org-defkey jsonyter-org-C-c-M-h jsonyter-org-kernel-history
  "Kernel history for the jy: session at point, else org's `C-c M-h'.")
(jsonyter--org-defkey jsonyter-org-C-c-C-d jsonyter-org-inspect
  "Documentation for the thing at point in a jy: block, else `org-deadline'.")
(jsonyter--org-defkey jsonyter-org-C-c-M-o jsonyter-org-clear-block-output
  "Clear this jy: block's shown output, else org's `C-c M-o'.")
(jsonyter--org-defkey jsonyter-org-C-c-C-s jsonyter-org-commit-block
  "Commit this jy: block's output to `#+RESULTS:', else `org-schedule'.")

(defvar jsonyter-org-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "<C-return>") #'jsonyter-org-C-RET)
    (define-key map (kbd "<S-return>") #'jsonyter-org-S-RET)
    (define-key map (kbd "C-c C-v C-b") #'jsonyter-org-run-buffer)
    (define-key map (kbd "C-c C-n") #'jsonyter-org-next-block)
    (define-key map (kbd "C-c C-p") #'jsonyter-org-previous-block)
    (define-key map (kbd "C-c C-c") #'jsonyter-org-C-c-C-c)
    (define-key map (kbd "C-c C-r") #'jsonyter-org-C-c-C-r)
    (define-key map (kbd "C-c C-l") #'jsonyter-org-C-c-C-l)
    (define-key map (kbd "C-c C-j") #'jsonyter-org-C-c-C-j)
    (define-key map (kbd "C-c M-h") #'jsonyter-org-C-c-M-h)
    (define-key map (kbd "C-c C-d") #'jsonyter-org-C-c-C-d)
    (define-key map (kbd "C-c M-o") #'jsonyter-org-C-c-M-o)
    (define-key map (kbd "C-c M-O") #'jsonyter-org-clear-all-output)
    (define-key map (kbd "C-c C-s") #'jsonyter-org-C-c-C-s)
    (define-key map (kbd "C-c C-M-s") #'jsonyter-org-commit-buffer)
    map)
  "Keymap for `jsonyter-org-mode'.
Every binding that shadows an Org command is conditional: inside a jy:
src block it runs the jsonyter action, everywhere else it falls through
to what Org would otherwise do.  `C-c C-n' / `C-c C-p' are the exception
-- they always jump to the next / previous jy: block, since that is
useful from anywhere in the file.")

;;;###autoload
(define-minor-mode jsonyter-org-mode
  "Run `#+begin_src' blocks with a `:session jy:...' against Jupyter kernels.

`C-RET' runs the block at point; output streams into an overlay beneath
it and never touches buffer text.  `C-c C-s' commits that output to a
`#+RESULTS:' drawer when you want it saved.  Blocks without a `jy:'
session are left entirely to Org.

\\{jsonyter-org-mode-map}"
  :group 'jsonyter
  :lighter jsonyter-org-mode-lighter
  :keymap jsonyter-org-mode-map
  (if jsonyter-org-mode
      (progn
        (unless (derived-mode-p 'org-mode)
          (setq jsonyter-org-mode nil)
          (user-error "jsonyter-org-mode is only for Org buffers"))
        (require 'org)
        (require 'ob-core)
        (setq-local jsonyter--callbacks (make-hash-table :test #'eql))
        (setq-local jsonyter--session-key nil) ; per-block, never a "current" one
        (setq mode-line-process '(:eval (jsonyter--mode-line-string)))
        (add-hook 'kill-buffer-hook #'jsonyter--cleanup nil t)
        (add-hook 'after-change-functions #'jsonyter--org-stale-after-change nil t)
        ;; TAB completion, call hints and `C-c C-d' from the block's own
        ;; kernel; see `jsonyter-completion-at-point'.
        (jsonyter--completion-enable #'jsonyter--org-code-context)
        (jsonyter-mode 1)
        (jsonyter--org-scan-committed))
    (jsonyter-org-clear-all-output)
    (dolist (ov jsonyter--org-committed)
      (when (overlay-buffer ov) (delete-overlay ov)))
    (setq jsonyter--org-committed nil)
    (remove-hook 'kill-buffer-hook #'jsonyter--cleanup t)
    (remove-hook 'after-change-functions #'jsonyter--org-stale-after-change t)
    (jsonyter--completion-disable)
    (jsonyter-mode -1)))

;;;###autoload
(defun jsonyter-org-mode-maybe ()
  "Enable `jsonyter-org-mode' when this Org buffer has a `jy:' session.
Suitable for `org-mode-hook'."
  (when (and (derived-mode-p 'org-mode) (jsonyter--org-buffer-has-jy-p))
    (jsonyter-org-mode 1)))

(provide 'jsonyter-org)
;;; jsonyter-org.el ends here
