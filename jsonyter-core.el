;;; jsonyter-core.el --- Sessions, versions and the bridge process -*- lexical-binding: t; -*-

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

;; Sessions, versions and the bridge process.  One part of jsonyter.el, which loads
;; every part; see jsonyter.el for the overview and the entry points.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'iso8601)
(require 'jsonyter-custom)

;; Defined in other parts of the package, which load after this one.
(declare-function jsonyter-notebook-save-buffer "jsonyter-notebook")
(declare-function jsonyter--announce "jsonyter-repl")
(defvar jsonyter-sync-max-deletes)

;;;; Buffer-local state

(defvar-local jsonyter--process nil
  "The jsonyter bridge process for this jsonyter buffer.
One bridge per buffer, however many kernels the buffer drives: the
bridge handles requests concurrently and gives each kernel its own
worker, so control messages such as `interrupt_kernel' are serviced on
this same process while an execute is still running, and a Python and an
R kernel in one Org buffer run without blocking each other.")
;; `M-x org-mode-restart' (which is also what `C-c C-c' on a
;; `#+PROPERTY:' line runs), `revert-buffer' and `normal-mode' all call
;; `kill-all-local-variables', which would otherwise wipe this process,
;; the callback table routing its replies, and the whole session table
;; out from under a live kernel: the kernel keeps running on the server,
;; orphaned, while the very next block resolves its session key against
;; an empty table and silently starts a brand-new one with none of the
;; previous blocks' state.  `permanent-local' is what `kill-all-local-variables'
;; itself already honors to keep exactly this from happening.
(put 'jsonyter--process 'permanent-local t)
(put 'jsonyter--callbacks 'permanent-local t)
(put 'jsonyter--sessions 'permanent-local t)
(put 'jsonyter--session-key 'permanent-local t)
(defvar-local jsonyter--command nil
  "The exact bridge command this buffer was started with.")
(defvar-local jsonyter--url nil
  "Server URL this buffer's bridge is talking to.
Buffer-wide: every session in the buffer shares the one server.")
(defvar-local jsonyter--callbacks nil
  "Hash table mapping request id to a handler plist (:result F :output F).
Buffer-wide and keyed by the bridge's own request ids, which are unique
across every kernel the one bridge serves.")
(defvar-local jsonyter--next-id 0)
(defvar-local jsonyter--execution-count 0
  "REPL execution counter.
A REPL is one kernel by definition, so unlike the per-session kernel
state this stays a plain buffer-local.")

;;;; The session table

;; A jsonyter buffer no longer has \"a kernel\"; it has a table of
;; sessions, each with its own kernel and its own state.  A REPL,
;; notebook or script buffer holds exactly one entry -- they are one
;; kernel by nature -- and `jsonyter--session-key' points at it, so the
;; single-kernel surfaces read as \"the current session\" and never name a
;; key.  An Org buffer holds one entry per `jy:' session in the file and
;; leaves `jsonyter--session-key' nil, addressing a session per block.
;;
;; The key is (LANGUAGE . NAME), matching org-babel's own (language,
;; name) session identity: `*Python:main*' and `*R:main*' have always
;; been distinct.  Events, the busy guard, the shutdown-on-kill rule and
;; the mode line are all per-session; only the bridge process, the
;; callback table and the server URL stay buffer-wide.

(cl-defstruct (jsonyter--session
               (:copier nil)
               (:constructor jsonyter--session-create))
  "Everything this buffer knows about one kernel."
  key                 ; (LANGUAGE . NAME), the hash key
  language            ; kernel language, e.g. "python" -- the live truth,
                      ; which an adopted cross-language kernel can move
                      ; away from the key's own car
  name                ; session name: "" (default), "main", "@KID" (adopt)
  kernel-id           ; id of the kernel this session is bound to, or nil
  kernel-name         ; its kernelspec name
  state               ; last execution_state from a subscription event
  busy                ; non-nil while an execute of ours is in flight
  own                 ; kernel-id iff this buffer started it (shutdown rule)
  last-kernel         ; plist (:id :name); outlives KERNEL-ID being cleared
  contents-dir        ; the kernel's cwd as a Contents-API path, or nil
  contents-dir-probed ; t once the probe has run, so a nil result is not
                      ; retried on every transfer command
  remote-directory    ; current directory in the remote browser, sticky
                      ; per session; seeded from CONTENTS-DIR, else ""
  transfer)           ; plist (:phase :pct :name) while a transfer of
                      ; ours runs on this session, else nil -- drives the
                      ; mode-line tag, see `jsonyter--session-status-tag'

(defvar-local jsonyter--sessions nil
  "Hash table mapping a session key (LANGUAGE . NAME) to a `jsonyter--session'.
Created on first use.  See \"The session table\" commentary above.")
(defvar-local jsonyter--session-key nil
  "Key into `jsonyter--sessions' for this buffer's sole or default session.
Set in REPL, notebook and script buffers, which drive one kernel; left
nil in Org buffers, which resolve a session per source block.")

(defun jsonyter--sessions ()
  "This buffer's session table, created empty on first use."
  (or jsonyter--sessions
      (setq jsonyter--sessions (make-hash-table :test #'equal))))

(defun jsonyter--session (&optional key)
  "The `jsonyter--session' for KEY, or this buffer's current session.
Returns nil when there is none."
  (and jsonyter--sessions
       (gethash (or key jsonyter--session-key) jsonyter--sessions)))

(defun jsonyter--session-put (key)
  "Return the session for KEY, creating an empty one if absent.
KEY is (LANGUAGE . NAME); the new session's language starts at KEY's car."
  (or (gethash key (jsonyter--sessions))
      (puthash key (jsonyter--session-create :key key :language (car key)
                                             :name (cdr key))
               jsonyter--sessions)))

(defun jsonyter--session-list ()
  "Every session in this buffer, in no particular order."
  (and jsonyter--sessions (hash-table-values jsonyter--sessions)))

(defun jsonyter--session-for-kernel (kernel-id)
  "The session in this buffer currently bound to KERNEL-ID, or nil."
  (and kernel-id jsonyter--sessions
       (catch 'hit
         (maphash (lambda (_key session)
                    (when (equal (jsonyter--session-kernel-id session) kernel-id)
                      (throw 'hit session)))
                  jsonyter--sessions)
         nil)))

(defun jsonyter--session-drop (key)
  "Forget the session for KEY."
  (when jsonyter--sessions (remhash key jsonyter--sessions)))

(defun jsonyter--session-clear (session)
  "Drop SESSION's kernel binding, keeping the session and its `last-kernel'."
  (setf (jsonyter--session-kernel-id session) nil
        (jsonyter--session-busy session) nil
        (jsonyter--session-state session) nil))

(defun jsonyter--busy-p (&optional session)
  "Non-nil if SESSION (default the current one) has an execute of ours in flight.
Safe when there is no session at all."
  (let ((session (or session (jsonyter--session))))
    (and session (jsonyter--session-busy session))))

;;;; Public accessors

;; `jsonyter--session' and friends are private.  These give a user's
;; config a stable handle on the buffer's current kernel without reaching
;; into the struct -- the supported replacement for the pre-2.0 scalars
;; `jsonyter--kernel-id' and `jsonyter--busy', which are gone.

(defun jsonyter-current-session ()
  "This buffer's current jsonyter session object, or nil.
In a REPL, notebook or script buffer that is the buffer's one kernel.
In an Org buffer it is the session of the `jy:' block at point, or nil
when point is not in one."
  (or (jsonyter--session)
      (and (derived-mode-p 'org-mode)
           (fboundp 'jsonyter--org-session-at-point)
           (jsonyter--org-session-at-point 'noerror))))

(defun jsonyter-current-kernel-id ()
  "Kernel id of `jsonyter-current-session', or nil."
  (let ((session (jsonyter-current-session)))
    (and session (jsonyter--session-kernel-id session))))

(defun jsonyter-current-session-name ()
  "Name of `jsonyter-current-session', or nil."
  (let ((session (jsonyter-current-session)))
    (and session (jsonyter--session-name session))))

(defun jsonyter-current-kernel-busy-p ()
  "Non-nil if an execute of ours is in flight on the current session."
  (let ((session (jsonyter-current-session)))
    (and session (jsonyter--session-busy session))))

(defvar jsonyter--kernel-id nil)
(defvar jsonyter--busy nil)
(defvar jsonyter--kernel-name nil)
(defvar jsonyter--kernel-state nil)
(defvar jsonyter--language nil)
(defvar jsonyter--own-kernel-id nil)
(defvar jsonyter--last-kernel nil)
(dolist (pair '((jsonyter--kernel-id . jsonyter-current-kernel-id)
                (jsonyter--busy . jsonyter-current-kernel-busy-p)
                (jsonyter--kernel-name . jsonyter-current-session)
                (jsonyter--kernel-state . jsonyter-current-session)
                (jsonyter--language . jsonyter-current-session)
                (jsonyter--own-kernel-id . jsonyter-current-session)
                (jsonyter--last-kernel . jsonyter-current-session)))
  (make-obsolete-variable (car pair) (cdr pair) "2.0.0"))
(defvar-local jsonyter--prompt-start nil "Marker at the start of the current prompt.")
(defvar-local jsonyter--input-start nil "Marker just after the current prompt.")
(defvar-local jsonyter--output-start nil "Marker at the start of the running cell's output.")
(defvar-local jsonyter--output-end nil "Marker where the next output is inserted.")
(defvar-local jsonyter--clear-pending nil
  "Non-nil after a clear_output with wait=true, until the next output.")
(defvar-local jsonyter--is-complete-failures 0
  "Consecutive `is_complete' failures in this buffer.
At `jsonyter--is-complete-give-up' we stop asking; a success resets it.")
(defvar-local jsonyter--history nil "List of previous inputs, newest first.")
(defvar-local jsonyter--history-index -1)
(defvar-local jsonyter--history-stash nil)

;;;; Version

(defmacro jsonyter--source-version ()
  "The version in the \"Version:\" header of jsonyter.el, as a string.
That header lives in jsonyter.el, the file that loads the others, so it is
read from the jsonyter.el that sits next to the file being compiled (or
loaded).  Read once, when this file is compiled (or, loaded as source,
when it is loaded), so the answer names the code that is running even if
an upgrade has since replaced the files on disk.  \"unknown\" when
jsonyter.el cannot be found while this is expanded."
  (let* ((file (or (bound-and-true-p byte-compile-current-file)
                   load-file-name
                   (buffer-file-name)))
         (main (and file
                    (expand-file-name "jsonyter.el"
                                      (file-name-directory file)))))
    (or (and main
             (file-readable-p main)
             (with-temp-buffer
               (insert-file-contents main nil 0 4096)
               (and (re-search-forward "^;; Version: *\\([0-9][^ \t\n]*\\)" nil t)
                    (match-string 1))))
        "unknown")))

(defconst jsonyter-version (jsonyter--source-version)
  "The version of jsonyter.el that is loaded, such as \"2.5.2\".
Taken from the \"Version:\" header of this file.  See `jsonyter-version'
for a report that includes the Python package.")

(defconst jsonyter--bridge-probe-code "\
import sys
sys.path[:] = [p for p in sys.path if p not in ('', '.')]
import jsonyter
try:
    version = jsonyter.__version__
except AttributeError:
    from importlib.metadata import version as _version
    version = _version('jsonyter')
print(version, sys.version.split()[0])
"
  "Python that prints the jsonyter package version and Python's own.
Run with the interpreter that launches the bridge.  The current directory
is dropped from the import path, as it is when the bridge is started from
its entry-point script.")

(defun jsonyter--script-interpreter (script)
  "The interpreter named by the first lines of SCRIPT, or nil.
Understands \"#!/path/to/python\", \"#!/usr/bin/env python3\" and the
\"/bin/sh\" form that pip writes when the interpreter's path is long or has
a space in it."
  (with-temp-buffer
    (insert-file-contents-literally script nil 0 512)
    (goto-char (point-min))
    (cond
     ((looking-at "#![ \t]*/bin/sh[ \t]*\n'''exec' +\"\\([^\"\n]+\\)\"")
      (executable-find (match-string 1)))
     ((looking-at "#![ \t]*\\(?:[^ \t\n]*/env[ \t]+\\(?:-S[ \t]+\\)?\\)?\\([^ \t\n]+\\)")
      (let ((interpreter (match-string 1)))
        ;; A shell script is a launcher, not the Python behind it.
        (unless (member (file-name-nondirectory interpreter)
                        '("sh" "bash" "dash" "zsh"))
          (executable-find interpreter)))))))

(defun jsonyter--bridge-python ()
  "The Python interpreter that runs the bridge `jsonyter-command' names.
That is its first word when the command is an interpreter (\"python3 -m
jsonyter\"), and otherwise the interpreter in the entry-point script's
first line.  nil when it cannot be told."
  (let* ((program (car jsonyter-command))
         (path (and (stringp program) (executable-find program))))
    (cond
     ((null path) nil)
     ((or (member "-m" (cdr jsonyter-command))
          (string-match-p "\\`python[0-9.]*\\(?:\\.exe\\)?\\'"
                          (file-name-nondirectory path)))
      path)
     (t (jsonyter--script-interpreter path)))))

(defvar jsonyter--bridge-probe-timeout 10
  "Seconds `jsonyter--run-probe' waits for the interpreter to answer.")

(defun jsonyter--run-probe (python)
  "Run `jsonyter--bridge-probe-code' with PYTHON; return its output or nil.
Waits at most `jsonyter--bridge-probe-timeout' seconds, so an interpreter
that hangs cannot freeze Emacs.  Standard error is mixed into the output."
  (let ((buffer (generate-new-buffer " *jsonyter version*"))
        (default-directory (file-name-as-directory temporary-file-directory)))
    (unwind-protect
        (let* ((done nil)
               (proc (make-process
                      :name "jsonyter-version"
                      :buffer buffer
                      :command (list python "-c" jsonyter--bridge-probe-code)
                      :connection-type 'pipe
                      :noquery t
                      :sentinel (lambda (process event)
                                 (ignore event)
                                 (unless (process-live-p process)
                                   (setq done t)))))
               (deadline (+ (float-time) jsonyter--bridge-probe-timeout)))
          (while (and (not done) (< (float-time) deadline))
            (accept-process-output proc 0.05))
          (if (not done)
              (progn (delete-process proc) nil)
            (string-trim (with-current-buffer buffer (buffer-string)))))
      (kill-buffer buffer))))

(defun jsonyter--bridge-info ()
  "What the jsonyter Python package that `jsonyter-command' runs says it is.
A plist with :version and :python (strings) on success, or with :error, a
sentence on why not.  Starts a short-lived Python process; the bridge
itself is not involved."
  (let ((python (jsonyter--bridge-python)))
    (if (null python)
        (list :error (format "cannot tell which Python runs %S"
                             (mapconcat #'identity jsonyter-command " ")))
      (let ((output (condition-case err
                        (jsonyter--run-probe python)
                      (error (error-message-string err)))))
        (cond
         ((null output) (list :error (format "%s did not answer" python)))
         ((string-match "\\`\\([0-9][^ \t\n]*\\) +\\([0-9][^ \t\n]*\\)\\'" output)
          (list :version (match-string 1 output) :python (match-string 2 output)))
         (t (list :error (let ((last (car (last (split-string output "\n" t)))))
                           (or last (format "%s printed nothing" python))))))))))

(defun jsonyter--server-version ()
  "The Jupyter server's version, asked through this buffer's live bridge.
nil when this buffer has no bridge running or the server does not answer."
  (when (process-live-p jsonyter--process)
    (condition-case nil
        (plist-get (jsonyter--request-sync "version" nil 5) :version)
      (error nil))))

(defun jsonyter--version-emit (text here)
  "Insert TEXT at point if HERE, otherwise show it in the echo area."
  (if here (insert text) (message "%s" text)))

;;;###autoload
(defun jsonyter-version (&optional here)
  "Report the jsonyter.el version and the jsonyter Python package under it.
Shows, for example, \"jsonyter.el v2.5.2 running on jsonyter v2.1.1\".  The
Python package is the one that `jsonyter-command' would start, found by
asking its interpreter, so this works with no REPL or notebook open.  When
that cannot be done the report says so instead of failing.

With a prefix argument HERE, insert the report at point rather than
showing it.  Returns the report as a string.  The variable
`jsonyter-version' holds just the version of jsonyter.el.  For more detail
for a bug report, see `jsonyter-version-full'."
  (interactive "P")
  (let* ((bridge (jsonyter--bridge-info))
         (text (if (plist-get bridge :version)
                   (format "jsonyter.el v%s running on jsonyter v%s"
                           jsonyter-version (plist-get bridge :version))
                 (format "jsonyter.el v%s, jsonyter bridge version unknown (%s)"
                         jsonyter-version (plist-get bridge :error)))))
    (when (called-interactively-p 'any)
      (jsonyter--version-emit text here))
    text))

;;;###autoload
(defun jsonyter-version-full (&optional here)
  "Report everything about this jsonyter install that a bug report needs.
Adds to `jsonyter-version' the file jsonyter.el was loaded from, the Python
that runs the bridge, the Jupyter server's version when this buffer has a
bridge connected to one, and Emacs's own version and system.

With a prefix argument HERE, insert the report at point rather than
showing it.  Returns the report as a string."
  (interactive "P")
  (let* ((bridge (jsonyter--bridge-info))
         (server (jsonyter--server-version))
         (loaded (or (symbol-file 'jsonyter 'provide)
                     (symbol-file 'jsonyter-version-full 'defun)))
         (text
          (concat
           (format "jsonyter.el v%s" jsonyter-version)
           (and loaded (format " (%s)" (abbreviate-file-name loaded)))
           (if (plist-get bridge :version)
               (format " running on jsonyter v%s (Python %s)"
                       (plist-get bridge :version) (plist-get bridge :python))
             (format ", jsonyter bridge version unknown (%s)"
                     (plist-get bridge :error)))
           (format ", Jupyter server %s" (or server "not connected from this buffer"))
           (format ", Emacs %s (%s)" emacs-version system-configuration))))
    (when (called-interactively-p 'any)
      (jsonyter--version-emit text here))
    text))

;;;; Token handling

(defun jsonyter--token ()
  "Return the configured server token, or nil.
Reads `jsonyter-server-token' (string or function) first, then
`jsonyter-server-token-file'.  Files ending in .gpg are decrypted by
EasyPG transparently."
  (cond
   ((functionp jsonyter-server-token)
    (funcall jsonyter-server-token))
   ((and (stringp jsonyter-server-token)
         (not (string-empty-p jsonyter-server-token)))
    jsonyter-server-token)
   (jsonyter-server-token-file
    (let ((file (expand-file-name jsonyter-server-token-file)))
      (unless (file-exists-p file)
        (error "jsonyter: token file %s does not exist" file))
      (with-temp-buffer
        (insert-file-contents file)
        (let ((token (string-trim (buffer-substring-no-properties
                                   (point-min) (point-max)))))
          (and (not (string-empty-p token)) token)))))))

;;;; Bridge process plumbing

(defun jsonyter--build-command (token)
  "Build the bridge command list, given the resolved TOKEN (or nil)."
  (append jsonyter-command
          (list "--url" jsonyter-server-url)
          (pcase jsonyter-token-transport
            ('argv (and token (list "--token" token)))
            ('stdin (and token (list "--token-file" "-")))
            ('file (and jsonyter-server-token-file
                        (list "--token-file"
                              (expand-file-name jsonyter-server-token-file))))
            (_ nil))                    ; env: nothing on the command line
          (and jsonyter-exec-timeout
               (list "--exec-timeout"
                     (number-to-string jsonyter-exec-timeout)))
          (and jsonyter-insecure-tls '("--insecure"))))

(defun jsonyter--start-bridge ()
  "Start the bridge process for the current REPL buffer.
Returns the process.  Sets `jsonyter--command' as a side effect so the
buffer records exactly how it was launched."
  (let* ((transport jsonyter-token-transport)
         (token (if (eq transport 'file) nil (jsonyter--token))))
    (when (and (eq transport 'file)
               jsonyter-server-token-file
               (string-suffix-p ".gpg" jsonyter-server-token-file))
      (user-error
       "jsonyter: token transport `file' cannot read the encrypted %s; use `env' or `stdin'"
       jsonyter-server-token-file))
    (setq jsonyter--command (jsonyter--build-command token))
    (let* ((stderr-buffer (generate-new-buffer " *jsonyter stderr*"))
           (process-environment
            (if (and token (eq transport 'env))
                (cons (concat "JUPYTER_TOKEN=" token) process-environment)
              process-environment))
           (proc (condition-case nil
                     (make-process
                      :name "jsonyter"
                      :command jsonyter--command
                      :connection-type 'pipe
                      :noquery t
                      :coding 'utf-8-unix
                      :stderr stderr-buffer
                      :filter #'jsonyter--filter
                      :sentinel #'jsonyter--sentinel)
                   ;; `make-process' signals this synchronously, before
                   ;; any process exists, when the executable itself
                   ;; can't be found on PATH — the state a fresh install
                   ;; with no Python package yet is in by default, since
                   ;; `jsonyter-command' defaults to the bare console
                   ;; script name. Emacs's own message for this ("Searching
                   ;; for program: No such file or directory, jsonyter")
                   ;; never says what jsonyter actually is, so replace it.
                   (file-missing
                    (kill-buffer stderr-buffer)
                    (user-error
                     "jsonyter: bridge command %S not found on PATH — install the jsonyter Python package (`pip install jsonyter`), or set `jsonyter-command' to the interpreter that has it, e.g. '(\"python3\" \"-m\" \"jsonyter\")"
                     (car jsonyter--command))))))
      (let ((stderr-proc (get-buffer-process stderr-buffer)))
        (when stderr-proc
          (set-process-query-on-exit-flag stderr-proc nil)))
      (process-put proc 'jsonyter-repl-buffer (current-buffer))
      (process-put proc 'jsonyter-stderr-buffer stderr-buffer)
      (process-put proc 'jsonyter-pending "")
      ;; With `stdin' transport the bridge reads the token from the very
      ;; first line, before it starts reading requests.
      (when (and token (eq transport 'stdin))
        (process-send-string proc (concat token "\n")))
      proc)))

(defun jsonyter--filter (proc chunk)
  "Accumulate CHUNK from PROC and dispatch complete JSON lines."
  (let ((buf (process-get proc 'jsonyter-repl-buffer))
        (pending (concat (process-get proc 'jsonyter-pending) chunk)))
    (while (string-match "\n" pending)
      (let ((line (substring pending 0 (match-beginning 0))))
        (setq pending (substring pending (match-end 0)))
        (when (and (not (string-blank-p line)) (buffer-live-p buf))
          (with-current-buffer buf
            (jsonyter--dispatch proc line)))))
    (process-put proc 'jsonyter-pending pending)))

(defun jsonyter--dispatch (proc line)
  "Handle one JSON LINE from bridge PROC.  Current buffer is the REPL.
Every line is a JSON object; which key is present says what it is:
`result'/`error' complete a request, while `output', `input_request',
`progress' and `event' are out-of-band and leave the request pending."
  (let ((msg (condition-case err
                 (json-parse-string line
                                    :object-type 'plist
                                    :array-type 'list
                                    :null-object nil
                                    :false-object nil)
               (error
                (jsonyter--announce (format "[unparseable bridge output: %s]"
                                        (error-message-string err)))
                nil))))
    (when msg
      (let* ((id (plist-get msg :id))
             (handlers (and id (gethash id jsonyter--callbacks))))
        (cond
         ;; Async kernel state; carries no request id.
         ((plist-member msg :event)
          (jsonyter--handle-event msg))
         ;; Incremental output from a running execute.
         ((plist-member msg :output)
          (let ((handler (plist-get handlers :output)))
            (when handler (funcall handler (plist-get msg :output)))))
         ;; Progress from a running upload/download.  Out-of-band like
         ;; `output': the request stays pending until its `result'.
         ((plist-member msg :progress)
          (let ((handler (plist-get handlers :progress)))
            (when handler (funcall handler (plist-get msg :progress)))))
         ;; The kernel wants stdin.
         ((plist-member msg :input_request)
          (jsonyter--answer-input proc id (plist-get msg :input_request)))
         ;; Final reply: result or error.
         (t
          (when id (remhash id jsonyter--callbacks))
          (let ((handler (plist-get handlers :result)))
            (cond
             (handler (funcall handler msg))
             ((plist-get msg :error)
              (jsonyter--announce
               (format "[bridge error: %s]"
                       (jsonyter--error-message (plist-get msg :error)))))))))))))

(defun jsonyter--answer-input (proc id content)
  "Prompt for stdin requested by request ID and reply on PROC."
  (let* ((prompt (or (plist-get content :prompt) ""))
         (answer (condition-case nil
                     (if (eq (plist-get content :password) t)
                         (read-passwd prompt)
                       (read-string prompt))
                   (quit ""))))
    (process-send-string
     proc (concat (json-serialize (list :id id :input answer)) "\n"))))

(defun jsonyter--handle-event (msg)
  "Handle an async kernel event line MSG from the bridge.

The bridge tags every event with the `kernel_id' it belongs to, so the
event is routed to the session that owns that kernel and touches nothing
else.  With two kernels in one buffer this is what keeps a `dead' event
from the R kernel from blanking the Python kernel's state or clearing a
busy flag that belongs to a cell still running.  An event for a kernel
this buffer no longer tracks -- a race with disconnect or shutdown -- has
nowhere to land and is dropped."
  (let* ((session (jsonyter--session-for-kernel (plist-get msg :kernel_id)))
         (event (plist-get msg :event))
         (type (plist-get event :type)))
    (when session
      (pcase type
        ("status"
         ;; A kernel shutting down reports `idle' on its way out, after the
         ;; shutdown_reply that told us it is gone — so once dead, stay dead
         ;; until a restart resubscribes.  A dropped socket is different: it
         ;; can come back on its own, and a status event is the proof.
         ;; Current bridges suppress that trailing status themselves, which
         ;; makes this a no-op there; it stays for older ones.
         (unless (equal (jsonyter--session-state session) "dead")
           (setf (jsonyter--session-state session)
                 (plist-get event :execution_state))))
        ("dead"
         (cond
          ((eq (plist-get event :restart) t)
           (setf (jsonyter--session-state session) "restarting")
           (jsonyter--announce "[kernel is restarting]" session))
          (t
           (setf (jsonyter--session-state session) "dead"
                 (jsonyter--session-busy session) nil)
           (jsonyter--announce "[kernel died — C-c C-r to restart]" session))))
        ("disconnected"
         (setf (jsonyter--session-state session) "disconnected")
         (jsonyter--announce (format "[kernel connection lost: %s]"
                                     (or (plist-get event :message) "unknown"))
                             session))
        (_ nil))
      (force-mode-line-update))))

(defun jsonyter--sentinel (proc event)
  "Note bridge PROC exiting (EVENT) in its buffer.
The one bridge serves every session, so its death takes them all down."
  (let ((buf (process-get proc 'jsonyter-repl-buffer)))
    (when (and (buffer-live-p buf) (not (process-live-p proc)))
      (with-current-buffer buf
        (when (eq proc jsonyter--process)
          (dolist (session (jsonyter--session-list))
            (setf (jsonyter--session-busy session) nil
                  (jsonyter--session-state session) "dead"
                  ;; A transfer in flight has no reply coming now; drop its
                  ;; mode-line tag so it does not mask `:dead' forever.
                  (jsonyter--session-transfer session) nil))
          (jsonyter--announce (format "\n[jsonyter bridge exited: %s]"
                                  (string-trim event)))
          (force-mode-line-update))))))

(defun jsonyter--send (method params &optional handlers)
  "Send METHOD with PARAMS on this buffer's bridge.
HANDLERS is a plist: :result is called with the final reply plist,
:output with each incremental output, :progress with each transfer
progress plist from a running `upload'/`download'.  Returns the request
id."
  (unless (process-live-p jsonyter--process)
    (error "jsonyter: bridge process is not running (M-x jsonyter-kernel-reconnect)"))
  ;; Every mode that talks to a kernel sets this up, but a buffer can
  ;; reach here without one — e.g. a notebook whose render failed, or a
  ;; caller driving the bridge directly — and a missing table would fail
  ;; far from the cause.
  (unless jsonyter--callbacks
    (setq-local jsonyter--callbacks (make-hash-table :test #'eql)))
  (let* ((id (cl-incf jsonyter--next-id))
         (request (if params
                      (list :id id :method method :params params)
                    (list :id id :method method))))
    (puthash id (or handlers '(:result ignore)) jsonyter--callbacks)
    (process-send-string jsonyter--process
                         (concat (json-serialize request) "\n"))
    id))

(defun jsonyter--error-message (err)
  "Format bridge ERR (an `:error' plist) as a user-facing string.

Appends a pointed hint for authentication failures (HTTP 401/403),
which the Jupyter server and the bridge otherwise report as a bare
\"Unauthorized\" or \"Forbidden\" with no indication of what actually
fixes it — confirmed empirically: an unauthenticated request against a
token-protected server returns exactly \"Forbidden\" and nothing else.

The same shape covers the structured errors a file transfer raises: a
`reason' key (a `TransferConflict') drives the recovery hint, and a
`cf_ray' key on a body-size failure names `jsonyter-upload-chunk-size'
rather than the bridge's own `--chunk-size', since a bare \"Request
Entity Too Large\" says nothing about which knob fixes it.

It also covers `SyncRefused' (a refused `sync_plan'/`sync_apply' from
`jsonyter-sync' and friends): `reason' again drives the recovery hint,
this time naming the elisp-side defcustom or command that fixes it.

It also covers `ExportError' (a failed `export_notebook'): `hint' is an
actionable toolchain fix when the bridge knows one -- `pdf' failing with
a bare \"Pandoc wasn't found\" is the single most likely first-run
failure, and the hint says exactly what to install *on the Jupyter
server*, a distinction users reliably get wrong since nbconvert runs
there, not in the bridge or in Emacs.  `available_formats' is populated
only for \"unknown export format\"."
  (let ((message (or (plist-get err :message) (format "%s" err)))
        (status (plist-get err :status))
        (reason (plist-get err :reason))
        (cf-ray (plist-get err :cf_ray))
        (hint (plist-get err :hint))
        (available (plist-get err :available_formats)))
    (cond
     ((memq status '(401 403))
      (format "%s (set `jsonyter-server-token' or `jsonyter-server-token-file' if %s requires a token)"
              message (or (plist-get err :url) "the server")))
     ;; A gateway refused the request itself — a 413 (body too large) or a
     ;; proxy 5xx — carrying cf-ray: not the Jupyter server talking, and a
     ;; different knob fixes it.  Same shape as the 401/403 case: key on
     ;; `status', not on words in the message, since the bridge injects
     ;; \"lower --chunk-size\" into *every* upload failure it re-raises —
     ;; an origin 404 for a missing directory would otherwise match too.
     ((and cf-ray (memq status '(413 429 502 503 504 520 521 522 523 524 525 526 530)))
      (format "%s [set `jsonyter-upload-chunk-size' below its current %s, then M-x jsonyter-resume-upload]"
              message
              (file-size-human-readable jsonyter-upload-chunk-size nil " " "B")))
     ;; A `TransferConflict': `reason' says which recovery to offer.
     ((equal reason "exists")
      (format "%s [pass a prefix argument (C-u) to the command to overwrite]" message))
     ((equal reason "stale")
      (let ((mine (plist-get err :expected_hash))
            (theirs (plist-get err :actual_hash)))
        (format "%s%s [download the server's copy first (M-x jsonyter-download-file), or C-u to overwrite]"
                message
                (if (and (stringp mine) (stringp theirs))
                    (format " (yours %s, server %s)"
                            (substring mine 0 (min 4 (length mine)))
                            (substring theirs 0 (min 4 (length theirs))))
                  ""))))
     ((equal reason "corrupt")
      (format "%s [retry, or M-x jsonyter-resume-upload / M-x jsonyter-resume-download]" message))
     ;; A `SyncRefused' from `jsonyter-sync' and friends: `reason' again
     ;; drives the recovery, this time naming the elisp-side knob rather
     ;; than the Python kwarg the bridge's own message names.
     ((equal reason "too-many-deletes")
      (format "%s [set `jsonyter-sync-max-deletes' above its current %s and re-run, once you've confirmed the count is really intended]"
              message (or (plist-get err :max_deletes) jsonyter-sync-max-deletes)))
     ((equal reason "locked")
      (format "%s [M-x jsonyter-sync-abort to stop it, or wait for it to finish]" message))
     ((equal reason "too-many-files")
      (format "%s [check that this is the directory you meant to sync]" message))
     ((equal reason "algorithm-mismatch")
      (format "%s [the server changed its hash algorithm mid-sync -- retry]" message))
     ((or hint available)
      (concat message
              (and hint (format " [%s]" hint))
              (and available
                   (format " (available: %s)"
                           (mapconcat #'identity (append available nil) ", ")))))
     (t message))))

(defun jsonyter--stderr-tail (proc &optional max-lines)
  "Last MAX-LINES (default 6) non-blank lines of PROC's bridge stderr.
Tails rather than heads: a Python traceback's most diagnostic line —
the exception itself — is always last, and anything earlier tends to be
import-time warning noise (this project's own dependencies produce
some on certain Python builds).  Returns nil if there is nothing
useful to show."
  (let ((buf (process-get proc 'jsonyter-stderr-buffer)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let* ((lines (split-string (buffer-string) "\n" t "[ \t]+"))
               (tail (last lines (or max-lines 6))))
          (and tail (mapconcat #'identity tail "\n")))))))

(defun jsonyter--request-sync (method params &optional timeout)
  "Send METHOD/PARAMS and wait for the reply, returning its :result.
Signals an error on a bridge error or timeout.  TIMEOUT defaults to
`jsonyter-request-timeout'.  Other traffic (streamed output, events,
replies to other requests) is dispatched normally while waiting."
  (let* ((proc jsonyter--process)
         (reply 'jsonyter--waiting)
         (id (jsonyter--send method params
                             (list :result (lambda (msg) (setq reply msg)))))
         (deadline (+ (float-time) (or timeout jsonyter-request-timeout))))
    (while (and (eq reply 'jsonyter--waiting)
                (process-live-p proc)
                (< (float-time) deadline))
      (accept-process-output proc 0.05))
    (when (eq reply 'jsonyter--waiting)
      (remhash id jsonyter--callbacks)
      (error "jsonyter: no reply to %s within %ss%s" method
             (or timeout jsonyter-request-timeout)
             (cond
              ((process-live-p proc) "")
              ;; The bridge died before answering even its first
              ;; request — e.g. the jsonyter Python package isn't
              ;; installed for whatever interpreter `jsonyter-command'
              ;; names. Python's own complaint about that is sitting
              ;; right there in stderr; show it rather than the
              ;; uninformative "died" this used to say on its own,
              ;; since it usually names the actual fix directly (most
              ;; commonly "No module named jsonyter").
              ((jsonyter--stderr-tail proc)
               (format " (bridge process died — %s)"
                      (jsonyter--stderr-tail proc)))
              (t " (bridge process died)"))))
    (let ((err (plist-get reply :error)))
      (when err
        (error "jsonyter: %s" (jsonyter--error-message err))))
    (plist-get reply :result)))

(defun jsonyter--kernel-request (method params)
  "Send short kernel METHOD with PARAMS, bounded on *both* sides.

The bridge serializes requests per kernel, so a kernel that never answers
a given message type can block that kernel's worker and queue every later
execute behind it — the REPL looking hung with the kernel stuck \"busy\".
Not hypothetical: the SAS kernel never answers `history' at all, and
answers `inspect' with `aborted'.

Current jsonyter bridges defend against this themselves, bounding the
introspection calls with their own `control_timeout' (30s) rather than
waiting forever.  We still send an explicit per-call `timeout' anyway:
it works the same on older bridges that lack that default, it keeps the
bound at an interactive latency rather than 30s, and it means
`jsonyter-request-timeout' is one knob that actually takes effect.

Emacs waits a little longer than the bridge so the bridge always wins
the race, and we get a real error back rather than abandoning a request
that is still live on the other side."
  (jsonyter--request-sync
   method
   (append params (list :timeout jsonyter-request-timeout))
   (+ jsonyter-request-timeout 5)))

(defun jsonyter--live-p (&optional session)
  "Non-nil if SESSION (default the current one) has a kernel and a live bridge."
  (let ((session (or session (jsonyter--session))))
    (and session
         (jsonyter--session-kernel-id session)
         (process-live-p jsonyter--process))))

;;;; Kernel spec resolution

(defun jsonyter--resolve-kernel-name (language)
  "Return the kernel spec name to use for LANGUAGE.
Honors `jsonyter-kernel-names', otherwise queries the server's
kernelspecs and matches on declared language, preferring the server
default."
  (or (cdr (assoc-string language jsonyter-kernel-names t))
      (let* ((specs (jsonyter--request-sync "list_kernelspecs" nil))
             (table (plist-get specs :kernelspecs))
             (default (plist-get specs :default))
             (matches '()))
        (cl-loop for (_key spec) on table by #'cddr
                 for name = (plist-get spec :name)
                 for lang = (plist-get (plist-get spec :spec) :language)
                 when (and name lang
                           (string-equal (downcase lang) (downcase language)))
                 do (push name matches))
        (cond
         ((member default matches) default)
         (matches (car (last matches)))
         (t (error "jsonyter: no kernel for language %S on %s (available: %s)"
                   language jsonyter-server-url
                   (let (names)
                     (cl-loop for (_key spec) on table by #'cddr
                              do (push (plist-get spec :name) names))
                     (mapconcat #'identity (nreverse names) ", "))))))))

;;;; The jsonyter marker mode

(define-minor-mode jsonyter-mode
  "Marker mode, on in every jsonyter buffer regardless of its kind.

`jsonyter-repl-mode' (a REPL), `jsonyter-notebook-mode' (a rendered
.ipynb), `jsonyter-script-mode' (\"# %%\" cells in a script) and
`jsonyter-org-mode' (`:session jy:...' blocks in Org) all turn this on
and never off — killing the buffer is what ends it.  An Org buffer using
only the `org-babel' back door (`C-c C-c', export, tangle) turns it on
lazily instead, via `jsonyter--org-babel-ensure-plumbing', without
`jsonyter-org-mode' ever having run.  It carries no keymap or behavior of
its own; it exists purely so other code can ask \"is this any kind of
jsonyter buffer\" with one check — `(bound-and-true-p jsonyter-mode)' —
without caring which kind it is or repeating that test itself.

`jsonyter-save-buffer' is built on exactly this and is the pattern to
copy: dispatch on the specific mode only where the specific mode's
buffer actually needs different handling, and treat `jsonyter-mode' as
the umbrella everything else can hang off, e.g. a leader-key \"save\"
binding that should do the right thing in a notebook without changing
behavior anywhere else:

  (defun my/save-buffer ()
    (interactive)
    (if (bound-and-true-p jsonyter-mode)
        (jsonyter-save-buffer)
      (save-buffer)))"
  :group 'jsonyter
  :init-value nil
  :lighter nil)

(defun jsonyter-save-buffer ()
  "Save the current buffer the jsonyter way.

In a notebook, delegates to `jsonyter-notebook-save-buffer', which
explains itself rather than silently doing nothing when only this
session's output changed \\(see `jsonyter-notebook-save-with-outputs' to
save that too\\).  Everywhere else — a script-cells buffer, a REPL, or
any ordinary buffer — delegates to `save-buffer' unchanged: a script
buffer's cell output lives entirely in overlays, so its file is always
just what `save-buffer' already saves.

The one command to bind to a generic \"save\" key that should also do
the right thing in a jsonyter notebook; see `jsonyter-mode'."
  (interactive)
  (if (bound-and-true-p jsonyter-notebook-mode)
      (jsonyter-notebook-save-buffer)
    (save-buffer)))

(provide 'jsonyter-core)
;;; jsonyter-core.el ends here
