;;; jsonyter-complete.el --- Kernel-backed completion, call hints and help -*- lexical-binding: t; -*-

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

;; Kernel-backed completion, documentation lookup and call hints, shared
;; by every surface that has code and a kernel: REPLs, notebook code
;; cells, `# %%' script cells and Org `jy:' blocks.  One part of
;; jsonyter.el, which loads every part; see jsonyter.el for the overview
;; and the entry points.
;;
;; What differs between the surfaces is only where "the code at point"
;; is, so each one registers a context function (see
;; `jsonyter--code-context-function') and everything here asks it.  A
;; context is a plist:
;;
;;   :code     the code the kernel should see, as a string
;;   :pos      point's offset into :code
;;   :start    the buffer position of :code's first character
;;   :session  the `jsonyter--session' that runs it
;;   :patient  non-nil where a keypress asked for the completion on
;;             purpose (a REPL's TAB), so the long request timeout is
;;             fine; nil where an idle-triggered UI may be asking
;;
;; Nothing here ever starts a kernel, and nothing waits on a busy one.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ansi-color)
(require 'jsonyter-core)

(declare-function jsonyter--org-session-at-point "jsonyter-org")
(declare-function jsonyter--mime "jsonyter-repl" (data key))

;;;; Options

(defcustom jsonyter-completion-timeout 2
  "Seconds to wait for the kernel's answer to a completion, away from the REPL.
In a notebook, a script or an Org block, completion can be triggered by
an idle timer (company, corfu), not only by a deliberate TAB, and a kernel
that is slow or far away would freeze typing for as long as
`jsonyter-request-timeout' allows.  This is the shorter limit used there;
when it is exceeded the completion gives up quietly, and the kernel is
not asked again for `jsonyter-completion-backoff' seconds.  A REPL always
uses `jsonyter-request-timeout', since TAB is pressed on purpose there."
  :type 'number
  :group 'jsonyter)

(defcustom jsonyter-completion-backoff 10
  "Seconds without kernel completion after one gave up (see above).
Applies away from the REPL only, to the buffer that timed out."
  :type 'number
  :group 'jsonyter)

(defcustom jsonyter-completion-position 'first
  "Where kernel completion goes among `completion-at-point-functions'.
The kernel knows the live session -- the columns of a data frame, an
object created a moment ago, packages installed on a remote kernel --
which a language server or the language mode cannot.  Whichever is
first is asked first, and when it has nothing to offer the next one is
tried, so either order falls back to the other.

`first'  Kernel completion before the language's own (default).
`last'   After it: the kernel only completes what the language's own
         completion has nothing for.

Takes effect in buffers where the mode is turned on afterwards."
  :type '(choice (const :tag "Before the language's own completion" first)
                 (const :tag "After it, as a fallback" last))
  :group 'jsonyter)

(defcustom jsonyter-completion-arguments-first t
  "Whether to put argument names first when completing inside a call.
Right after the `(' or a `,' of a call, such as `rnorm(', the kernel's
matches include the function's argument names mixed in with every
global name.  With this on, the arguments come first in the candidate
list (the others are still there: typing a prefix reaches them), as in
RStudio.  `jsonyter-completion-argument-regexps' says which candidates
are arguments."
  :type 'boolean
  :group 'jsonyter)

(defcustom jsonyter-completion-argument-regexps
  '((t . "[[:space:]]*=[[:space:]]*\\'"))
  "How to tell a call's argument names from other completion candidates.
An alist of (LANGUAGE . REGEXP).  LANGUAGE is a kernel language such as
\"python\" or \"r\" (compared without regard to case), and t gives the
default.  A candidate is an argument when it matches REGEXP; the default
says it ends in `=' (Python and Julia kernels complete `sep=', R kernels
complete `sep = ')."
  :type '(alist :key-type (choice string (const t)) :value-type regexp)
  :group 'jsonyter)

(defcustom jsonyter-help-shorthand t
  "Whether a REPL answers `?name' from the kernel's documentation.
When the input is just `?NAME' or `??NAME' (and, for Python,
`NAME?' or `NAME??'), it is not run: the kernel is asked for
NAME's documentation (more detail for the doubled form) and the answer
is shown in the `*jsonyter-doc*' window, as `C-c C-d' does.  When the
kernel has nothing for NAME, the input is sent unchanged, so nothing is
lost.  A REPL's execution count does not move.

t        in every REPL (default)
a list   only in REPLs of those languages, e.g. (\"r\" \"python\")
nil      never: the kernel sees every input as typed"
  :type '(choice (const :tag "Always" t)
                 (const :tag "Never" nil)
                 (repeat :tag "Only these languages" string))
  :group 'jsonyter)

(defcustom jsonyter-eldoc nil
  "Whether to show a call's signature in the echo area while inside it.
When non-nil (and Emacs has `eldoc-documentation-functions', that is
Emacs 28 or later), the kernel is asked for the documentation of the
function whose argument list point is in, and the first line of its
answer -- the signature -- is shown by Eldoc.  Off by default because
each new function name is one round trip to the kernel.

Takes effect in buffers where the mode is turned on afterwards."
  :type 'boolean
  :group 'jsonyter)

;;;; Where the code at point is

(defvar-local jsonyter--code-context-function nil
  "Function returning the code context at point, or nil if there is none.
See the Commentary of jsonyter-complete.el for what the context holds.
Set by the REPL, notebook, script and Org modes.")

(defun jsonyter--code-context ()
  "The code context at point (see `jsonyter--code-context-function'), or nil."
  (and jsonyter--code-context-function
       (funcall jsonyter--code-context-function)))

(defun jsonyter--completion-enable (context-function)
  "Turn on kernel completion, call hints and help in this buffer.
CONTEXT-FUNCTION finds the code at point; see
`jsonyter--code-context-function'."
  (setq-local jsonyter--code-context-function context-function)
  (add-hook 'completion-at-point-functions #'jsonyter-completion-at-point
            (eq jsonyter-completion-position 'last) t)
  (when (and jsonyter-eldoc (boundp 'eldoc-documentation-functions))
    (add-hook 'eldoc-documentation-functions #'jsonyter-eldoc-function nil t)))

(defun jsonyter--completion-disable ()
  "Undo `jsonyter--completion-enable' in this buffer."
  (kill-local-variable 'jsonyter--code-context-function)
  (remove-hook 'completion-at-point-functions #'jsonyter-completion-at-point t)
  (when (boundp 'eldoc-documentation-functions)
    (remove-hook 'eldoc-documentation-functions #'jsonyter-eldoc-function t)))

;;;; Reading calls out of code

(defun jsonyter--call-scan (code offset)
  "Scan CODE up to OFFSET; return the position of the innermost open bracket.
The result is (CHAR . POSITION), or nil when no bracket is open at OFFSET.
Brackets inside a string (single, double or backtick quoted, with
backslash escapes) or a `#' comment are ignored.  POSITION is an offset
into CODE."
  (let ((stack nil) (i 0) (quote-char nil)
        (limit (min offset (length code))))
    (while (< i limit)
      (let ((c (aref code i)))
        (cond
         (quote-char
          (cond ((eq c ?\\) (cl-incf i))
                ((eq c quote-char) (setq quote-char nil))))
         ((memq c '(?\" ?' ?`)) (setq quote-char c))
         ((eq c ?#)
          (while (and (< i limit) (not (eq (aref code i) ?\n)))
            (cl-incf i)))
         ((memq c '(?\( ?\[ ?\{)) (push (cons c i) stack))
         ((memq c '(?\) ?\] ?\})) (pop stack))))
      (cl-incf i))
    (car stack)))

(defun jsonyter--call-open-paren (code offset)
  "The offset of the `(' of the call OFFSET is inside in CODE, or nil.
That is the innermost open bracket when it is a parenthesis that follows
something that can be called: a name, or the end of another call or
subscript.  A grouping parenthesis, as in `(a + b', is not a call."
  (let ((open (jsonyter--call-scan code offset)))
    (when (and open (eq (car open) ?\())
      (let ((before (string-trim-right (substring code 0 (cdr open)))))
        (when (and (> (length before) 0)
                   (string-match-p "[][:alnum:]_.)]\\'" before))
          (cdr open))))))

(defun jsonyter--completing-argument-p (code start)
  "Non-nil if the completion beginning at offset START of CODE names an argument.
That is, it follows the `(' or a `,' of a call, with only whitespace between."
  (and (jsonyter--call-open-paren code start)
       (string-match-p "[(,][[:space:]\n]*\\'" (substring code 0 start))))

(defun jsonyter--argument-regexp (language)
  "The regexp for LANGUAGE's argument candidates; see the option."
  (let ((language (and language (downcase language))))
    (or (cdr (cl-find-if (lambda (entry)
                           (and (stringp (car entry))
                                (string= (downcase (car entry)) (or language ""))))
                         jsonyter-completion-argument-regexps))
        (cdr (assq t jsonyter-completion-argument-regexps)))))

;;;; Asking the kernel

(defvar-local jsonyter--completion-backoff-until nil
  "`float-time' before which kernel completion stays quiet in this buffer.")

(defun jsonyter--completion-ready-p (context)
  "Non-nil if the kernel behind CONTEXT can be asked right now.
It must exist, be idle, and not have just failed to answer in time."
  (let ((session (plist-get context :session)))
    (and session
         (jsonyter--live-p session)
         (not (jsonyter--busy-p session))
         (or (plist-get context :patient)
             (null jsonyter--completion-backoff-until)
             (>= (float-time) jsonyter--completion-backoff-until)))))

(defun jsonyter--completion-request (context method &rest extra)
  "Send kernel METHOD for CONTEXT's code and point, plus EXTRA parameters.
Returns the reply, or nil when the request failed.  Outside a REPL a
failure -- in practice a timeout -- also silences completion for
`jsonyter-completion-backoff' seconds."
  (let* ((session (plist-get context :session))
         (params (append (list :kernel_id (jsonyter--session-kernel-id session)
                               :code (plist-get context :code)
                               :cursor_pos (plist-get context :pos))
                         extra)))
    (if (plist-get context :patient)
        (ignore-errors (jsonyter--kernel-request method params))
      (condition-case nil
          (prog1 (jsonyter--request-sync
                  method
                  (append params (list :timeout jsonyter-completion-timeout))
                  (+ jsonyter-completion-timeout 1))
            (setq jsonyter--completion-backoff-until nil))
        (error
         (setq jsonyter--completion-backoff-until
               (+ (float-time) jsonyter-completion-backoff))
         nil)))))

;;;; Completion

(defun jsonyter--completion-types (reply)
  "A hash table of the kernel's type information in REPLY, by candidate, or nil.
The kernel gives each match a `type' and a `signature' in the reply's
`_jupyter_types_experimental' metadata, when it supports that."
  (let ((entries (plist-get (plist-get reply :metadata)
                            :_jupyter_types_experimental)))
    (when (and (consp entries) (consp (car entries)))
      (let ((table (make-hash-table :test #'equal)))
        (dolist (entry entries)
          (when (and (listp entry) (stringp (plist-get entry :text)))
            (puthash (plist-get entry :text) entry table)))
        (and (> (hash-table-count table) 0) table)))))

(defun jsonyter--completion-table (matches sort)
  "A completion table over MATCHES that offers candidates in SORT's order.
SORT is a function from a list of candidates to the list as it should be
shown.  The table is otherwise the list itself."
  (lambda (string pred action)
    (if (eq action 'metadata)
        `(metadata (display-sort-function . ,sort)
                   (cycle-sort-function . ,sort))
      (complete-with-action action matches string pred))))

(defun jsonyter--completion-result (context reply matches)
  "The `completion-at-point' result for REPLY's MATCHES in CONTEXT."
  (let* ((code (plist-get context :code))
         (pos (plist-get context :pos))
         (begin (or (plist-get reply :cursor_start) pos))
         (end (or (plist-get reply :cursor_end) pos))
         (start (plist-get context :start))
         (types (jsonyter--completion-types reply))
         (language (jsonyter--session-language (plist-get context :session)))
         (regexp (jsonyter--argument-regexp language))
         (arguments (and jsonyter-completion-arguments-first
                         regexp
                         (jsonyter--completing-argument-p code begin)
                         (cl-remove-if-not
                          (lambda (m) (string-match-p regexp m)) matches)))
         (table (if (and arguments (< (length arguments) (length matches)))
                    (jsonyter--completion-table
                     matches
                     (lambda (candidates)
                       (append (seq-filter (lambda (c) (member c arguments))
                                           candidates)
                               (seq-remove (lambda (c) (member c arguments))
                                           candidates))))
                  matches)))
    (append
     (list (+ start begin) (+ start end) table)
     ;; Step aside, for the language's own completion, when none of this
     ;; fits what is being typed.
     (list :exclusive 'no)
     (when types
       (list :annotation-function
             (lambda (candidate)
               (let ((type (plist-get (gethash candidate types) :type)))
                 (and (stringp type) (concat " " type))))
             :company-docsig
             (lambda (candidate)
               (let ((signature (plist-get (gethash candidate types) :signature)))
                 (and (stringp signature) signature))))))))

(defun jsonyter-completion-at-point ()
  "Kernel-backed `completion-at-point' function.
Works in a REPL, a notebook code cell, a `# %%' script cell and an Org
`jy:' block; anywhere else, and whenever the kernel is not running, is
busy, or does not answer in `jsonyter-completion-timeout', it returns nil
so the next function on `completion-at-point-functions' gets its turn.
It never starts a kernel.

Inside a call, right after the `(' or a `,', the call's argument names
come first (see `jsonyter-completion-arguments-first'), and candidates
carry the kernel's `type' as an annotation when it sends one."
  (let ((context (jsonyter--code-context)))
    (when (and context (jsonyter--completion-ready-p context))
      (let ((reply (jsonyter--completion-request context "complete")))
        (when (and reply (equal (plist-get reply :status) "ok"))
          (let ((matches (plist-get reply :matches)))
            (when matches
              (jsonyter--completion-result context reply matches))))))))

;;;; Documentation

(defun jsonyter--show-doc (text)
  "Show kernel documentation TEXT in the `*jsonyter-doc*' help window."
  (with-help-window "*jsonyter-doc*"
    (with-current-buffer standard-output
      (insert (ansi-color-apply text)))))

(defun jsonyter--inspect-text (session code pos &optional detail)
  "The kernel's documentation for the thing at POS in CODE, or nil.
SESSION is the session to ask.  DETAIL, 0 or 1, is the kernel's
`detail_level' (1 asks for more, as `??' does in IPython)."
  (let* ((reply (jsonyter--kernel-request
                 "inspect"
                 (append (list :kernel_id (jsonyter--session-kernel-id session)
                               :code code
                               :cursor_pos (max 0 (min (length code) pos)))
                         (and detail (list :detail_level detail))))))
    (and (eq (plist-get reply :found) t)
         (jsonyter--mime (plist-get reply :data) :text/plain))))

;;;###autoload
(defun jsonyter-inspect (&optional detailed)
  "Show the kernel's documentation for the thing at point.
Works in a REPL, a notebook code cell, a `# %%' script cell and an Org
`jy:' block.  With a prefix argument DETAILED, asks for more detail than
usual.  The answer appears in the `*jsonyter-doc*' window."
  (interactive "P")
  (let ((context (jsonyter--code-context)))
    (unless context
      (user-error "jsonyter: point is not in code the kernel can see"))
    (let ((session (plist-get context :session)))
      (unless (jsonyter--live-p session)
        (user-error "jsonyter: this kernel is not running"))
      (when (jsonyter--busy-p session)
        (user-error "jsonyter: kernel is busy"))
      (let ((text (jsonyter--inspect-text session
                                          (plist-get context :code)
                                          (plist-get context :pos)
                                          (and detailed 1))))
        (if (not text)
            (message "jsonyter: no documentation found")
          (jsonyter--show-doc text))))))

;;;; `?name' help in a REPL

(defconst jsonyter--help-prefix-regexp
  "\\`[ \t]*\\(\\?\\??\\)[ \t]*\\([^ \t\n?()]+\\)[ \t]*\\'"
  "`?NAME' or `??NAME' as the whole of a single-line input.")

(defconst jsonyter--help-suffix-regexp
  "\\`[ \t]*\\([^ \t\n?()]+\\)\\(\\?\\??\\)[ \t]*\\'"
  "`NAME?' or `NAME??' as the whole of a single-line input.")

(defun jsonyter--help-shorthand-enabled-p (language)
  "Non-nil if `jsonyter-help-shorthand' covers a REPL of LANGUAGE."
  (cond ((eq jsonyter-help-shorthand t) t)
        ((consp jsonyter-help-shorthand)
         (and language
              (cl-some (lambda (l) (string= (downcase l) (downcase language)))
                       jsonyter-help-shorthand)
              t))))

(defun jsonyter--help-shorthand-parse (code language)
  "Parse CODE as help shorthand: (NAME . DETAIL), or nil if it is not.
DETAIL is 0 for one `?', 1 for two.  `?NAME' is recognised for every
language; the IPython form `NAME?' only for Python.  Anything else --
more than one line, a call, an expression with a `?' in it -- is not
shorthand."
  (when (and (stringp code)
             (jsonyter--help-shorthand-enabled-p language))
    (let ((line (string-trim-right code)))
      (cond
       ((string-match jsonyter--help-prefix-regexp line)
        (cons (match-string 2 line)
              (if (= (length (match-string 1 line)) 2) 1 0)))
       ((and language (string= (downcase language) "python")
             (string-match jsonyter--help-suffix-regexp line))
        (cons (match-string 1 line)
              (if (= (length (match-string 2 line)) 2) 1 0)))))))

(defun jsonyter--help-shorthand-text (session code)
  "The documentation CODE asks for as help shorthand in SESSION, or nil.
nil too when CODE is not shorthand, or the kernel has nothing for the name
or does not answer; the caller then sends CODE as typed."
  (let ((parsed (jsonyter--help-shorthand-parse
                 code (jsonyter--session-language session))))
    (when parsed
      (let ((name (car parsed)))
        (ignore-errors
          (jsonyter--inspect-text session name (length name) (cdr parsed)))))))

;;;; Call hints

(defvar-local jsonyter--eldoc-cache nil
  "(KEY . DOCUMENTATION) of the last signature looked up, to ask only once.")

(defun jsonyter--call-name (code open)
  "The name being called by the parenthesis at offset OPEN of CODE, or nil."
  (let ((before (string-trim-right (substring code 0 open))))
    (when (string-match "\\([[:alnum:]_.:$@]+\\)\\'" before)
      (match-string 1 before))))

(defun jsonyter--signature-line (text)
  "The signature line of kernel documentation TEXT, or nil.
The first line, without ANSI escapes, minus a leading `Signature:'."
  (let ((line (car (split-string (ansi-color-filter-apply text) "\n" t "[ \t]+"))))
    (and line
         (replace-regexp-in-string "\\`Signature:[ \t]*" "" line))))

(defun jsonyter-eldoc-function (callback &rest _ignored)
  "Eldoc: show the signature of the call point is in, from the kernel.
For `eldoc-documentation-functions'; see `jsonyter-eldoc'.  CALLBACK
receives the signature.  Nothing is shown when point is not inside a
call, or when the kernel is stopped, busy or slow."
  (let ((context (jsonyter--code-context)))
    (when (and context (jsonyter--completion-ready-p context))
      (let* ((code (plist-get context :code))
             (open (jsonyter--call-open-paren code (plist-get context :pos)))
             (name (and open (jsonyter--call-name code open))))
        (when name
          (let* ((session (plist-get context :session))
                 (key (list (jsonyter--session-kernel-id session) name))
                 (doc (if (equal (car jsonyter--eldoc-cache) key)
                          (cdr jsonyter--eldoc-cache)
                        (let* ((reply (jsonyter--completion-request
                                       (plist-put (copy-sequence context)
                                                  :pos (1+ open))
                                       "inspect"))
                               (text (and (eq (plist-get reply :found) t)
                                          (jsonyter--mime (plist-get reply :data)
                                                          :text/plain)))
                               (doc (and text (jsonyter--signature-line text))))
                          ;; Remember a miss too, so a name the kernel
                          ;; has nothing for is asked about once.
                          (setq jsonyter--eldoc-cache (cons key (or doc "")))
                          (or doc "")))))
            (when (and doc (not (string-empty-p doc)))
              (funcall callback doc :thing name)
              t)))))))

(provide 'jsonyter-complete)
;;; jsonyter-complete.el ends here
