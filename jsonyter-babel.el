;;; jsonyter-babel.el --- The org-babel backend -*- lexical-binding: t; -*-

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

;; The org-babel backend.  One part of jsonyter.el, which loads
;; every part; see jsonyter.el for the overview and the entry points.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'jsonyter-org)
(require 'jsonyter-script)

;;;; The org-babel backend (M5/M6)

;; `jsonyter-org-mode' is one front door: `C-RET' against an overlay,
;; never touching buffer text until `C-c C-s' commits it.  This is the
;; other: `org-babel-execute:python' (and `:R', `:julia', `:SAS') routed
;; through jsonyter whenever a block's `:session' carries the `jy:'
;; prefix, so `C-c C-c', export and `org-babel-tangle' all work on a
;; `jy:' block too -- and, because session resolution is shared with the
;; cell layer (`jsonyter--org-connect', keyed the same way), a variable a
;; `C-RET' run defines is visible to a `C-c C-c' run in the same session
;; and back again.  A block with no `jy:' session is untouched: dispatch
;; falls through to whatever `org-babel-execute:LANG' Org (or a third
;; party) already defines, exactly as if jsonyter did not exist.
;;
;; This backend works with `jsonyter-org-mode' off.  Export in particular
;; may run without the cell layer ever having been turned on for the
;; buffer, so `jsonyter--org-babel-ensure-plumbing' sets up just enough
;; buffer-local state (a bridge, a callback table, a session table) for
;; that to work on its own.
;;
;; Registration is lazy and global: `with-eval-after-load' on `ob-core'
;; costs nothing in a REPL, notebook or script buffer that never loads
;; Org at all, and fires the moment anything -- `jsonyter-org-mode', or
;; the user's own unrelated Org-babel use -- actually loads it, which is
;; what lets `C-c C-c' work in a buffer that only ever uses this back
;; door.

(declare-function org-babel-process-params "ob-core" (params))
(declare-function org-babel-insert-result
                   "ob-core" (result &optional result-params info hash lang exec-time))
(declare-function org-babel-spec-to-string "ob-tangle" (spec))

(defun jsonyter--org-babel-jy-p (params)
  "Non-nil when PARAMS' `:session' header argument starts with `jy:'."
  (let ((session (cdr (assq :session params))))
    (and (stringp session) (string-prefix-p "jy:" session))))

(defun jsonyter--org-babel-key (lang params)
  "The (LANG . NAME) session key PARAMS opts into via `:session jy:...'."
  (cons lang (substring (cdr (assq :session params)) 3)))

(defun jsonyter--org-babel-ensure-plumbing ()
  "Make sure this Org buffer can talk to a bridge, `jsonyter-org-mode' or not.
The babel back door is independent of the cell layer (Part 5 of the
feature request), so it cannot assume the minor mode's enable body ever
ran to set up `jsonyter--callbacks', the session table pointer, and
shutdown-on-kill.  Installs exactly that much and no more -- no keymap,
no staleness hook -- since those are cell-layer UI this path does not
need."
  (unless (bound-and-true-p jsonyter-mode)
    (setq-local jsonyter--callbacks (make-hash-table :test #'eql))
    (setq-local jsonyter--session-key nil)
    (add-hook 'kill-buffer-hook #'jsonyter--cleanup nil t)
    (jsonyter-mode 1)))

;;; Converting kernel outputs to an org-babel result value

(defun jsonyter--org-babel-mime (outputs key)
  "The last KEY mimetype string among OUTPUTS' `:data', or nil."
  (let (found)
    (dolist (o outputs found)
      (let ((v (jsonyter--mime (plist-get o :data) key)))
        (when v (setq found v))))))

(defun jsonyter--org-babel-image (outputs)
  "Write the first image among OUTPUTS to the managed directory; its path, or nil.
Reuses `jsonyter--org-write-image' (M4), so this only ever runs with an
Org buffer current."
  (catch 'done
    (dolist (o outputs)
      (let* ((data (plist-get o :data))
             (png (jsonyter--mime data :image/png))
             (jpeg (jsonyter--mime data :image/jpeg))
             (svg (jsonyter--mime data :image/svg+xml)))
        (cond
         (png (throw 'done (jsonyter--org-write-image png "png")))
         (jpeg (throw 'done (jsonyter--org-write-image jpeg "jpg")))
         (svg (throw 'done
                (jsonyter--org-write-image
                 (base64-encode-string (encode-coding-string svg 'utf-8)) "svg"))))))
    nil))

(defun jsonyter--org-babel-value (outputs result-type result-params)
  "The Lisp result value `org-babel-insert-result' should insert for OUTPUTS.

Follows the feature request's Part 5 mapping: an error's traceback (ANSI
stripped) always wins, since there is nothing else to show; an image is
written to `jsonyter-org-image-directory' and returned as a bare path
when \"file\" is in RESULT-PARAMS -- exactly the existing Org convention
for a `:results file' block, so `org-babel-insert-result' turns it into
the `[[file:...]]' link itself; `text/html'/`text/latex' are returned
plain when \"html\"/\"latex\" is requested, for the same reason.
Otherwise: stream text verbatim for RESULT-TYPE `output', or the last
`execute_result''s `text/plain' for `value' (Jupyter's own value/output
distinction lines up with babel's), falling back to stream text if there
was no execute_result to show."
  (let* ((errors (seq-filter (lambda (o) (equal (plist-get o :type) "error")) outputs))
         (streams (seq-filter (lambda (o) (equal (plist-get o :type) "stream")) outputs))
         (rich (seq-filter (lambda (o) (member (plist-get o :type)
                                               '("execute_result" "display_data"
                                                 "update_display_data")))
                           outputs))
         (values (seq-filter (lambda (o) (equal (plist-get o :type) "execute_result")) rich)))
    (cond
     (errors
      (mapconcat (lambda (o) (ansi-color-filter-apply
                              (mapconcat #'identity (plist-get o :traceback) "\n")))
                errors "\n"))
     ((member "file" result-params) (or (jsonyter--org-babel-image rich) ""))
     ((member "html" result-params) (or (jsonyter--org-babel-mime rich :text/html) ""))
     ((member "latex" result-params) (or (jsonyter--org-babel-mime rich :text/latex) ""))
     ((eq result-type 'output)
      (mapconcat (lambda (o) (or (plist-get o :text) "")) streams ""))
     (t (or (jsonyter--org-babel-mime values :text/plain)
            (mapconcat (lambda (o) (or (plist-get o :text) "")) streams ""))))))

;;; Running the code (synchronous and `:async yes')

(defun jsonyter--org-babel-async-p (params)
  "Non-nil when PARAMS' `:async' header argument is \"yes\"."
  (let ((async (cdr (assq :async params))))
    (and async (not (member async '("no" "nil"))))))

(defun jsonyter--org-babel-token ()
  "A short opaque token identifying one pending `:async yes' placeholder."
  (substring (secure-hash 'sha1 (format "%s%s%s" (buffer-name) (float-time) (random)))
             0 10))

(defun jsonyter--org-babel-async-reply (token msg)
  "Find the `:async yes' placeholder for TOKEN and replace it with MSG's result.
Runs with the block's own buffer current.  Locates the placeholder by
searching for TOKEN's literal text, then the nearest preceding
`#+begin_src' line, so it works from nothing but what is already in the
buffer -- no marker to go stale, no copy of the original params to fall
out of sync with a header-arg edited in the meantime.  If the
placeholder is gone -- the block was edited or deleted before the kernel
replied -- the result is dropped, with a message saying so, exactly as
the feature request's own answer to that edge case asks."
  (save-excursion
    (goto-char (point-min))
    (if (not (search-forward (format "[[%s]]" token) nil t))
        (message "jsonyter: async result [%s] arrived for a block that no longer has its placeholder — dropped" token)
      (let ((src (save-excursion
                   (goto-char (line-beginning-position))
                   (and (re-search-backward "^[ \t]*#\\+begin_src" nil t) (point)))))
        (if (not src)
            (message "jsonyter: async result [%s]: no source block found — dropped" token)
          (goto-char src)
          (let ((info (jsonyter--org-block-info)))
            (if (not info)
                (message "jsonyter: async result [%s]: source block is gone — dropped" token)
              (let* ((params (org-babel-process-params (nth 2 info)))
                     (lang (nth 0 info))
                     (err (plist-get msg :error))
                     (value (if err
                                (format "jsonyter: execute failed: %s" (jsonyter--error-message err))
                              (jsonyter--org-babel-value
                               (plist-get (plist-get msg :result) :outputs)
                               (or (cdr (assq :result-type params)) 'value)
                               (cdr (assq :result-params params))))))
                (org-babel-insert-result value (cdr (assq :result-params params)) info nil lang)
                (message "jsonyter: async result [%s] inserted" token)))))))))

(defun jsonyter--org-babel-execute (lang body params)
  "Run BODY (already noweb-expanded) for a `:session jy:...' block in LANG.

Shared by every `org-babel-execute:LANG' wrapper.  Returns the Lisp value
`org-babel-insert-result' should insert.  With `:async yes' and outside
export, returns a placeholder immediately instead and lets
`jsonyter--org-babel-async-reply' replace it once the kernel answers;
export always forces the synchronous path, bounded by
`jsonyter-exec-timeout', since `ox' collects the whole buffer in one pass
and has nowhere for an async result to land.  A second execute on a
session already busy is refused, matching the cell layer's own guard,
rather than queued or made to interrupt the first."
  (jsonyter--org-babel-ensure-plumbing)
  (let* ((key (jsonyter--org-babel-key lang params))
         (session (jsonyter--org-connect key (cdr (assq :kernel params)))))
    (when (jsonyter--session-busy session)
      (user-error "jsonyter: session %s is busy (C-c C-c in a jy: block interrupts it)"
                  (jsonyter--session-name session)))
    (let* ((code (jsonyter--org-var-code lang body params))
           (result-type (or (cdr (assq :result-type params)) 'value))
           (result-params (cdr (assq :result-params params)))
           (async (and (jsonyter--org-babel-async-p params)
                       (not (bound-and-true-p org-export-current-backend))))
           (kernel-id (jsonyter--session-kernel-id session)))
      (setf (jsonyter--session-busy session) t)
      (force-mode-line-update)
      (if async
          (let ((token (jsonyter--org-babel-token))
                (buf (current-buffer)))
            (jsonyter--send
             "execute" (list :kernel_id kernel-id :code code)
             (list :result
                   (lambda (msg)
                     (setf (jsonyter--session-busy session) nil)
                     (when (buffer-live-p buf)
                       (with-current-buffer buf
                         (force-mode-line-update)
                         (jsonyter--org-babel-async-reply token msg))))))
            (format "jsonyter: running… [[%s]]" token))
        (let ((reply 'jsonyter--pending))
          (jsonyter--send
           "execute" (list :kernel_id kernel-id :code code)
           (list :result (lambda (msg) (setq reply msg))))
          (let ((deadline (+ (float-time) (min 3600 (or jsonyter-exec-timeout 3600)))))
            (while (and (eq reply 'jsonyter--pending)
                        (process-live-p jsonyter--process)
                        (< (float-time) deadline))
              (accept-process-output jsonyter--process 0.05)))
          (setf (jsonyter--session-busy session) nil)
          (force-mode-line-update)
          (when (eq reply 'jsonyter--pending)
            (error "jsonyter: %s timed out waiting for a reply"
                   (jsonyter--session-name session)))
          (let ((err (plist-get reply :error)))
            (when err (error "jsonyter: %s" (jsonyter--error-message err))))
          (jsonyter--org-babel-value
           (plist-get (plist-get reply :result) :outputs) result-type result-params))))))

;;; Registering the wrappers

(defun jsonyter--org-babel-dispatch (lang orig-fun body params)
  "Shared body for every `org-babel-execute:LANG' wrapper.
Runs BODY through jsonyter when PARAMS opts into a `jy:' session;
otherwise calls ORIG-FUN the way Org itself would have.  With no
ORIG-FUN at all -- a language, such as SAS on a stock install, that Org
ships no backend for -- signals the same \"no org-babel-execute
function\" error Org's own dispatcher raises for any other unconfigured
language."
  (if (jsonyter--org-babel-jy-p params)
      (jsonyter--org-babel-execute lang body params)
    (if orig-fun
        (funcall orig-fun body params)
      (error "No org-babel-execute function for %s!" lang))))

;;;###autoload
(defun jsonyter--org-babel-execute:python (orig-fun body params)
  "Advice for `org-babel-execute:python'; see `jsonyter--org-babel-dispatch'."
  (jsonyter--org-babel-dispatch "python" orig-fun body params))
;;;###autoload
(defun jsonyter--org-babel-standalone:python (body params)
  "Standalone `org-babel-execute:python' for when nothing else defines one."
  (jsonyter--org-babel-dispatch "python" nil body params))

;;;###autoload
(defun jsonyter--org-babel-execute:R (orig-fun body params)
  "Advice for `org-babel-execute:R'; see `jsonyter--org-babel-dispatch'."
  (jsonyter--org-babel-dispatch "R" orig-fun body params))
;;;###autoload
(defun jsonyter--org-babel-standalone:R (body params)
  "Standalone `org-babel-execute:R' for when nothing else defines one."
  (jsonyter--org-babel-dispatch "R" nil body params))

;;;###autoload
(defun jsonyter--org-babel-execute:julia (orig-fun body params)
  "Advice for `org-babel-execute:julia'; see `jsonyter--org-babel-dispatch'."
  (jsonyter--org-babel-dispatch "julia" orig-fun body params))
;;;###autoload
(defun jsonyter--org-babel-standalone:julia (body params)
  "Standalone `org-babel-execute:julia' for when nothing else defines one."
  (jsonyter--org-babel-dispatch "julia" nil body params))

;;;###autoload
(defun jsonyter--org-babel-execute:SAS (orig-fun body params)
  "Advice for `org-babel-execute:SAS'; see `jsonyter--org-babel-dispatch'."
  (jsonyter--org-babel-dispatch "SAS" orig-fun body params))
;;;###autoload
(defun jsonyter--org-babel-standalone:SAS (body params)
  "Standalone `org-babel-execute:SAS' -- Org itself ships no SAS backend at all."
  (jsonyter--org-babel-dispatch "SAS" nil body params))

;;;###autoload
(defvar jsonyter--org-babel-registered nil
  "Non-nil once the `org-babel-execute:LANG' wrappers have been installed.")

;;;###autoload
(with-eval-after-load 'ob-core
  ;; An autoload cookie on a form that is not a definition copies the form
  ;; itself into `jsonyter-autoloads.el', which Emacs loads at startup with
  ;; jsonyter.el still unloaded.  So this body may call nothing but subrs
  ;; and the autoloaded `jsonyter--org-babel-execute:LANG' and
  ;; `jsonyter--org-babel-standalone:LANG' wrappers above -- a helper of
  ;; jsonyter's own would be a `void-function' the moment Org loaded, and a
  ;; `require' of jsonyter here would pull the whole package into every
  ;; Emacs that so much as opens an Org file.  Installing the wrappers is
  ;; eager, since export and `C-c C-c' both have to find a `jy:' block
  ;; already routed, but each one is only an autoload until a block runs
  ;; it, so jsonyter itself loads no earlier than the first block that
  ;; needs it.
  ;;
  ;; Julia's Org backend is newer than the rest and SAS's does not exist in
  ;; Org at all, so each `require' is best-effort.  Advice wraps whatever
  ;; already defines `org-babel-execute:LANG' -- Org's own, or a third
  ;; party's -- so a non-`jy:' block keeps running exactly as it did before
  ;; jsonyter was installed; jsonyter's own standalone function goes in
  ;; outright when nothing defines one, so a language Org ships no backend
  ;; for at all still gets one, live only inside a `:session jy:...' block.
  (unless jsonyter--org-babel-registered
    (setq jsonyter--org-babel-registered t)
    (require 'ob-python nil t)
    (require 'ob-R nil t)
    (require 'ob-julia nil t)
    (dolist (lang '("python" "R" "julia" "SAS"))
      (let ((cmd (intern (concat "org-babel-execute:" lang)))
            (advice (intern (concat "jsonyter--org-babel-execute:" lang)))
            (standalone (intern (concat "jsonyter--org-babel-standalone:" lang))))
        (if (fboundp cmd)
            (advice-add cmd :around advice)
          (defalias cmd standalone))))))

;;; Tangling to `# %%' scripts by default

(defcustom jsonyter-org-tangle-cell-markers t
  "If non-nil, prefix each tangled `jy:' block with a `# %%' cell marker.
Matches `jsonyter-script-cell-regexp', so a file `org-babel-tangle'
writes out of one or more `jy:' blocks opens ready for
`jsonyter-script-mode'.  Blocks with no `jy:' session are never marked;
this only changes what a `jy:' block tangles to."
  :type 'boolean
  :group 'jsonyter)

;;;###autoload
(defun jsonyter--org-tangle-mark-cell (orig-fun spec)
  "Around-advice on `org-babel-spec-to-string': prefix a `jy:' SPEC with `# %%'."
  (when (and jsonyter-org-tangle-cell-markers (jsonyter--org-babel-jy-p (nth 4 spec)))
    (insert "# %%\n"))
  (funcall orig-fun spec))

;;;###autoload
(with-eval-after-load 'ob-tangle
  (advice-add 'org-babel-spec-to-string :around #'jsonyter--org-tangle-mark-cell))


;;;; `:var' marshalling (M7)

;; Values arrive from Org already resolved to Lisp: a scalar as a string
;; or number, a table as a list of row-lists.  Each language's own
;; `jsonyter--org-var-value-LANG' turns one such binding into a prelude
;; statement, prepended to the block's code ahead of execution -- there
;; is no hook in `org-babel-execute:LANG' for this the way
;; `org-babel-variable-assignments:LANG' gives other backends; jsonyter
;; is on its own for it, per the feature request's Part 8.

(defcustom jsonyter-org-var-size-limit 100000
  "Largest size, in characters, of any single `:var' binding jsonyter will send.
A large Org table becomes a large piece of code sent to the kernel;
past this limit jsonyter signals a clear error instead of a slow or
silently oversized execute payload.  Read the data from the kernel's own
filesystem instead for anything bigger."
  :type 'integer
  :group 'jsonyter)

(defcustom jsonyter-org-var-julia-dataframe nil
  "If non-nil, marshal a `:var' table with `:colnames yes' as a DataFrame in Julia.
Off by default: unlike Python's pandas, Julia's DataFrames.jl is not a
near-universal dependency, and jsonyter will not silently `using' a
package that may not be installed.  Turning this on is a promise that
the session already has it loaded.  With this off, or without
`:colnames', a Julia `:var' table is always a plain `Matrix'."
  :type 'boolean
  :group 'jsonyter)

(defun jsonyter--org-var-shape (value)
  "`table', `row', or `scalar' -- how a `:var' binding's Lisp shape reads."
  (cond
   ((not (listp value)) 'scalar)
   ((and value (seq-every-p #'listp value)) 'table)
   (t 'row)))

(defun jsonyter--org-var-check-size (name value)
  "Signal a clear error when NAME's VALUE is over `jsonyter-org-var-size-limit'."
  (let ((size (length (format "%S" value))))
    (when (> size jsonyter-org-var-size-limit)
      (user-error
       "jsonyter: `:var %s' is %d characters, over `jsonyter-org-var-size-limit' (%d) — read it from the kernel's filesystem instead"
       name size jsonyter-org-var-size-limit))))

(defun jsonyter--org-var-quote-c (s)
  "Format string S as a double-quoted literal shared by Python, R and Julia.
All three escape a double-quoted string the same C-like way, so one
quoting function serves all three languages' scalar and table cells."
  (concat "\""
          (replace-regexp-in-string
           "[\\\"\n\t\r]"
           (lambda (m)
             (pcase m
               ("\\" "\\\\") ("\"" "\\\"")
               ("\n" "\\n") ("\t" "\\t") ("\r" "\\r")))
           s nil t)
          "\""))

(defun jsonyter--org-var-atom (value null true)
  "Format scalar VALUE, using NULL and TRUE for Lisp nil and t respectively."
  (cond ((stringp value) (jsonyter--org-var-quote-c value))
        ((numberp value) (format "%s" value))
        ((null value) null)
        ((eq value t) true)
        (t (jsonyter--org-var-quote-c (format "%s" value)))))

(defun jsonyter--org-var-atom-python (value)
  "Format scalar VALUE as a Python literal."
  (jsonyter--org-var-atom value "None" "True"))
(defun jsonyter--org-var-atom-r (value)
  "Format scalar VALUE as an R literal."
  (jsonyter--org-var-atom value "NA" "TRUE"))
(defun jsonyter--org-var-atom-julia (value)
  "Format scalar VALUE as a Julia literal."
  (jsonyter--org-var-atom value "nothing" "true"))

(defun jsonyter--org-var-value-python (name value colnames)
  "One Python prelude statement binding NAME to VALUE.
A table becomes a list of lists, or -- with COLNAMES, from `:colnames
yes' -- a `pandas.DataFrame'; jsonyter imports pandas itself in that
case, on the view that asking for column names is asking for a
DataFrame, and the import is a cheap no-op if the kernel has it already."
  (pcase (jsonyter--org-var-shape value)
    ('table
     (let ((rows (concat "[" (mapconcat
                              (lambda (row)
                                (concat "[" (mapconcat #'jsonyter--org-var-atom-python row ", ") "]"))
                              value ", ")
                         "]")))
       (if colnames
           (format "import pandas as pd\n%s = pd.DataFrame(%s, columns=[%s])"
                   name rows (mapconcat #'jsonyter--org-var-quote-c colnames ", "))
         (format "%s = %s" name rows))))
    ('row (format "%s = [%s]" name (mapconcat #'jsonyter--org-var-atom-python value ", ")))
    (_ (format "%s = %s" name (jsonyter--org-var-atom-python value)))))

(defun jsonyter--org-var-value-r (name value colnames)
  "One R prelude statement binding NAME to VALUE.
A table becomes a `matrix', or with COLNAMES a `data.frame' built from
one -- base R either way, so this never depends on an extra package."
  (pcase (jsonyter--org-var-shape value)
    ('table
     (let* ((cells (apply #'append value))
            (matrix (format "matrix(c(%s), nrow = %d, byrow = TRUE)"
                            (mapconcat #'jsonyter--org-var-atom-r cells ", ")
                            (length value))))
       (if colnames
           (format "%s <- as.data.frame(%s)\ncolnames(%s) <- c(%s)"
                   name matrix name (mapconcat #'jsonyter--org-var-quote-c colnames ", "))
         (format "%s <- %s" name matrix))))
    ('row (format "%s <- c(%s)" name (mapconcat #'jsonyter--org-var-atom-r value ", ")))
    (_ (format "%s <- %s" name (jsonyter--org-var-atom-r value)))))

(defun jsonyter--org-var-value-julia (name value colnames)
  "One Julia prelude statement binding NAME to VALUE.
A table becomes a `Matrix' literal, or -- only with COLNAMES and
`jsonyter-org-var-julia-dataframe' non-nil -- a `DataFrame' built from
one; column names go through `Symbol(...)' rather than a bare `:name'
token, so an arbitrary string always reads back as a valid symbol."
  (pcase (jsonyter--org-var-shape value)
    ('table
     (let ((matrix (format "[%s]"
                           (mapconcat (lambda (row)
                                        (mapconcat #'jsonyter--org-var-atom-julia row " "))
                                      value "; "))))
       (if (and colnames jsonyter-org-var-julia-dataframe)
           (format "%s = DataFrame(%s, [%s])"
                   name matrix
                   (mapconcat (lambda (c) (format "Symbol(%s)" (jsonyter--org-var-quote-c c)))
                             colnames ", "))
         (format "%s = %s" name matrix))))
    ('row (format "%s = [%s]" name (mapconcat #'jsonyter--org-var-atom-julia value ", ")))
    (_ (format "%s = %s" name (jsonyter--org-var-atom-julia value)))))

(defun jsonyter--org-var-value-sas (name value)
  "One SAS prelude statement binding NAME to VALUE.
A scalar becomes a `%let'.  A table becomes a `DATALINES' step when every
cell is safe to space-delimit -- an all-numeric table, in practice --
and a clear `user-error' otherwise: SAS has no expression-level literal
for a dataset, and guessing at a delimiter for a character field that
might contain whitespace risks silently corrupting the very data the
block asked for, which is worse than refusing outright."
  (pcase (jsonyter--org-var-shape value)
    ('table
     (when (seq-some (lambda (row)
                       (seq-some (lambda (cell) (and (stringp cell) (string-match-p "[ \t]" cell)))
                                 row))
                     value)
       (user-error
        "jsonyter: `:var %s' is a SAS table with a character field containing whitespace — unsupported, since DATALINES cannot delimit it safely; pass scalars instead, or read the data from the kernel's filesystem"
        name))
     (let* ((ncol (length (car value)))
            (types (mapcar (lambda (i) (if (numberp (nth i (car value))) 'numeric 'character))
                           (number-sequence 0 (1- ncol)))))
       (format "data %s;\n  input %s;\n  datalines;\n%s\n;\nrun;"
               name
               (mapconcat (lambda (i) (format "col%d%s" (1+ i)
                                              (if (eq (nth i types) 'character) " $" "")))
                          (number-sequence 0 (1- ncol)) " ")
               (mapconcat (lambda (row) (mapconcat (lambda (c) (format "%s" c)) row " "))
                          value "\n"))))
    ('row (format "%%let %s = %s;" name (mapconcat (lambda (c) (format "%s" c)) value " ")))
    (_ (format "%%let %s = %s;" name value))))

(defun jsonyter--org-var-code (lang body params)
  "BODY prefixed with a marshalling prelude for every `:var' in PARAMS.
One prelude statement per binding, in LANG, ahead of BODY; PARAMS with no
`:var' at all returns BODY unchanged.  See the `jsonyter--org-var-value-*'
family for the per-language rules, and `jsonyter-org-var-size-limit' for
the guard against an oversized one."
  (let ((colname-names (cdr (assq :colname-names params)))
        lines)
    (dolist (entry params)
      (when (eq (car entry) :var)
        (let* ((binding (cdr entry))
               (name (symbol-name (car binding)))
               (value (cdr binding))
               (colnames (and colname-names (eq (car colname-names) (car binding))
                              (cdr colname-names))))
          (jsonyter--org-var-check-size name value)
          (push (pcase lang
                  ("python" (jsonyter--org-var-value-python name value colnames))
                  ("R" (jsonyter--org-var-value-r name value colnames))
                  ("julia" (jsonyter--org-var-value-julia name value colnames))
                  ("SAS" (jsonyter--org-var-value-sas name value))
                  (_ (user-error "jsonyter: no `:var' marshalling for language %s" lang)))
                lines))))
    (if lines (concat (mapconcat #'identity (nreverse lines) "\n") "\n" body) body)))

(provide 'jsonyter-babel)
;;; jsonyter-babel.el ends here
