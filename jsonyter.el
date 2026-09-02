;;; jsonyter.el --- Interactive Jupyter REPLs via the jsonyter bridge -*- lexical-binding: t; -*-

;; Author: Ethan Guthrie
;; Assisted-by: Claude:claude-fable-5
;; Assisted-by: Claude:claude-sonnet-5
;; Version: 2.1.4
;; Package-Requires: ((emacs "27.1") (org "9.4"))
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

;; Interactive Jupyter REPL buffers for Emacs, backed by the `jsonyter'
;; Python package (https://github.com/EGuthrieWasTaken/jsonyter), which
;; exposes a Jupyter server as a line-oriented JSON protocol over
;; stdin/stdout.
;;
;; Entry points:
;;
;;   M-x jsonyter-start-python
;;   M-x jsonyter-start-julia
;;   M-x jsonyter-start-R
;;   M-x jsonyter-start-SAS
;;   M-x jsonyter-start          (prompts for a language)
;;
;; Each command starts (or pops to) a REPL buffer connected to a kernel of
;; that language on the configured Jupyter server.  The kernel spec is
;; auto-detected from the server's kernelspec list by language, or pinned
;; explicitly via `jsonyter-kernel-names'.
;;
;; Configuration (e.g. in init.el / config.el):
;;
;;   (setq jsonyter-server-url "https://jupyter.example.com:8888")
;;   ;; a (possibly gpg-encrypted) file holding the token:
;;   (setq jsonyter-server-token-file "~/.authinfo.d/jupyter-token.gpg")
;;
;; A ".gpg" token file is decrypted transparently by EasyPG (`epa-file'),
;; which is enabled by default in modern Emacs, so the token never has to
;; appear in plain text in your config.  The token is handed to the bridge
;; through the subprocess environment (`JUPYTER_TOKEN') rather than argv,
;; so it is not visible to other local users via ps — see
;; `jsonyter-token-transport'.
;;
;; In the REPL:
;;
;;   RET        send input (or continue on a new line if incomplete)
;;   M-RET      force-send input even if the kernel says it is incomplete
;;   C-j        insert a literal newline
;;   TAB        complete at point (kernel-backed)
;;   M-p / M-n  cycle input history
;;   C-c C-c    interrupt the kernel
;;   C-c C-r    restart the kernel
;;   C-c C-q    shut the kernel down
;;   C-c C-d    show documentation for the thing at point
;;   C-c C-k    reset a REPL stuck at "kernel is busy"
;;   C-c M-o    clear previous output from the buffer
;;
;; Output streams in as it is produced, so a long-running cell shows its
;; `print' output live.  Rich output is rendered like a notebook where
;; Emacs allows: image/png, image/jpeg and image/svg+xml mimebundles are
;; decoded and displayed inline; text/html is rendered with shr when
;; libxml is available; ANSI escape codes are colorized.  Kernel state
;; (busy/idle/dead) is reported in the mode line from the bridge's async
;; event subscription.
;;
;; The same machinery drives four surfaces, all sharing one bridge and
;; one kernel model: the REPL, a rendered `.ipynb' (`jsonyter-notebook-open'),
;; `# %%' cells in a script (`jsonyter-script-mode'), and -- new in 2.0 --
;; `#+begin_src' blocks in an Org file whose `:session' starts with `jy:'
;; (`jsonyter-org-mode'; add `jsonyter-org-mode-maybe' to `org-mode-hook').
;; A jsonyter buffer holds a table of sessions keyed (language, name), so
;; one Org file can drive Python, R and SAS kernels at once; the public
;; accessors are `jsonyter-current-session' and `jsonyter-current-kernel-id'.
;;
;; Requires jsonyter >= 0.2 (concurrent bridge, "stream", "subscribe",
;; JUPYTER_TOKEN).  Against an older bridge the REPL still works, minus
;; live streaming and kernel-state reporting.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ansi-color)
;; `create-image', `image-size', `insert-sliced-image' and the
;; `image-property' place all live here.  A graphical Emacs has loaded
;; it long before this file, but a batch or terminal one has not, and
;; `(setf (image-property ...))' in particular needs it loaded before
;; this file is read: without it `setf' finds no expander and compiles
;; a call to a `(setf image-property)' function that does not exist.
(require 'image)

(declare-function shr-render-region "shr" (begin end &optional buffer))

;;;; Customization

(defgroup jsonyter nil
  "Jupyter REPLs over the jsonyter JSON bridge."
  :group 'processes
  :prefix "jsonyter-")

(defcustom jsonyter-server-url "http://localhost:8888"
  "Base URL of the Jupyter server, local or remote.
For a remote server use e.g. \"https://jupyter.example.com:8888\"."
  :type 'string)

(defcustom jsonyter-server-token nil
  "Authentication token for the Jupyter server.
Either a literal token string, or a function of no arguments that
returns the token.  If nil, `jsonyter-server-token-file' is consulted
instead.  Prefer the file (optionally gpg-encrypted) over a literal
string so the token does not live in your config.

If both are nil the bridge falls back to the `JUPYTER_TOKEN'
environment variable, if Emacs inherited one."
  :type '(choice (const :tag "None / use token file" nil)
                 (string :tag "Literal token")
                 (function :tag "Function returning the token")))

(defcustom jsonyter-server-token-file nil
  "File containing the Jupyter authentication token.
The file's contents (trimmed of whitespace) are used as the token.
A file ending in \".gpg\" is decrypted transparently by EasyPG
\(`epa-file'), so the token can be stored encrypted, e.g.:

  (setq jsonyter-server-token-file \"~/.authinfo.d/jupyter-token.gpg\")

Only consulted when `jsonyter-server-token' is nil."
  :type '(choice (const :tag "None" nil) file))

(defcustom jsonyter-token-transport 'env
  "How the token is handed to the bridge process.

`env'    Set JUPYTER_TOKEN in the subprocess environment.  The default,
         and what the jsonyter README recommends for editors.
`stdin'  Run the bridge with `--token-file -' and write the token as the
         first line of its stdin.  Keeps the token out of the process
         environment as well; the most conservative option.
`file'   Pass `--token-file PATH' and let Python read the file itself,
         so the token never enters Emacs.  Only works for a plaintext
         `jsonyter-server-token-file' — Python cannot decrypt .gpg.
`argv'   Pass `--token SECRET' on the command line.  INSECURE: argv is
         readable by any local user via ps.  Provided only for older
         bridges that support nothing else."
  :type '(choice (const :tag "JUPYTER_TOKEN environment variable" env)
                 (const :tag "First line of the bridge's stdin" stdin)
                 (const :tag "Plaintext file read by Python" file)
                 (const :tag "Command line (insecure)" argv)))

(defcustom jsonyter-command '("jsonyter")
  "Command (as a list) that runs the jsonyter stdio bridge.
Use e.g. \\='(\"python3\" \"-m\" \"jsonyter\") if the entry point script
is not on variable `exec-path'."
  :type '(repeat string))

(defcustom jsonyter-insecure-tls nil
  "If non-nil, pass --insecure to skip TLS certificate verification."
  :type 'boolean)

(defcustom jsonyter-exec-timeout nil
  "Default kernel-reply timeout in seconds passed to the bridge.
This bounds silence from the kernel, not total run time (see the
jsonyter README).  nil means wait indefinitely, which is the right
default for a REPL and for slow-to-warm-up kernels such as SAS."
  :type '(choice (const :tag "Wait indefinitely" nil) number))

(defcustom jsonyter-request-timeout 15
  "Seconds to wait for quick synchronous requests (completion, inspect)."
  :type 'number)

(defcustom jsonyter-startup-timeout 120
  "Seconds to wait for kernel startup and other slow control requests."
  :type 'number)

(defcustom jsonyter-kernel-names nil
  "Alist mapping a language name to an explicit kernel spec name.
E.g. \\='((\"python\" . \"python3\") (\"sas\" . \"sas\")).  Languages not
listed here are resolved by asking the server for its kernelspecs and
picking one whose declared language matches (case-insensitively)."
  :type '(alist :key-type string :value-type string))

(defcustom jsonyter-stream-output t
  "If non-nil, render each output as the kernel produces it.
Requires a bridge that understands the \"stream\" execute parameter
\(jsonyter >= 0.2); with an older bridge output simply arrives all at
once when the cell finishes."
  :type 'boolean)

(defcustom jsonyter-subscribe-events t
  "If non-nil, subscribe to async kernel state events.
This is what keeps the mode line's busy/idle/dead indicator accurate
without polling.  Requires jsonyter >= 0.2."
  :type 'boolean)

(defcustom jsonyter-use-is-complete t
  "If non-nil, ask the kernel whether input is complete before sending.
This is what makes RET continue a multi-line block instead of sending
it.  Disable for kernels where the round trip is too slow to be worth
it; jsonyter.el also stops asking on its own after the first failure."
  :type 'boolean)

(defcustom jsonyter-image-max-width 800
  "Maximum pixel width for inline images, or nil for no limit.
Only honored when Emacs supports native image scaling."
  :type '(choice (const :tag "No limit" nil) integer))

(defcustom jsonyter-image-max-height nil
  "Maximum pixel height for inline images, or nil for no limit.
Tall images can be scrolled through where they are shown, so this is
usually unnecessary; set it if you would rather shrink huge plots to fit
than scroll through them."
  :type '(choice (const :tag "No limit" nil) integer))

(defcustom jsonyter-slice-images t
  "If non-nil, insert images as a stack of one-line-tall slices.

Emacs scrolls by whole lines, and an image inserted the ordinary way
occupies a single line however tall it is.  That makes a plot taller
than the window all-or-nothing: scrolling either steps clean over it or
lands mid-image showing only its bottom edge, and the image can never be
brought fully into view.  Slicing it across as many lines as it is tall
\(what `doc-view' does for page images) lets ordinary line scrolling walk
through it like normal text.

Slices tile only in a buffer that draws no leading between its lines,
so a buffer showing them goes without `line-spacing'; see
`jsonyter-suppress-line-spacing'.

This applies wherever output is the buffer's own text: a REPL buffer,
and a notebook cell, whose output is written into the buffer after its
source.  A `# %%' script cell is the exception — its buffer's text is
the file you save, so its output has to stay an overlay string, where
slices would not be lines at all and images are inserted whole; see
`jsonyter--string-output'."
  :type 'boolean)

(defcustom jsonyter-suppress-line-spacing t
  "If non-nil, drop `line-spacing' in buffers that show sliced images.

`line-spacing' adds leading below every display line, and Emacs adds it
below a line showing an image slice too — so a sliced plot comes out
banded, each strip of picture separated from the next by a bar of
background as tall as the leading.  The `line-height' property
`insert-sliced-image' puts on each row's newline does not prevent this:
it cancels the leading for the newline, but the image glyph on the same
row has already claimed it, and no text property can take it back.  The
only thing that helps is for the buffer not to ask for leading at all.

Only REPL and notebook buffers are touched, and only their own
`line-spacing' is set — it is a buffer-local value, so every other
buffer keeps whatever leading you have configured.  Set this to nil to
keep yours here too: images are then inserted whole rather than banded,
at the cost of the line-by-line scrolling `jsonyter-slice-images'
describes."
  :type 'boolean)

(defcustom jsonyter-render-html t
  "If non-nil, render text/html output with shr when libxml is available."
  :type 'boolean)

(defcustom jsonyter-shutdown-on-kill t
  "If non-nil, shut the kernel down when its REPL buffer is killed."
  :type 'boolean)

(defcustom jsonyter-notebook-separator-width 62
  "Width of the rule drawn beside a cell prompt.
Used for a notebook cell's own prompt, and for the session rules in the
listing `jsonyter-kernel-history' produces."
  :type 'integer)

(defcustom jsonyter-history-size 500
  "Maximum number of inputs kept in the REPL history."
  :type 'integer)

(defcustom jsonyter-kernel-history-count 25
  "Default number of commands shown by `jsonyter-kernel-history'.
This is the kernel's own history — everything it has run, for every
client that ever attached to it — and so has nothing to do with
`jsonyter-history-size', which bounds only the inputs this Emacs
session typed at a REPL prompt."
  :type 'integer)

;;;; Faces

(defface jsonyter-prompt-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for REPL input prompts.")

(defface jsonyter-output-prompt-face
  '((t :inherit font-lock-string-face))
  "Face for \"Out[n]:\" result prompts.")

(defface jsonyter-stderr-face
  '((t :inherit error))
  "Face for stderr stream output.")

(defface jsonyter-note-face
  '((t :inherit shadow))
  "Face for informational notes inserted by jsonyter itself.")

;;;; Buffer-local state

(defvar-local jsonyter--process nil
  "The jsonyter bridge process for this jsonyter buffer.
One bridge per buffer, however many kernels the buffer drives: the
bridge handles requests concurrently and gives each kernel its own
worker, so control messages such as `interrupt_kernel' are serviced on
this same process while an execute is still running, and a Python and an
R kernel in one Org buffer run without blocking each other.")
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
  last-kernel)        ; plist (:id :name); outlives KERNEL-ID being cleared

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
`result'/`error' complete a request, while `output', `input_request'
and `event' are out-of-band and leave the request pending."
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
                  (jsonyter--session-state session) "dead"))
          (jsonyter--announce (format "\n[jsonyter bridge exited: %s]"
                                  (string-trim event)))
          (force-mode-line-update))))))

(defun jsonyter--send (method params &optional handlers)
  "Send METHOD with PARAMS on this buffer's bridge.
HANDLERS is a plist: :result is called with the final reply plist,
:output with each incremental output.  Returns the request id."
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
token-protected server returns exactly \"Forbidden\" and nothing else."
  (let ((message (or (plist-get err :message) (format "%s" err)))
        (status (plist-get err :status)))
    (if (memq status '(401 403))
        (format "%s (set `jsonyter-server-token' or `jsonyter-server-token-file' if %s requires a token)"
               message (or (plist-get err :url) "the server"))
      message)))

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
.ipynb) and `jsonyter-script-mode' (\"# %%\" cells in a script) all turn
this on and never off — killing the buffer is what ends it.  It carries
no keymap or behavior of its own; it exists purely so other code can
ask \"is this any kind of jsonyter buffer\" with one check —
`(bound-and-true-p jsonyter-mode)' — without caring which of the three
it is or repeating that three-way test itself.

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

;;;; Line spacing

;; A sliced image tiles only if each row of the buffer is exactly as
;; tall as the slice it shows.  `line-spacing' breaks that: Emacs adds
;; the leading below the image glyph as readily as below a character,
;; so every slice ends up sitting on a bar of background and the plot
;; is drawn through a set of blinds.  It cannot be fixed per line --
;; the leading comes from the buffer (or the frame), not from anything
;; the text carries — so a buffer that shows slices has to go without
;; it.  See `jsonyter-suppress-line-spacing'.

(defvar-local jsonyter--line-spacing-restore nil
  "How to put `line-spacing' back when jsonyter stops managing it.
Nil when jsonyter has not set it in this buffer; `kill' when the buffer
had no `line-spacing' of its own before; otherwise a cons whose cdr is
the value to put back.")

(defun jsonyter--line-spacing ()
  "Extra leading, in pixels, this buffer draws below every line.
The buffer's own `line-spacing', else the global one, else the frame's
parameter — the same order `default-line-height' consults, and the
order Emacs itself resolves them in.  A float is a multiple of the
frame's line height, as `line-spacing' documents.  Zero on a text
terminal, which has no such thing."
  (if (not (display-graphic-p))
      0
    (let ((spacing (or line-spacing
                       (default-value 'line-spacing)
                       (frame-parameter nil 'line-spacing)
                       0)))
      (max 0 (if (floatp spacing)
                 (truncate (* (frame-char-height) spacing))
               spacing)))))

(defun jsonyter--suppress-line-spacing ()
  "Take `line-spacing' out of this buffer so image slices tile.
Does nothing unless there is leading to remove and something that would
be spoiled by it; see `jsonyter-suppress-line-spacing'.

The value set is 0 rather than nil deliberately: a buffer-local nil
means \"no opinion\" and Emacs falls through to the frame's own
`line-spacing' parameter, which would leave the bands in place on a
frame that sets one."
  (when (and jsonyter-suppress-line-spacing
             jsonyter-slice-images
             (not (zerop (jsonyter--line-spacing))))
    (setq jsonyter--line-spacing-restore
          (if (local-variable-p 'line-spacing)
              (cons 'set line-spacing)
            'kill))
    (setq-local line-spacing 0)))

(defun jsonyter--restore-line-spacing ()
  "Undo `jsonyter--suppress-line-spacing' in this buffer.
Leaves alone a `line-spacing' jsonyter never set, and puts back one the
buffer had of its own rather than assuming it had none."
  (pcase jsonyter--line-spacing-restore
    ('nil nil)
    ('kill (kill-local-variable 'line-spacing))
    (`(set . ,value) (setq-local line-spacing value)))
  (setq jsonyter--line-spacing-restore nil))

;;;; REPL buffer basics

(defvar jsonyter-repl-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'jsonyter-repl-return)
    (define-key map (kbd "M-RET") #'jsonyter-repl-send)
    (define-key map (kbd "<C-return>") #'jsonyter-repl-send)
    (define-key map (kbd "C-j") #'jsonyter-repl-newline)
    (define-key map (kbd "TAB") #'completion-at-point)
    (define-key map (kbd "C-a") #'jsonyter-repl-beginning-of-line)
    (define-key map (kbd "M-p") #'jsonyter-repl-previous-input)
    (define-key map (kbd "M-n") #'jsonyter-repl-next-input)
    (define-key map (kbd "C-c C-c") #'jsonyter-interrupt)
    (define-key map (kbd "C-c C-r") #'jsonyter-restart)
    (define-key map (kbd "C-c C-q") #'jsonyter-shutdown)
    (define-key map (kbd "C-c C-l") #'jsonyter-kernel-reconnect)
    (define-key map (kbd "C-c C-j") #'jsonyter-kernel-connect)
    (define-key map (kbd "C-c M-h") #'jsonyter-kernel-history)
    (define-key map (kbd "C-c C-d") #'jsonyter-repl-inspect)
    (define-key map (kbd "C-c C-k") #'jsonyter-reset)
    (define-key map (kbd "C-c M-o") #'jsonyter-repl-clear)
    map)
  "Keymap for `jsonyter-repl-mode'.")

(defun jsonyter--session-status-tag (session)
  "The mode-line tag for one SESSION: our request state, else the kernel's."
  (let ((state (jsonyter--session-state session)))
    (cond
     ((jsonyter--session-busy session) ":run")
     ((equal state "dead") ":dead")
     ((equal state "restarting") ":restarting")
     ((equal state "disconnected") ":offline")
     ;; Busy without a request of ours in flight: another client is using
     ;; this kernel.
     ((equal state "busy") ":run[ext]")
     ((equal state "starting") ":starting")
     ((null (jsonyter--session-kernel-id session)) ":no-kernel")
     (t ":idle"))))

(defun jsonyter--mode-line-string ()
  "Mode-line indicator for the session in play.

A REPL, notebook or script buffer has one session and reports it.  An
Org buffer reports the session of the block at point; with point outside
every `jy:' block it summarizes -- the lone session's state if there is
just one, otherwise a count like `:2 kernels' with a `!' if any is busy."
  (let ((current (or (jsonyter--session)
                     (and (derived-mode-p 'org-mode)
                          (fboundp 'jsonyter--org-session-at-point)
                          (jsonyter--org-session-at-point 'noerror)))))
    (cond
     (current (jsonyter--session-status-tag current))
     ((null (jsonyter--session-list)) "")
     ((cdr (jsonyter--session-list))
      (let ((sessions (jsonyter--session-list)))
        (format ":%d kernel%s%s" (length sessions)
                (if (cdr sessions) "s" "")
                (if (seq-some #'jsonyter--session-busy sessions) "!" ""))))
     (t (jsonyter--session-status-tag (car (jsonyter--session-list)))))))

(define-derived-mode jsonyter-repl-mode fundamental-mode "Jsonyter"
  "Major mode for interactive Jupyter REPL buffers via jsonyter.

\\{jsonyter-repl-mode-map}"
  (setq-local jsonyter--callbacks (make-hash-table :test #'eql))
  (setq-local jsonyter--prompt-start (make-marker))
  (setq-local jsonyter--input-start (make-marker))
  (setq-local jsonyter--output-start (make-marker))
  (setq-local jsonyter--output-end (make-marker))
  (set-marker-insertion-type jsonyter--output-end t)
  (setq-local scroll-conservatively 101)
  (jsonyter--suppress-line-spacing)
  ;; A REPL buffer is entirely output and frozen input -- there is no
  ;; source here for font-lock to highlight, and `font-lock-defaults' is
  ;; nil accordingly.  But `global-font-lock-mode' still switches
  ;; `font-lock-mode' on, and `font-lock-default-unfontify-region' strips
  ;; the `face' text property wherever it runs.  Every colour in this
  ;; buffer -- the `Out[N]:' prompts, stderr, resolved ANSI escapes, the
  ;; bracketed notes -- is a hand-applied `face' property, so the only
  ;; thing font-lock can accomplish here is erasing all of it the first
  ;; time redisplay drives jit-lock over the region.
  ;;
  ;; Invisible to a batch test, which never redisplays and so never
  ;; fontifies; found by running the suite in a real frame.
  ;; `jsonyter-notebook-mode' already defends cell output this way in
  ;; both directions (`jsonyter--nb-fontify-region' and
  ;; `jsonyter--nb-unfontify-region'); the REPL needs the same and had
  ;; nothing.  Overriding the functions rather than turning the mode off
  ;; because `global-font-lock-mode' re-enables it from
  ;; `after-change-major-mode-hook', i.e. after this body has run.
  (setq-local font-lock-fontify-region-function #'ignore)
  (setq-local font-lock-unfontify-region-function #'ignore)
  (setq mode-line-process '(:eval (jsonyter--mode-line-string)))
  (add-hook 'completion-at-point-functions #'jsonyter-completion-at-point nil t)
  (add-hook 'kill-buffer-hook #'jsonyter--cleanup nil t)
  (jsonyter-mode 1))

(defun jsonyter--insert-at (position renderer)
  "Call RENDERER with point at POSITION, then keep windows scrolled.
Windows whose point was at or after POSITION follow the new end, so
streaming output scrolls into view without stealing point from a user
reading further up."
  (let ((inhibit-read-only t)
        (follow '()))
    (dolist (window (get-buffer-window-list (current-buffer) nil t))
      (when (>= (window-point window) position)
        (push window follow)))
    (save-excursion
      (goto-char position)
      (funcall renderer))
    (dolist (window follow)
      (set-window-point window (point-max)))))

(defun jsonyter--note (text)
  "Insert an informational TEXT note at the end of the buffer."
  (jsonyter--insert-at
   (point-max)
   (lambda ()
     (unless (bolp) (insert "\n"))
     (insert (propertize text 'face 'jsonyter-note-face) "\n"))))

(defun jsonyter--announce (text &optional session)
  "Report TEXT wherever this buffer's kind of transcript lives.
A REPL's transcript *is* its buffer text, so notes belong inline.  A
notebook or Org buffer's text is the document — writing a note into it
would corrupt it — so those go to the echo area.

SESSION, when given and named, is folded into the echo-area message so a
buffer driving several kernels says which one an event concerns."
  (if (derived-mode-p 'jsonyter-repl-mode)
      (jsonyter--note text)
    (let ((name (and session (jsonyter--session-name session))))
      (message "jsonyter%s: %s"
               (if (and name (not (string-empty-p name))) (format " [%s]" name) "")
               (string-trim (string-trim text) "\\[" "\\]")))))

(defun jsonyter--insert-prompt ()
  "Freeze everything so far and insert a fresh input prompt at the end."
  (let ((inhibit-read-only t))
    (goto-char (point-max))
    (unless (bolp) (insert "\n"))
    ;; Everything before the new prompt becomes read-only history.
    (when (> (point) (point-min))
      (add-text-properties (point-min) (point) '(read-only t)))
    (set-marker jsonyter--prompt-start (point))
    (let ((start (point)))
      (insert (format "In [%d]: " (1+ jsonyter--execution-count)))
      (add-text-properties start (point)
                           '(read-only t
                             front-sticky (read-only)
                             rear-nonsticky t
                             face jsonyter-prompt-face)))
    (set-marker jsonyter--input-start (point))
    (goto-char (point-max))))

(defun jsonyter--current-input ()
  "Text of the input at the current prompt, or \"\" before one exists."
  (if (marker-position jsonyter--input-start)
      (buffer-substring-no-properties jsonyter--input-start (point-max))
    ""))

(defun jsonyter--set-input (text)
  "Replace the current input region with TEXT."
  (let ((inhibit-read-only t))
    (delete-region jsonyter--input-start (point-max))
    (goto-char (point-max))
    (insert text)))

;;;; Output rendering

(defvar jsonyter--string-output nil
  "Non-nil while rendering an output into a string rather than buffer text.

A `# %%' script cell shows its output in an overlay string, and an
overlay string is a single buffer position however many newlines it
contains: redisplay cannot begin part way into one.  The lines a sliced
image is spread across are therefore not buffer lines there, and nothing
— `next-line', `scroll-up-command', `recenter' — can move between them;
a plot taller than the window pins `window-start' in front of it and the
buffer cannot be scrolled past it at all.  A whole image is a single
glyph on a single line instead, which Emacs does scroll through, by
pixel.  So slicing is skipped when this is set.

Only script cells need it.  A script buffer's text is exactly the file
being saved, so nothing may be written into it; a notebook buffer is a
rendered view, so its cell output is real buffer text with real lines
and is sliced like a REPL's — see `jsonyter--nb-show-output-as-text'.")

(defun jsonyter--mime (data key)
  "Return the KEY entry of mimebundle DATA as a string, or nil.
Handles values that arrive as a list of line fragments."
  (let ((v (plist-get data key)))
    (cond ((null v) nil)
          ((stringp v) v)
          ((listp v) (mapconcat #'identity v ""))
          (t (format "%s" v)))))

(defun jsonyter--insert-ansi (text &optional face)
  "Insert TEXT with ANSI escapes rendered; apply FACE if given."
  (let ((rendered (ansi-color-apply text)))
    (if face
        (insert (propertize rendered 'face face))
      (insert rendered))))

(defun jsonyter--image-rows (image line-height)
  "How many text lines IMAGE should be sliced across, or nil for one.
LINE-HEIGHT is the pixel height of a line in the buffer that will show
it.  Returns nil when slicing is off, when the output is bound for a
script cell's overlay string rather than for buffer text, when there is
no graphical display, or when the image's displayed size cannot be
measured.

Also nil when the buffer still draws leading below each line: Emacs
draws it below an image slice too, so slicing there would band the
picture rather than tile it.  A REPL or notebook buffer has had that
leading removed by `jsonyter--suppress-line-spacing' before any of this
runs, so this only bites where the user has asked to keep it — and
there a whole image, which has no seams to show, is the better of the
two."
  (and jsonyter-slice-images
       (not jsonyter--string-output)
       (display-graphic-p)
       (zerop (jsonyter--line-spacing))
       (ignore-errors
         (max 1 (round (/ (float (cdr (image-size image t))) line-height))))))

(defun jsonyter--fit-image-to-lines (image rows line-height)
  "Resize IMAGE so that slicing it into ROWS lands on whole text lines.
A slice is only as tall as its own share of the image, so unless the
image's height is an exact multiple of LINE-HEIGHT every slice comes up
short of the line it sits on, and the shortfall is drawn as a band of
background — a stripe across the picture, once per slice.  Rounding the
height to a whole number of lines removes the shortfall.

That is one of the two ways slices come out banded; `line-spacing' is
the other, and `jsonyter-suppress-line-spacing' deals with it.

Both dimensions are pinned rather than just the height because
`:max-width' and `:max-height' would otherwise still be free to shrink
the result to preserve the aspect ratio, undoing the fit; `:width' and
`:height' take precedence over them."
  (let* ((size (image-size image t))
         (height (cdr size))
         (target (* rows line-height)))
    (unless (zerop height)
      (setf (image-property image :width)
            (max 1 (round (* (car size) (/ (float target) height))))
            (image-property image :height) target))))

(defun jsonyter--insert-image (image alt)
  "Insert IMAGE at point with ALT as its text fallback.
Tall images are sliced one text line per row so that line-based
scrolling can move through them; see `jsonyter-slice-images'.  Output
bound for a script cell's overlay string is inserted whole instead,
since slices would not be lines there at all — see
`jsonyter--string-output'."
  (let* ((line-height (max 1 (default-font-height)))
         (rows (jsonyter--image-rows image line-height)))
    (if (and rows (> rows 1))
        (progn
          (jsonyter--fit-image-to-lines image rows line-height)
          ;; `insert-sliced-image' repeats its string once per row, so it
          ;; gets a single space (as `doc-view' does) rather than ALT --
          ;; otherwise the buffer's real text, and anything copied out of
          ;; it, is the alt text repeated once per slice. It also
          ;; terminates each row with its own newline, so no trailing one
          ;; is needed here.
          (insert-sliced-image image " " nil rows 1))
      (insert-image image alt)
      (insert "\n"))))

(defun jsonyter--image-scale-props ()
  "Scaling properties to hand `create-image', per the size options."
  (append (and jsonyter-image-max-width
               (list :max-width jsonyter-image-max-width))
          (and jsonyter-image-max-height
               (list :max-height jsonyter-image-max-height))))

(defun jsonyter--insert-encoded-image (base64-data type)
  "Insert an inline image of TYPE from BASE64-DATA, with a text fallback."
  (let* ((clean (replace-regexp-in-string "[ \t\r\n]" "" base64-data))
         (raw (ignore-errors (base64-decode-string clean)))
         (image (and raw
                     (ignore-errors
                       (apply #'create-image raw type t
                              (jsonyter--image-scale-props))))))
    (if (not image)
        (insert (format "[%s image: could not decode]\n" type))
      (jsonyter--insert-image image (format "[%s image]" type)))))

(defun jsonyter--insert-html (html)
  "Render HTML into the buffer with shr."
  (require 'shr)
  (let ((start (point)))
    (insert html)
    (condition-case nil
        (shr-render-region start (point))
      (error nil))
    (goto-char (point-max))
    (unless (bolp) (insert "\n"))))

(defun jsonyter--insert-mimebundle (data)
  "Insert the richest representation of mimebundle DATA we can render.
Priority: png > jpeg > svg > html (shr) > plain text — the same idea a
notebook front end uses."
  (cond
   ((and (display-images-p) (image-type-available-p 'png)
         (jsonyter--mime data :image/png))
    (jsonyter--insert-encoded-image (jsonyter--mime data :image/png) 'png))
   ((and (display-images-p) (image-type-available-p 'jpeg)
         (jsonyter--mime data :image/jpeg))
    (jsonyter--insert-encoded-image (jsonyter--mime data :image/jpeg) 'jpeg))
   ((and (display-images-p) (image-type-available-p 'svg)
         (jsonyter--mime data :image/svg+xml))
    (jsonyter--insert-image
     (apply #'create-image (jsonyter--mime data :image/svg+xml) 'svg t
            (jsonyter--image-scale-props))
     "[svg image]"))
   ((and jsonyter-render-html
         (fboundp 'libxml-parse-html-region)
         (jsonyter--mime data :text/html))
    (jsonyter--insert-html (jsonyter--mime data :text/html)))
   ((jsonyter--mime data :text/plain)
    (jsonyter--insert-ansi (jsonyter--mime data :text/plain))
    (unless (bolp) (insert "\n")))
   (t
    (insert "[unrenderable output]\n"))))

(defun jsonyter--clear-cell-output ()
  "Delete the running cell's output, for clear_output."
  (when (and (marker-position jsonyter--output-start)
             (marker-position jsonyter--output-end)
             (<= jsonyter--output-start jsonyter--output-end))
    (delete-region jsonyter--output-start jsonyter--output-end)))

(defun jsonyter--render-output (output)
  "Insert one OUTPUT dict at point.
Point is expected to be at `jsonyter--output-end'."
  ;; A clear_output with wait=t defers the clear until the replacement
  ;; output shows up — that is what makes progress bars and animations
  ;; redraw in place instead of flickering.
  (when (and jsonyter--clear-pending
             (not (equal (plist-get output :type) "clear_output")))
    (setq jsonyter--clear-pending nil)
    (jsonyter--clear-cell-output)
    (goto-char jsonyter--output-end))
  (pcase (plist-get output :type)
    ("stream"
     (jsonyter--insert-ansi (or (plist-get output :text) "")
                            (when (equal (plist-get output :name) "stderr")
                              'jsonyter-stderr-face)))
    ((or "execute_result" "display_data" "update_display_data")
     (unless (bolp) (insert "\n"))
     (when (equal (plist-get output :type) "execute_result")
       (insert (propertize
                (format "Out[%s]: "
                        (or (plist-get output :execution_count) ""))
                'face 'jsonyter-output-prompt-face)))
     (jsonyter--insert-mimebundle (plist-get output :data)))
    ("error"
     (unless (bolp) (insert "\n"))
     (jsonyter--insert-ansi
      (mapconcat #'identity (plist-get output :traceback) "\n"))
     (unless (bolp) (insert "\n")))
    ("clear_output"
     (if (eq (plist-get output :wait) t)
         (setq jsonyter--clear-pending t)
       (jsonyter--clear-cell-output)
       (goto-char jsonyter--output-end)))))

(defun jsonyter--stream-output (output)
  "Render OUTPUT as it arrives from a running cell."
  (jsonyter--insert-at
   (marker-position jsonyter--output-end)
   (lambda () (jsonyter--render-output output))))

;;;; Sending input

(defun jsonyter-repl-return ()
  "Send the current input if the kernel deems it complete, else newline."
  (interactive)
  (cond
   ((not (jsonyter--live-p))
    (user-error "No live kernel in this buffer"))
   ((jsonyter--busy-p)
    (message "jsonyter: kernel is busy (C-c C-c to interrupt)"))
   ((< (point) jsonyter--input-start)
    (goto-char (point-max)))
   (t
    (let ((code (jsonyter--current-input)))
      (if (string-blank-p code)
          (message "jsonyter: nothing to send")
        (let ((reply (jsonyter--is-complete code)))
          (if (equal (plist-get reply :status) "incomplete")
              (progn
                (goto-char (point-max))
                (insert "\n" (or (plist-get reply :indent) "")))
            (jsonyter--execute code))))))))

(defconst jsonyter--is-complete-give-up 2
  "Consecutive `is_complete' failures before we stop asking.
More than one, so a single hiccup on a remote server does not cost the
buffer its multi-line editing for the rest of the session; few enough
that a kernel which simply never answers stops being asked quickly.")

(defun jsonyter--is-complete (code)
  "Ask the kernel whether CODE is complete input; nil if unavailable.
After `jsonyter--is-complete-give-up' consecutive failures we stop
asking, so a kernel that does not implement is_complete costs a couple
of round trips rather than one per RET.  Any success resets the count."
  (when (and jsonyter-use-is-complete
             (< jsonyter--is-complete-failures jsonyter--is-complete-give-up))
    (condition-case err
        (prog1 (jsonyter--kernel-request
                "is_complete"
                ;; Ask about the code as a *submitted* cell, i.e. newline
                ;; terminated. Kernels key off that: the SAS kernel calls
                ;; anything without a trailing newline "incomplete" (even
                ;; the empty string), so without this RET could never send
                ;; SAS at all. It also fixes Python, where
                ;; "def f():\n    return 1" reads as incomplete bare but
                ;; complete once terminated. Genuinely unfinished input
                ;; ("if True:") still reports incomplete on every kernel,
                ;; so nothing is sent early. The bridge deliberately does
                ;; not append this for us — it is the front end's call.
                (list :kernel_id (jsonyter-current-kernel-id)
                      :code (concat code "\n")))
          (setq jsonyter--is-complete-failures 0))
      (error
       (cl-incf jsonyter--is-complete-failures)
       (message
        (if (< jsonyter--is-complete-failures jsonyter--is-complete-give-up)
            "jsonyter: is_complete failed (%s); sending anyway, will retry"
          "jsonyter: is_complete unavailable (%s); RET now always sends")
        (error-message-string err))
       nil))))

(defun jsonyter-repl-send ()
  "Send the current input unconditionally."
  (interactive)
  (cond
   ((not (jsonyter--live-p)) (user-error "No live kernel in this buffer"))
   ((jsonyter--busy-p)
    (message "jsonyter: kernel is busy"))
   (t (let ((code (jsonyter--current-input)))
        (if (string-blank-p code)
            (message "jsonyter: nothing to send")
          (jsonyter--execute code))))))

(defun jsonyter-repl-newline ()
  "Insert a newline into the current input."
  (interactive)
  (goto-char (max (point) (marker-position jsonyter--input-start)))
  (insert "\n"))

(defun jsonyter--execute (code)
  "Send CODE to the kernel and render its outputs as they arrive."
  (jsonyter--history-add code)
  (let ((session (jsonyter--session)))
    (setq jsonyter--history-index -1
          jsonyter--history-stash nil
          jsonyter--clear-pending nil)
    (setf (jsonyter--session-busy session) t)
    (force-mode-line-update)
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (insert "\n")
      ;; Freeze the sent input.
      (add-text-properties jsonyter--input-start (point) '(read-only t)))
    (set-marker jsonyter--output-start (point-max))
    (set-marker jsonyter--output-end (point-max))
    ;; Count what streaming already drew: the final result repeats every
    ;; output, and an older bridge that ignores "stream" sends none at all,
    ;; so rendering the tail past this count is right either way.
    (let ((streamed 0)
          (params (append (list :kernel_id (jsonyter--session-kernel-id session)
                                :code code)
                          (and jsonyter-stream-output '(:stream t)))))
      (jsonyter--send
       "execute" params
       (list
        :output (lambda (output)
                  (cl-incf streamed)
                  (jsonyter--stream-output output))
        :result
        (lambda (msg)
          (setf (jsonyter--session-busy session) nil)
          (force-mode-line-update)
          (let ((err (plist-get msg :error))
                (result (plist-get msg :result)))
            (cond
             (err
              (jsonyter--note (format "[execute failed: %s]"
                                      (jsonyter--error-message err))))
             (result
              (let ((n (plist-get result :execution_count)))
                (when n (setq jsonyter--execution-count n)))
              (let ((remaining (nthcdr streamed (plist-get result :outputs))))
                (when remaining
                  (jsonyter--insert-at
                   (marker-position jsonyter--output-end)
                   (lambda ()
                     (dolist (output remaining)
                       (jsonyter--render-output output))))))
              (when (equal (plist-get result :status) "aborted")
                (jsonyter--note "[execution aborted]")))))
          (let ((inhibit-read-only t))
            (goto-char (point-max)))
          (jsonyter--insert-prompt)))))))

;;;; History

(defun jsonyter--history-add (code)
  "Push CODE onto the input history, unless it repeats the last entry."
  (unless (equal code (car jsonyter--history))
    (push code jsonyter--history)
    (when (> (length jsonyter--history) jsonyter-history-size)
      (setcdr (nthcdr (1- jsonyter-history-size) jsonyter--history) nil))))

(defun jsonyter-repl-previous-input ()
  "Replace the input with the previous history entry."
  (interactive)
  (unless jsonyter--history
    (user-error "No input history yet"))
  (when (< jsonyter--history-index 0)
    (setq jsonyter--history-stash (jsonyter--current-input)))
  (if (>= (1+ jsonyter--history-index) (length jsonyter--history))
      (message "jsonyter: beginning of history")
    (cl-incf jsonyter--history-index)
    (jsonyter--set-input (nth jsonyter--history-index jsonyter--history))))

(defun jsonyter-repl-next-input ()
  "Replace the input with the next history entry."
  (interactive)
  (cond
   ((> jsonyter--history-index 0)
    (cl-decf jsonyter--history-index)
    (jsonyter--set-input (nth jsonyter--history-index jsonyter--history)))
   ((= jsonyter--history-index 0)
    (setq jsonyter--history-index -1)
    (jsonyter--set-input (or jsonyter--history-stash "")))
   (t (message "jsonyter: end of history"))))

;;;; Completion and inspection

(defun jsonyter-completion-at-point ()
  "Kernel-backed `completion-at-point' function for the REPL."
  (when (and (jsonyter--live-p)
             (not (jsonyter--busy-p))
             (marker-position jsonyter--input-start)
             (>= (point) jsonyter--input-start))
    (let* ((code (jsonyter--current-input))
           (pos (- (point) jsonyter--input-start))
           (reply (ignore-errors
                    (jsonyter--kernel-request
                     "complete"
                     (list :kernel_id (jsonyter-current-kernel-id)
                           :code code :cursor_pos pos)))))
      (when (and reply (equal (plist-get reply :status) "ok"))
        (let ((matches (plist-get reply :matches)))
          (when matches
            (list (+ jsonyter--input-start
                     (or (plist-get reply :cursor_start) pos))
                  (+ jsonyter--input-start
                     (or (plist-get reply :cursor_end) pos))
                  matches)))))))

(defun jsonyter-repl-inspect ()
  "Show kernel documentation for the object at point."
  (interactive)
  (unless (jsonyter--live-p) (user-error "No live kernel in this buffer"))
  (when (jsonyter--busy-p) (user-error "Kernel is busy"))
  (let* ((code (jsonyter--current-input))
         (pos (max 0 (min (length code) (- (point) jsonyter--input-start))))
         (reply (jsonyter--kernel-request
                 "inspect"
                 (list :kernel_id (jsonyter-current-kernel-id)
                       :code code :cursor_pos pos)))
         (text (and (eq (plist-get reply :found) t)
                    (jsonyter--mime (plist-get reply :data) :text/plain))))
    (if (not text)
        (message "jsonyter: no documentation found")
      (with-help-window "*jsonyter-doc*"
        (with-current-buffer standard-output
          (insert (ansi-color-apply text)))))))

;;;; Kernel control

(defun jsonyter--subscribe (session)
  "Subscribe to SESSION's async kernel state events, if the bridge supports it."
  (when jsonyter-subscribe-events
    (condition-case err
        (let ((reply (jsonyter--request-sync
                      "subscribe"
                      (list :kernel_id (jsonyter--session-kernel-id session)))))
          (setf (jsonyter--session-state session)
                (plist-get reply :execution_state))
          t)
      (error
       ;; An older bridge has no `subscribe'; the REPL works fine without
       ;; it, only the mode line goes quiet.
       (setf (jsonyter--session-state session) nil)
       (message "jsonyter: kernel events unavailable (%s)"
                (error-message-string err))
       nil))))

(defun jsonyter--command-session ()
  "The session an interactive kernel command should act on.
The buffer's sole session where there is one; in an Org buffer, the
session of the `jy:' block at point.  Signals when neither applies."
  (or (jsonyter--session)
      (and (derived-mode-p 'org-mode)
           (fboundp 'jsonyter--org-session-at-point)
           (jsonyter--org-session-at-point))
      (user-error "jsonyter: no kernel session here")))

(defun jsonyter-interrupt (&optional session)
  "Interrupt SESSION's kernel (default the session in play).
The bridge handles requests concurrently, so this is acted on
immediately even while an execute is still running."
  (interactive)
  (let* ((session (or session (jsonyter--command-session)))
         (id (jsonyter--session-kernel-id session)))
    (unless id (user-error "No kernel in this session"))
    (jsonyter--request-sync "interrupt_kernel" (list :kernel_id id))
    (message "jsonyter: interrupt sent")))

(defun jsonyter-restart (&optional session)
  "Restart SESSION's kernel (default the session in play), keeping its id."
  (interactive)
  (let* ((session (or session (jsonyter--command-session)))
         (id (jsonyter--session-kernel-id session)))
    (unless id (user-error "No kernel in this session"))
    (when (yes-or-no-p "Restart the kernel (all state will be lost)? ")
      (jsonyter--request-sync "restart_kernel"
                              (list :kernel_id id)
                              jsonyter-startup-timeout)
      ;; Drop the now-stale websocket so the next execute reconnects
      ;; cleanly.  This also drops the event subscription, so renew it.
      (ignore-errors
        (jsonyter--request-sync "disconnect" (list :kernel_id id)))
      (setf (jsonyter--session-busy session) nil)
      (setq jsonyter--execution-count 0
            jsonyter--clear-pending nil)
      (jsonyter--subscribe session)
      (jsonyter--after-kernel-reset "[kernel restarted]" session))))

(defun jsonyter-shutdown (&optional session)
  "Shut SESSION's kernel down (default the session in play).
In a REPL, notebook or script buffer this also stops the bridge process,
since that buffer has only the one kernel; in an Org buffer the bridge
stays up for the buffer's other sessions."
  (interactive)
  (let* ((session (or session (jsonyter--command-session)))
         (id (jsonyter--session-kernel-id session)))
    (unless id (user-error "No kernel in this session"))
    (when (yes-or-no-p "Shut the kernel down? ")
      (ignore-errors
        (jsonyter--request-sync "shutdown_kernel" (list :kernel_id id)))
      (setf (jsonyter--session-own session) nil
            (jsonyter--session-last-kernel session) nil)
      (jsonyter--session-clear session)
      (setf (jsonyter--session-state session) "dead")
      (if jsonyter--session-key
          (progn (jsonyter--kill-process)
                 (jsonyter--announce "\n[kernel shut down]"))
        (jsonyter--session-drop (jsonyter--session-key session))
        (jsonyter--announce "[kernel shut down]" session))
      (force-mode-line-update))))

(defun jsonyter-reset (&optional session)
  "Recover a REPL stuck at a \"kernel is busy\" prompt.
Abandons any in-flight requests, clears SESSION's busy flag and draws a
fresh prompt.  The kernel is left running: if it is genuinely still
working, interrupt it with \\[jsonyter-interrupt] first, or this prompt
will sit alongside output that is still on its way."
  (interactive)
  (let ((session (or session (jsonyter--command-session))))
    (when jsonyter--callbacks (clrhash jsonyter--callbacks))
    (setf (jsonyter--session-busy session) nil)
    (setq jsonyter--clear-pending nil)
    (force-mode-line-update)
    (jsonyter--after-kernel-reset "[reset — kernel left running]" session)))

(defun jsonyter--after-kernel-reset (text &optional session)
  "Put this buffer back in a usable state after a restart or reset.
A REPL gets TEXT in its transcript and a fresh prompt.  A notebook gets
neither — writing into its text would corrupt the document — but its
cells' execution counts are blanked, since the kernel's counter has gone
back to zero and the old numbers no longer mean anything.  SESSION names
the affected session for the echo-area note in a multi-kernel buffer."
  (if (derived-mode-p 'jsonyter-repl-mode)
      (progn (jsonyter--note (concat "\n" text))
             (jsonyter--insert-prompt))
    (when (bound-and-true-p jsonyter-notebook-mode)
      (dolist (cell (jsonyter--nb-cells))
        (overlay-put cell 'jsonyter-exec-count nil)
        (overlay-put cell 'jsonyter-running nil)
        (jsonyter--nb-refresh-prompt cell)))
    (jsonyter--announce text session)))

(defun jsonyter-repl-clear ()
  "Delete all output above the current prompt."
  (interactive)
  (when (marker-position jsonyter--prompt-start)
    (let ((inhibit-read-only t))
      (delete-region (point-min) jsonyter--prompt-start))))

(defun jsonyter-repl-beginning-of-line ()
  "Move to the start of the input on the prompt line, else to bol."
  (interactive)
  (if (and (marker-position jsonyter--input-start)
           (>= (point) jsonyter--input-start)
           (<= (line-beginning-position) jsonyter--input-start))
      (goto-char jsonyter--input-start)
    (move-beginning-of-line 1)))

(defun jsonyter--kill-process ()
  "Stop the bridge process and drop its stderr buffer."
  (when jsonyter--process
    (let ((stderr-buffer (process-get jsonyter--process
                                      'jsonyter-stderr-buffer)))
      (when (process-live-p jsonyter--process)
        (delete-process jsonyter--process))
      (when (buffer-live-p stderr-buffer)
        (kill-buffer stderr-buffer)))))

(defun jsonyter--cleanup ()
  "Kill-buffer hook: shut down every kernel this buffer started, then the bridge.

What is shut down is each kernel this buffer started — not whichever ones
it happens to be attached to now, which may be someone else\\='s.  A
borrowed kernel was theirs before this buffer existed and stays theirs
afterwards, and a buffer that wandered off to one still has its own to
account for.  An Org buffer can have started several; each is ended on
its own terms."
  (when (and jsonyter-shutdown-on-kill (process-live-p jsonyter--process))
    (dolist (session (jsonyter--session-list))
      (when (jsonyter--session-own session)
        ;; Safe even mid-execute: shutdown_kernel is a REST call and runs
        ;; on the bridge's pool, not behind the kernel's queue.
        (ignore-errors
          (jsonyter--request-sync
           "shutdown_kernel"
           (list :kernel_id (jsonyter--session-own session)) 5)))))
  (jsonyter--kill-process))

;;;; Attaching to a kernel that is already running

;; Everything above starts a kernel and holds it for the life of the
;; buffer.  These commands go the other way: they point a buffer that
;; already exists at a kernel that already exists.
;;
;; What makes that necessary is a remote server plus a laptop that slept
;; or lost its network.  The bridge's websocket to the kernel is then
;; half-open — the socket object still reports itself connected, so the
;; bridge's own "reconnect on the next send" never fires, and every
;; later request waits for a reply that cannot arrive.  Closing the
;; socket explicitly is the only thing that breaks that, which is why
;; `jsonyter-kernel-connect' sends `disconnect' before `subscribe' even
;; when it looks redundant.  The kernel itself is untouched by any of
;; this: it kept running on the server the whole time, with all of its
;; state, which is exactly why reattaching is worth doing.

(defun jsonyter--short-id (kernel-id)
  "The leading 8 characters of KERNEL-ID, enough to tell kernels apart."
  (cond ((not (stringp kernel-id)) "?")
        ((> (length kernel-id) 8) (substring kernel-id 0 8))
        (t kernel-id)))

(defun jsonyter--check-jsonyter-buffer ()
  "Signal unless the current buffer is some kind of jsonyter buffer."
  (unless (bound-and-true-p jsonyter-mode)
    (user-error "jsonyter: not a jsonyter buffer — needs a REPL, a rendered .ipynb, or `jsonyter-script-mode'")))

(defun jsonyter--ensure-live-bridge ()
  "Make sure this jsonyter buffer has a live bridge process.

Starts one if the buffer never had one, and replaces one that has
exited — a bridge is a subprocess, and a broken pipe to the server can
leave Python far enough gone that it takes the process with it.  A
replacement process cannot answer requests the old one accepted, so the
callback table is emptied along with it rather than left holding
handlers that will never be called."
  (jsonyter--check-jsonyter-buffer)
  (unless jsonyter--callbacks
    (setq-local jsonyter--callbacks (make-hash-table :test #'eql)))
  (unless (process-live-p jsonyter--process)
    (jsonyter--kill-process)
    (clrhash jsonyter--callbacks)
    ;; A replacement bridge has none of the old one's kernel sockets, so
    ;; no execute of ours is in flight on any session any more.
    (dolist (session (jsonyter--session-list))
      (setf (jsonyter--session-busy session) nil))
    (setq jsonyter--process (jsonyter--start-bridge)))
  jsonyter--process)

(defun jsonyter--running-kernels ()
  "Kernels running on `jsonyter-server-url', most recently active first.
Each is a plist with at least :id, :name, :execution_state and
:last_activity."
  (sort (jsonyter--request-sync "list_kernels" nil)
        (lambda (a b)
          ;; The server's timestamps are fixed-layout UTC, so they sort
          ;; correctly as plain strings; reversed to put the kernel you
          ;; were most likely just using at the top of the list.
          (string< (or (plist-get b :last_activity) "")
                   (or (plist-get a :last_activity) "")))))

(defun jsonyter--kernel-activity (kernel)
  "KERNEL's `last_activity' as a local time, or the raw value it sent."
  (let ((stamp (plist-get kernel :last_activity)))
    (or (and stamp (ignore-errors
                     (format-time-string "%F %H:%M" (date-to-time stamp))))
        stamp
        "")))

(defun jsonyter--kernel-label (kernel current)
  "One completion line describing KERNEL, marked when its id is CURRENT."
  (format "%s %-16s %-8s  %-9s %s"
          (if (equal (plist-get kernel :id) current) "*" " ")
          (or (plist-get kernel :name) "?")
          (jsonyter--short-id (plist-get kernel :id))
          (or (plist-get kernel :execution_state) "?")
          (jsonyter--kernel-activity kernel)))

(defun jsonyter--read-kernel (prompt &optional current)
  "Read the id of a kernel running on the server, prompting with PROMPT.
CURRENT, an id, is marked with a `*' and offered as the default; it
defaults to the current session's kernel (or the one it last used), so
reattaching after a dropped connection is one RET."
  (let ((kernels (jsonyter--running-kernels)))
    (unless kernels
      (user-error "jsonyter: no kernels are running on %s" jsonyter-server-url))
    (let* ((current (or current
                        (jsonyter-current-kernel-id)
                        (let ((s (jsonyter--session)))
                          (and s (plist-get (jsonyter--session-last-kernel s) :id)))))
           (table (mapcar (lambda (kernel)
                            (cons (jsonyter--kernel-label kernel current)
                                  (plist-get kernel :id)))
                          kernels))
           (default (car (rassoc current table)))
           ;; The labels are padded columns, so completion has to match
           ;; on the whole line rather than on a prefix of it.
           (completion-styles (cons 'substring completion-styles))
           (choice (completing-read prompt table nil t nil nil default)))
      (or (cdr (assoc choice table))
          (user-error "jsonyter: no such kernel")))))

(defun jsonyter--kernelspec-language (name)
  "Declared language of kernel spec NAME, or nil if it cannot be resolved.
Best effort: a server that will not describe its kernelspecs is no
reason to refuse a connection to a kernel it is plainly running."
  (ignore-errors
    (let ((table (plist-get (jsonyter--request-sync "list_kernelspecs" nil)
                            :kernelspecs)))
      (cl-loop for (_key spec) on table by #'cddr
               when (equal (plist-get spec :name) name)
               return (plist-get (plist-get spec :spec) :language)))))

(defun jsonyter--adopt-kernel-language (session name)
  "Adopt kernel spec NAME's language into SESSION, reporting a change.
Returns a clause to append to the connection message when the session was
set up for a different language — attaching a Python script buffer to an
R kernel is a mistake worth seeing rather than a silent one — else nil."
  (let ((language (jsonyter--kernelspec-language name))
        (previous (jsonyter--session-language session)))
    (when language
      (setf (jsonyter--session-language session) language))
    (and language previous
         (not (string-equal (downcase previous) (downcase language)))
         (format " (note: this buffer was set up for %s, not %s)"
                 previous language))))

(defun jsonyter--attach-target ()
  "The session `jsonyter-kernel-connect' (re)binds here, made if it must."
  (or (jsonyter--session)
      (and jsonyter--session-key (jsonyter--session-put jsonyter--session-key))
      (and (derived-mode-p 'org-mode)
           (fboundp 'jsonyter--org-session-at-point)
           (or (jsonyter--org-session-at-point 'noerror)
               (and (fboundp 'jsonyter--org-ensure-session-at-point)
                    (jsonyter--org-ensure-session-at-point 'no-kernel))))
      (user-error "jsonyter: nowhere to attach a kernel here")))

(defun jsonyter-kernel-connect (kernel-id &optional session)
  "Attach SESSION (default the one in play) to KERNEL-ID, running on the server.

Works in any jsonyter buffer — a REPL, a rendered .ipynb, a script with
`jsonyter-script-mode' on, or an Org buffer — and replaces whatever
kernel that session was talking to.  Called interactively, offers the
kernels `jsonyter-server-url' currently reports, most recently active
first, with this session's own kernel marked `*' and offered as the
default.

Two quite different jobs, both of which come down to the same steps:

  - Recovering a connection that broke.  Give it the kernel this buffer
    already has (which is all `jsonyter-kernel-reconnect' does) and the
    kernel keeps running with every variable it had; only the socket is
    rebuilt.  Nothing is lost but output that was in flight.
  - Borrowing someone else\\='s kernel — running a script\\='s cells against
    the kernel a notebook already has warm, say, so both see the same
    variables.

Requests still outstanding are abandoned: after a broken pipe their
replies are never coming, and a reply to a request issued against the
old socket would be meaningless against the new one anyway.  A REPL gets
a fresh prompt for that reason.  Its number may be behind what the
kernel actually counts, since the kernel kept running while we were
away; it resyncs on the next execution.

A kernel attached to this way is not shut down when the buffer is
killed, however `jsonyter-shutdown-on-kill' is set — it is not this
buffer\\='s to end.  Nor does attaching elsewhere disown the kernel this
buffer started, if it started one: that one stays its responsibility,
and stays what gets shut down when the buffer dies.

Returns KERNEL-ID."
  (interactive
   (list (progn (jsonyter--ensure-live-bridge)
                (jsonyter--read-kernel "Connect to kernel: "))))
  (jsonyter--ensure-live-bridge)
  (let* ((session (or session (jsonyter--attach-target)))
         (same (equal kernel-id (jsonyter--session-kernel-id session)))
         ;; Ask about the kernel before disturbing anything: if it is
         ;; gone from the server there is nothing to attach to, and the
         ;; session should be left exactly as it was.
         (kernel (condition-case err
                     (jsonyter--request-sync "get_kernel"
                                             (list :kernel_id kernel-id))
                   (error
                    (user-error "jsonyter: cannot attach to kernel %s on %s — %s"
                                (jsonyter--short-id kernel-id)
                                jsonyter-server-url
                                (error-message-string err)))))
         (name (plist-get kernel :name)))
    ;; Nothing pending can be answered across a new socket.
    (clrhash jsonyter--callbacks)
    (setf (jsonyter--session-busy session) nil)
    (setq jsonyter--clear-pending nil
          jsonyter--is-complete-failures 0)
    ;; The whole point (see the commentary above): close the old socket
    ;; before opening a new one, because a half-open one will happily
    ;; claim it is still connected and be reused.  Harmless when there
    ;; is nothing to close, which is the case on a fresh bridge.
    (ignore-errors
      (jsonyter--request-sync "disconnect" (list :kernel_id kernel-id)))
    (setq jsonyter--url jsonyter-server-url)
    (setf (jsonyter--session-kernel-id session) kernel-id
          (jsonyter--session-kernel-name session) name
          (jsonyter--session-state session) (plist-get kernel :execution_state)
          ;; `own' is deliberately untouched: attaching to a kernel never
          ;; makes it ours, and wandering off to one never stops the
          ;; kernel we started from being.
          (jsonyter--session-last-kernel session) (list :id kernel-id :name name))
    (jsonyter--subscribe session)
    ;; A socket opened moments ago has not seen a status message yet, so
    ;; `subscribe' can legitimately report no state at all; the REST
    ;; call above knows what the server thinks.
    (unless (jsonyter--session-state session)
      (setf (jsonyter--session-state session)
            (plist-get kernel :execution_state)))
    (let ((mismatch (jsonyter--adopt-kernel-language session name))
          (verb (if same "reconnected to" "connected to")))
      (force-mode-line-update)
      (when (derived-mode-p 'jsonyter-repl-mode)
        (jsonyter--note (format "\n[%s kernel %s (%s) on %s]"
                                verb name (jsonyter--short-id kernel-id)
                                jsonyter--url))
        (jsonyter--insert-prompt))
      (message "jsonyter: %s kernel %s (%s) on %s%s"
               verb name (jsonyter--short-id kernel-id) jsonyter--url
               (or mismatch "")))
    kernel-id))

(defun jsonyter-kernel-reconnect ()
  "Reconnect this buffer to the kernel it was last using.

The command for a REPL that has gone quiet because the network dropped
or the machine slept: the kernel is still on the server with all of its
state, and only the connection to it needs rebuilding.  Equivalent to
`jsonyter-kernel-connect' on this buffer\\='s own kernel, which is where
the details are; use that one to pick a different kernel."
  (interactive)
  (jsonyter--check-jsonyter-buffer)
  (let* ((session (jsonyter--command-session))
         (kernel-id (or (jsonyter--session-kernel-id session)
                        (plist-get (jsonyter--session-last-kernel session) :id))))
    (unless kernel-id
      (user-error "jsonyter: this session has no kernel to reconnect to (M-x jsonyter-kernel-connect to pick one)"))
    (jsonyter-kernel-connect kernel-id session)))

(defun jsonyter--history-input (entry)
  "Input text of one `history' reply ENTRY, or nil if it carries none.
An entry is (SESSION LINE INPUT).  When a client asks for outputs too —
which jsonyter.el never does, but another front end sharing the kernel
may have — INPUT is instead a pair of the input and its output; take the
input either way."
  (let ((input (nth 2 entry)))
    (cond ((stringp input) input)
          ((and (consp input) (stringp (car input))) (car input))
          (t nil))))

(defun jsonyter--history-insert (entries)
  "Insert history ENTRIES into the current buffer as a transcript.
ENTRIES are `history_reply' triples, oldest first, and stay in that
order: history reads like a transcript, so the newest command belongs at
the bottom where the eye finishes.  Line numbers restart with every
session in the kernel\\='s history store, and that store can span kernels
as well as restarts (see `jsonyter-kernel-history'), so each session
gets a rule of its own — without one a tail reads as several In [1]s
with no hint of why, or whose."
  (let ((session 'jsonyter--none))
    (dolist (entry entries)
      (let ((input (jsonyter--history-input entry)))
        (when input
          (unless (equal (nth 0 entry) session)
            (let* ((first (eq session 'jsonyter--none))
                   (label (format "session %s " (setq session (nth 0 entry))))
                   (rule (make-string (max 4 (- jsonyter-notebook-separator-width
                                                (length label)))
                                      ?─)))
              ;; A blank line separates sessions; there is nothing to
              ;; separate the first one from but the header.
              (unless first (insert "\n"))
              (insert (propertize (concat label rule "\n")
                                  'face 'jsonyter-note-face))))
          (let ((label (format "In [%s]: " (nth 1 entry))))
            (insert (propertize label 'face 'jsonyter-prompt-face)
                    ;; Continuation lines line up under the first, so a
                    ;; multi-line cell reads as one block.
                    (string-join (split-string input "\n")
                                 (concat "\n" (make-string (length label) ?\s)))
                    "\n")))))))

(defun jsonyter-kernel-history (&optional n kernel-id)
  "Show the N commands most recently run by KERNEL-ID.

Asks the kernel for its own history, which is a different thing from
this Emacs session\\='s input ring — what \\[jsonyter-repl-previous-input]
walks.  It is how to see what a REPL whose transcript you have lost
actually ran, and what a kernel you are thinking of attaching to has
been used for.

How far back that history reaches, and whose commands are in it, is the
kernel\\='s business rather than ours — and IPython\\='s in particular reaches
wider than the one kernel you asked.  Its history is a single SQLite
database per profile, shared by every kernel using that profile, so a
tail of it can hand back commands run by a different kernel entirely: a
freshly started kernel that has executed nothing at all still answers
with the last things its neighbours ran.  Entries are grouped and
labelled by session for that reason, and the numbering restarts with
each — the session is what separates one kernel\\='s run from another\\='s.

Interactively, N defaults to `jsonyter-kernel-history-count' and the
kernel is this buffer\\='s own.  A numeric prefix argument sets N
\\(\\[universal-argument] 100 asks for a hundred).  A bare
\\[universal-argument] prompts for both, which is how to read the history
of a kernel this buffer is not attached to; a buffer with no kernel of
its own prompts for one too.

Called from Lisp, both arguments are plain: N is a count and KERNEL-ID
an id as `jsonyter--running-kernels' reports it.  Either way this must
run in a jsonyter buffer, whose bridge process does the asking.

Not every kernel implements history — SAS, for one, never answers — so
this can time out where a REPL against the same kernel works fine."
  (interactive
   (let* ((arg current-prefix-arg)
          ;; Whether we know of a kernel, not whether the bridge is up:
          ;; a buffer reaching for its history after the pipe broke wants
          ;; its own kernel, not a prompt.
          (choose (or (consp arg) (null (jsonyter-current-kernel-id))))
          (n (cond ((consp arg)
                    (read-number "Number of commands: "
                                 jsonyter-kernel-history-count))
                   (arg (prefix-numeric-value arg))
                   (t jsonyter-kernel-history-count))))
     (jsonyter--ensure-live-bridge)
     (list n (if choose
                 (jsonyter--read-kernel "History of kernel: ")
               (jsonyter-current-kernel-id)))))
  (jsonyter--ensure-live-bridge)
  (let ((n (or n jsonyter-kernel-history-count))
        (kernel-id (or kernel-id (jsonyter-current-kernel-id))))
    (unless kernel-id
      (user-error "jsonyter: no kernel to show the history of"))
    (unless (and (integerp n) (> n 0))
      (user-error "jsonyter: number of commands must be a positive integer, not %S" n))
    (let* ((ours (equal kernel-id (jsonyter-current-kernel-id)))
           ;; Names the kernel for the header, and — the reason it comes
           ;; first — says plainly that a kernel is gone, rather than
           ;; leaving that to a socket that fails for its own reasons.
           (kernel (condition-case err
                       (jsonyter--request-sync "get_kernel"
                                               (list :kernel_id kernel-id))
                     (error
                      (user-error "jsonyter: cannot reach kernel %s on %s — %s"
                                  (jsonyter--short-id kernel-id)
                                  jsonyter-server-url
                                  (error-message-string err)))))
           (reply
            (unwind-protect
                (condition-case err
                    (jsonyter--kernel-request "history"
                                              (list :kernel_id kernel-id :n n))
                  (error
                   (user-error "jsonyter: kernel %s gave no history — %s"
                               (jsonyter--short-id kernel-id)
                               (error-message-string err))))
              ;; Asking opens a socket to the kernel; keep one only to a
              ;; kernel this buffer is actually working with.
              (unless ours
                (ignore-errors
                  (jsonyter--request-sync "disconnect"
                                          (list :kernel_id kernel-id))))))
           (status (plist-get reply :status))
           (entries (plist-get reply :history)))
      ;; Kernels that report a status and mean it get taken at their word;
      ;; ones that omit it are judged on whether they sent any history.
      (when (and status (not (equal status "ok")))
        (error "jsonyter: kernel %s refused the history request (%s)"
               (jsonyter--short-id kernel-id) status))
      (if (null entries)
          (message "jsonyter: kernel %s has run nothing yet"
                   (jsonyter--short-id kernel-id))
        (let ((name (or (plist-get kernel :name) "?"))
              (url (if ours (or jsonyter--url jsonyter-server-url)
                     jsonyter-server-url))
              (shown (length entries)))
          (with-help-window "*jsonyter-history*"
            (with-current-buffer standard-output
              (insert (propertize
                       (format "Last %d command%s in the history of kernel %s (%s) on %s%s\n\n"
                               shown (if (= shown 1) "" "s")
                               name (jsonyter--short-id kernel-id) url
                               (if (< shown n) " — all it has" ""))
                       'face 'jsonyter-note-face))
              (jsonyter--history-insert entries))))))))

;;;; Starting REPLs

(defun jsonyter--connect-kernel (key &optional kernel-name)
  "Ensure session KEY in this buffer has a running kernel; return the session.

KEY is (LANGUAGE . NAME).  Idempotent: a session that already has a live
kernel is returned untouched, so this doubles as \"get or start\".
KERNEL-NAME pins the kernelspec, overriding language-based resolution and
any name the session was last bound to.

The buffer's one bridge process is started on first use and reused for
every later kernel.  Every step is awaited in turn: the bridge opens one
websocket per kernel, and issuing two connection-opening requests
concurrently is a race that older bridges lose.

REPL, notebook and script buffers also point `jsonyter--session-key' at
KEY, so their single-kernel commands find it as \"the current session\";
an Org buffer leaves that pointer alone."
  (setq jsonyter--url jsonyter-server-url)
  (jsonyter--ensure-live-bridge)
  (let ((session (jsonyter--session-put key)))
    (unless (derived-mode-p 'org-mode)
      (setq jsonyter--session-key key))
    (when kernel-name
      (setf (jsonyter--session-kernel-name session) kernel-name))
    (unless (jsonyter--live-p session)
      (let* ((name (or kernel-name
                       (jsonyter--session-kernel-name session)
                       (jsonyter--resolve-kernel-name
                        (jsonyter--session-language session))))
             (kernel (jsonyter--request-sync "start_kernel" (list :name name)
                                             jsonyter-startup-timeout))
             (id (plist-get kernel :id)))
        (setf (jsonyter--session-kernel-id session) id
              (jsonyter--session-kernel-name session) (plist-get kernel :name)
              (jsonyter--session-state session) (plist-get kernel :execution_state)
              ;; We started it, so it is ours to shut down again; see
              ;; `jsonyter--cleanup'.
              (jsonyter--session-own session) id
              (jsonyter--session-last-kernel session)
              (list :id id :name (plist-get kernel :name)))
        (jsonyter--subscribe session)))
    session))

(defun jsonyter--start-repl (language)
  "Start (or pop to) a Jupyter REPL for LANGUAGE."
  (let* ((bufname (format "*jsonyter[%s]*" language))
         (existing (get-buffer bufname)))
    (if (and existing
             (buffer-local-value 'jsonyter--session-key existing)
             (process-live-p (buffer-local-value 'jsonyter--process existing)))
        (pop-to-buffer existing)
      (when existing (kill-buffer existing))
      (let ((buffer (get-buffer-create bufname)))
        (condition-case err
            (with-current-buffer buffer
              (jsonyter-repl-mode)
              (let ((session (jsonyter--connect-kernel (cons language ""))))
                (jsonyter--note
                 (format (concat "Jupyter REPL — kernel %s (%s) on %s\n"
                                 "RET send · TAB complete · C-c C-c interrupt · "
                                 "C-c C-r restart · C-c C-l reconnect · "
                                 "C-c C-d doc · M-p/M-n history")
                         (jsonyter--session-kernel-name session)
                         (jsonyter--short-id (jsonyter--session-kernel-id session))
                         jsonyter--url)))
              (jsonyter--insert-prompt)
              (pop-to-buffer buffer))
          (error
           (with-current-buffer buffer (jsonyter--kill-process))
           (kill-buffer buffer)
           (signal (car err) (cdr err))))))))

;;;###autoload
(defun jsonyter-start (language)
  "Start an interactive Jupyter REPL for LANGUAGE on the configured server.
LANGUAGE is a language name such as \"python\", \"julia\", \"R\" or
\"sas\", matched against the server's kernelspecs (see also
`jsonyter-kernel-names')."
  (interactive (list (read-string "Kernel language: " nil nil "python")))
  (jsonyter--start-repl language))

;;;###autoload
(defun jsonyter-start-python ()
  "Start an interactive Jupyter Python REPL."
  (interactive)
  (jsonyter--start-repl "python"))

;;;###autoload
(defun jsonyter-start-julia ()
  "Start an interactive Jupyter Julia REPL."
  (interactive)
  (jsonyter--start-repl "julia"))

;;;###autoload
(defun jsonyter-start-R ()
  "Start an interactive Jupyter R REPL."
  (interactive)
  (jsonyter--start-repl "R"))

;;;###autoload
(defun jsonyter-start-SAS ()
  "Start an interactive Jupyter SAS REPL."
  (interactive)
  (jsonyter--start-repl "sas"))

;;;###autoload
(defalias 'jsonyter-start-r #'jsonyter-start-R)
;;;###autoload
(defalias 'jsonyter-start-sas #'jsonyter-start-SAS)


;;;; Notebooks (.ipynb)

;; A notebook buffer holds the cells' source text and, after each
;; cell's source, that cell's rendered output.  Prompts and separators
;; are overlay strings; output is not, because point cannot be put
;; inside an overlay string — a plot taller than the window could then
;; never be scrolled through, only stepped over in one jump.
;;
;; What the overlay string gave outputs for free, buffer text has to be
;; given deliberately.  Output is written under
;; `with-silent-modifications', so it stays out of the undo history and
;; out of the buffer's modified flag; it is `read-only', so no edit can
;; corrupt it; and `jsonyter--nb-fontify-region' and
;; `jsonyter--nb-unfontify-region' keep the language's font-lock off it
;; in both directions.  Undo still walks your edits and never your
;; results.
;;
;; Each cell overlay therefore spans two regions, told apart by its
;; `jsonyter-source-end' marker: the source, which is the document, and
;; the output, which is a result.  Everything that saves, hashes or
;; executes a cell reads only the first — see `jsonyter--nb-cell-source'.
;;
;; The mode is a *minor* mode layered on the notebook language's own
;; major mode, so syntax highlighting, indentation and completion come
;; from python-mode/ess-r-mode/etc. for free.

(defcustom jsonyter-notebook-language-modes
  '(("python" . python-mode)
    ("r" . ess-r-mode)
    ("julia" . julia-mode)
    ("sas" . SAS-mode))
  "Alist mapping a notebook language to the major mode to edit it in.
Entries whose mode is not available fall back to `prog-mode'."
  :type '(alist :key-type string :value-type function))

(defcustom jsonyter-notebook-auto-start-kernel t
  "If non-nil, start a kernel on the first cell execution in a notebook.
With nil, `jsonyter-notebook-start-kernel' must be called explicitly."
  :type 'boolean)

(defface jsonyter-notebook-cell-face
  '((t :inherit jsonyter-prompt-face))
  "Face for a notebook cell's prompt line.")

(defface jsonyter-notebook-markdown-face
  '((t :inherit font-lock-doc-face))
  "Face for the prompt line of a markdown cell.")

(defface jsonyter-notebook-rule-face
  '((t :inherit shadow))
  "Face for the rule drawn beside a cell prompt.")

(defface jsonyter-code-cell-face
  '((t :inherit jsonyter-notebook-cell-face))
  "Face for the boundary label of a code cell.")

(defface jsonyter-markdown-cell-face
  '((t :inherit jsonyter-notebook-markdown-face))
  "Face for the boundary label of a markdown cell.")

(defface jsonyter-raw-cell-face
  '((t :inherit shadow :weight bold))
  "Face for the boundary label of a raw cell.")

(defface jsonyter-output-border-face
  '((t :inherit jsonyter-notebook-rule-face))
  "Face for the rules framing a cell's rendered output.")

(defface jsonyter-output-border-stale-face
  '((t :inherit warning))
  "Face for the output frame of a cell edited since its output was made.
Flags output that may no longer match the cell's current source; the
frame reverts to `jsonyter-output-border-face' when the cell is re-run
\(or the edit is undone).")

(defvar-local jsonyter--nb-lang nil
  "The notebook's declared kernel language, from its metadata.
Set at open time, before any kernel exists, so a cell's prompt can name
the language from the start; the session's own `language' slot is the
live truth once a kernel is running.")
(defvar-local jsonyter--nb-metadata nil
  "The notebook's top-level metadata plist, as read from the file.")
(defvar-local jsonyter--nb-format nil
  "Cons of (NBFORMAT . NBFORMAT-MINOR) as read from the file.")
(defvar-local jsonyter--nb-running-cell nil
  "Overlay of the cell currently executing, if any.")

(defun jsonyter--undo-entry-before-p (entry position)
  "Non-nil if ENTRY of `buffer-undo-list' names no position at or past POSITION.
Entries naming no buffer position at all — an undo boundary, a
modification-time stamp, a marker adjustment — qualify trivially.  An
entry whose positions cannot be read, which is any `apply' form that
does not declare its range, does not: it cannot be shown to be safe."
  (pcase entry
    ('nil t)                                       ; boundary
    (`(t . ,_) t)                                  ; visited-file modtime
    ((pred integerp) (< entry position))           ; point was here
    (`(,(pred markerp) . ,_) t)                    ; marker adjustment
    (`(apply ,(pred integerp) ,beg ,end . ,_)      ; change with a range
     (and (< beg position) (< end position)))
    (`(nil ,_ ,_ ,beg . ,end)                      ; text-property change
     (and (< beg position) (< end position)))
    (`(,(and beg (pred integerp)) . ,(and end (pred integerp)))
     (and (< beg position) (< end position)))      ; text inserted
    (`(,(pred stringp) . ,(and pos (pred integerp)))
     (< (abs pos) position))                       ; text deleted
    (_ nil)))

(defun jsonyter--forget-undo-after (position)
  "Drop undo entries that refer to buffer text at or after POSITION.

A cell's output is written into the buffer without being recorded in the
undo history (see `jsonyter--nb-show-output-as-text'), so text after it
shifts without undo noticing.  Entries recorded before that shift which
point past POSITION would then be replayed against text that has moved —
rewriting some unrelated cell, silently.  Dropping them is the cost of
keeping results out of the history.

`buffer-undo-list' is replayed newest first, and an entry may only be
undone once every entry before it has been, so the list is cut at the
first unsafe entry rather than having that entry picked out of it.  Edits
to a cell all sit before its own output, so editing a cell and then
running it — the usual way round — loses nothing."
  (unless (eq buffer-undo-list t)
    (setq buffer-undo-list
          (seq-take-while (lambda (entry)
                            (jsonyter--undo-entry-before-p entry position))
                          buffer-undo-list))))

(defvar jsonyter--nb-cell-surgery nil
  "Non-nil while a cell command is rearranging buffer text.
The staleness tracker (`jsonyter--nb-stale-after-change') stands down
while this is bound: mid-surgery the text and the overlays are
transiently inconsistent — a neighbour's overlay can momentarily hold
text that is not its own — and a staleness verdict taken then would
stick after the command has put everything back.")

;;; Reading the file

(defun jsonyter--nb-text (value)
  "Normalize nbformat VALUE to a string.
nbformat stores `source' and stream `text' as either a string or a list
of lines depending on who wrote the file; both must read the same."
  (cond ((null value) "")
        ((stringp value) value)
        ((listp value) (mapconcat #'identity value ""))
        (t (format "%s" value))))

(defun jsonyter--nb-parse (&optional buffer)
  "Parse BUFFER (default current) as notebook JSON, returning a plist."
  (with-current-buffer (or buffer (current-buffer))
    (save-excursion
      (goto-char (point-min))
      (json-parse-buffer :object-type 'plist :array-type 'list
                         :null-object nil :false-object nil))))

(defun jsonyter--nb-language (notebook)
  "Return the language name declared by NOTEBOOK, defaulting to python."
  (let* ((md (plist-get notebook :metadata))
         (spec (plist-get md :kernelspec))
         (info (plist-get md :language_info)))
    (or (plist-get spec :language)
        (plist-get info :name)
        ;; kernelspec names are conventionally the kernel, not the
        ;; language, but they are the last hint available.
        (plist-get spec :name)
        "python")))

(defun jsonyter--nb-major-mode (language)
  "Major mode to use for LANGUAGE, or `prog-mode' if none is available."
  (let ((mode (cdr (assoc-string language jsonyter-notebook-language-modes t))))
    (if (and mode (fboundp mode)) mode #'prog-mode)))

;;; Rendering outputs into overlay strings

(defun jsonyter--nb-adapt-output (output)
  "Adapt one nbformat OUTPUT plist to the shape the renderer expects.
nbformat says `output_type' where the kernel protocol says `type', and
stores stream text as a list of lines."
  (let ((type (plist-get output :output_type)))
    (append
     (list :type type)
     (pcase type
       ("stream" (list :name (plist-get output :name)
                       :text (jsonyter--nb-text (plist-get output :text))))
       ((or "display_data" "execute_result" "update_display_data")
        (list :data (plist-get output :data)
              :metadata (plist-get output :metadata)
              :execution_count (plist-get output :execution_count)))
       ("error" (list :ename (plist-get output :ename)
                      :evalue (plist-get output :evalue)
                      :traceback (plist-get output :traceback)))
       (_ nil)))))

(defun jsonyter--nb-render-string (output &optional overlay-string)
  "Render one OUTPUT (already in kernel shape) to a propertized string.
Rendering happens in a scratch buffer so the existing output renderer —
images, sliced scrolling, ANSI, shr — can be reused verbatim; the
resulting text, display properties and all, is then either written into
the buffer (a notebook cell) or hung off an overlay (a script cell).

With OVERLAY-STRING the renderer is told it is working for a string
rather than for buffer text (see `jsonyter--string-output'), which is
what keeps it from slicing images across lines that an overlay string
does not have.  Only script cells pass it."
  (let ((jsonyter--string-output overlay-string)
        ;; Rendering happens over there but the text lands back here, so
        ;; the scratch buffer is told what leading this one draws: a
        ;; fresh buffer would report the global `line-spacing' and
        ;; `jsonyter--image-rows' would judge slicing by a line grid
        ;; that is not the one the slices end up on.
        (spacing line-spacing))
    (with-temp-buffer
      (setq-local line-spacing spacing)
      (setq-local jsonyter--clear-pending nil)
      (setq-local jsonyter--output-start (copy-marker (point-min)))
      (setq-local jsonyter--output-end (copy-marker (point-max) t))
      (condition-case err
          (jsonyter--render-output output)
        (error (insert (format "[jsonyter: cannot render %s output: %s]\n"
                               (plist-get output :type)
                               (error-message-string err)))))
      (buffer-string))))

(defun jsonyter--nb-outputs-string (rendered &optional stale)
  "Wrap RENDERED output text for display beneath a cell.
The block is framed above and below by a rule, so where a cell's code
ends and its output begins is visible at a glance however long the
output runs.  With STALE the frame takes
`jsonyter-output-border-stale-face' and says so in its label: the
cell's source has been edited since this output was produced, so the
two may no longer correspond.  A cell with no output gets no frame.

The block carries no read-only protection of its own: as an overlay
string there is nothing to protect, and as buffer text the whole span
— frame included — is made read-only where it is inserted, by
`jsonyter--nb-show-output-as-text'."
  (if (or (null rendered) (string-empty-p rendered))
      ""
    (let* ((face (if stale 'jsonyter-output-border-stale-face
                   'jsonyter-output-border-face))
           (label (if stale "output (stale)" "output"))
           (help (and stale
                      "Source edited since this output was produced — re-run the cell to refresh it"))
           (rule (make-string (max 4 (- jsonyter-notebook-separator-width
                                        (1+ (length label))))
                              ?─)))
      (concat
       (propertize (concat label " " rule "\n") 'face face 'help-echo help)
       rendered
       (if (string-suffix-p "\n" rendered) "" "\n")
       (propertize
        (concat (make-string jsonyter-notebook-separator-width ?─) "\n")
        'face face 'help-echo help)))))

;;; Cell overlays

(defun jsonyter--nb-cell-type-face (cell-type)
  "Face for the boundary label of a CELL-TYPE cell."
  (pcase cell-type
    ("markdown" 'jsonyter-markdown-cell-face)
    ("raw" 'jsonyter-raw-cell-face)
    (_ 'jsonyter-code-cell-face)))

(defun jsonyter--nb-prompt (cell-type exec-count &optional running)
  "Prompt string shown above a cell of CELL-TYPE with EXEC-COUNT.
RUNNING marks a cell whose execution is still in flight.

The line is the cell's visible boundary: it names the cell's type —
and, for a code cell, the notebook's kernel language — and its label
takes that type's own face (`jsonyter-code-cell-face',
`jsonyter-markdown-cell-face', `jsonyter-raw-cell-face'), so adjacent
cells of different kinds are tellable apart at a glance."
  (let* ((label (pcase cell-type
                  ("markdown" "Markdown")
                  ("raw" "Raw")
                  (_ (concat (if running "In [*]:"
                               (format "In [%s]:" (or exec-count " ")))
                             " code"
                             (and jsonyter--nb-lang
                                  (format " (%s)" jsonyter--nb-lang))))))
         (rule (make-string (max 4 (- jsonyter-notebook-separator-width
                                      (length label)))
                            ?─)))
    (concat "\n"
            (propertize label 'face (jsonyter--nb-cell-type-face cell-type))
            " "
            (propertize rule 'face 'jsonyter-notebook-rule-face)
            "\n")))

(defun jsonyter--nb-refresh-prompt (cell)
  "Update CELL's prompt overlay string from its stored state."
  (overlay-put cell 'before-string
               (jsonyter--nb-prompt (overlay-get cell 'jsonyter-cell-type)
                                    (overlay-get cell 'jsonyter-exec-count)
                                    (overlay-get cell 'jsonyter-running))))

(defun jsonyter--overlay-string-cell-p (cell)
  "Non-nil if CELL shows its output in an overlay string, not buffer text.
True for a `# %%' script cell and for an Org src block: in both the
buffer's text is a file the user saves, so nothing may be written into
it.  A rendered notebook buffer is a view, so its cell output is real
buffer text instead — which is what lets a tall sliced image be scrolled
through a line at a time."
  (or (overlay-get cell 'jsonyter-script-cell)
      (overlay-get cell 'jsonyter-org-cell)))

(defun jsonyter--nb-refresh-output (cell)
  "Update CELL's shown output from its stored rendered text.

Where the output goes depends on what the buffer's text is; see
`jsonyter--overlay-string-cell-p'."
  (if (jsonyter--overlay-string-cell-p cell)
      (jsonyter--nb-show-output-as-string cell)
    (jsonyter--nb-show-output-as-text cell)))

(defun jsonyter--nb-show-output-as-string (cell)
  "Hang CELL's rendered output off its overlay as an `after-string'."
  (let ((body (jsonyter--nb-outputs-string
               (overlay-get cell 'jsonyter-output-string)
               (overlay-get cell 'jsonyter-output-stale))))
    (overlay-put
     cell 'after-string
     (if (string-empty-p body)
         ""
       ;; Output must begin on a line of its own.  A script cell can end
       ;; mid-line — the last cell of a file with no final newline — and
       ;; an after-string there is displayed running on from the last
       ;; line of code, which is exactly where print output must not
       ;; appear.
       (let ((end (overlay-end cell)))
         (if (or (= end (point-min)) (eq (char-before end) ?\n))
             body
           (concat "\n" body)))))))

(defun jsonyter--nb-show-output-as-text (cell)
  "Rewrite CELL's output region in the buffer from its rendered text.

CELL spans its source and then its output; the boundary between the two
is its `jsonyter-source-end' marker, and everything from there to the
overlay's end is output, replaced wholesale here.  The marker's
insertion type is nil, so text inserted at the boundary — this
function's own — falls on the output side of it and never silently joins
the cell's source.

The block is made `read-only', front-sticky so nothing can be typed into
it and rear-nonsticky so the next cell's source can still begin directly
after it.  Selecting and copying it are unaffected.

`with-silent-modifications' keeps the rewrite out of the undo history
and out of the buffer's modified flag — output is a result, not part of
the document, exactly as it was when it lived in an overlay string — and
stands `after-change-functions' down for the same reason
`jsonyter--nb-cell-surgery' does."
  (let* ((body (jsonyter--nb-outputs-string
                (overlay-get cell 'jsonyter-output-string)
                (overlay-get cell 'jsonyter-output-stale)))
         (src-end (marker-position (overlay-get cell 'jsonyter-source-end)))
         (out-end (overlay-end cell))
         ;; A cell beginning where this one's output ends collapses onto
         ;; the insertion point when the old output is deleted, and
         ;; `make-overlay's FRONT-ADVANCE being nil would then let it
         ;; swallow the replacement whole — the same hazard
         ;; `jsonyter--nb-insert-cell' guards against at its own end.
         (adjacent (seq-filter (lambda (o)
                                 (and (overlay-get o 'jsonyter-cell)
                                      (= (overlay-start o) out-end)))
                               (overlays-at out-end)))
         (new-end
          (let ((jsonyter--nb-cell-surgery t))
            (with-silent-modifications
              (save-excursion
                (delete-region src-end out-end)
                (goto-char src-end)
                (unless (string-empty-p body)
                  ;; Output must begin on a line of its own.  A notebook
                  ;; cell owns its trailing newline, so this only fires
                  ;; for a cell whose own has been edited away; the
                  ;; newline stays outside the read-only span so that
                  ;; typing at the end of that line still works.
                  (unless (bolp) (insert "\n"))
                  (let ((start (point)))
                    (insert body)
                    (add-text-properties
                     start (point)
                     '(read-only t front-sticky (read-only) rear-nonsticky t))))
                (dolist (o adjacent) (move-overlay o (point) (overlay-end o)))
                (move-overlay cell (overlay-start cell) (point))
                (point))))))
    (unless (= new-end out-end)
      (jsonyter--forget-undo-after src-end))))

(defun jsonyter--nb-make-cell (start end cell)
  "Create the overlay for CELL whose source spans START..END.
Returns the overlay, which by the time this returns reaches past END:
the cell's rendered output is buffer text written in after its source,
and the overlay covers both.  `jsonyter-source-end' marks the boundary,
and is what tells the cell's source from its results ever after — see
`jsonyter--nb-cell-source'.

Rear-advance is deliberately off: cells are laid down back to back, so
an overlay that grew at its end would swallow every cell rendered after
it.  A cell's trailing newline is inside the overlay, so typing at the
end of its last visible line still lands in the right cell."
  (let ((ov (make-overlay start end)))
    (overlay-put ov 'jsonyter-cell t)
    (overlay-put ov 'jsonyter-cell-id (plist-get cell :id))
    (overlay-put ov 'jsonyter-cell-type (plist-get cell :cell_type))
    (overlay-put ov 'jsonyter-exec-count (plist-get cell :execution_count))
    (overlay-put ov 'evaporate nil)
    ;; Insertion type nil: output written at the boundary stays on the
    ;; output side of it.  With the marker advancing instead, the very
    ;; first refresh would sweep the whole rendered block into what the
    ;; cell calls its source, and the next save would write it to disk.
    (overlay-put ov 'jsonyter-source-end (copy-marker end))
    (jsonyter--nb-refresh-prompt ov)
    (let ((rendered (mapconcat (lambda (o)
                                 (jsonyter--nb-render-string
                                  (jsonyter--nb-adapt-output o)))
                               (plist-get cell :outputs) "")))
      (overlay-put ov 'jsonyter-output-string rendered)
      (jsonyter--nb-refresh-output ov))
    ;; The outputs on display were produced by the source as it reads
    ;; right now; record that pairing so later edits can be flagged as
    ;; making the output stale.
    (overlay-put ov 'jsonyter-source-hash
                 (jsonyter--source-hash (jsonyter--nb-cell-source ov)))
    ov))

(defun jsonyter--nb-cells ()
  "All cell overlays in this buffer, in document order."
  (sort (seq-filter (lambda (o) (overlay-get o 'jsonyter-cell))
                    (overlays-in (point-min) (point-max)))
        (lambda (a b) (< (overlay-start a) (overlay-start b)))))

(defun jsonyter--nb-cell-at (&optional pos)
  "The cell overlay containing POS (default point), or nil."
  (let* ((pos (or pos (point)))
         (cell-p (lambda (o) (overlay-get o 'jsonyter-cell))))
    (or (seq-find cell-p (overlays-at pos))
        ;; Point at end-of-buffer sits just past the last cell's final
        ;; newline; only fall back there, never in preference to a cell
        ;; that genuinely covers POS.
        (and (> pos (point-min))
             (seq-find cell-p (overlays-at (1- pos)))))))

(defun jsonyter--nb-cell-source (cell)
  "The source text of CELL, without its trailing newline.

A cell's overlay spans its source and then its rendered output, so only
the text before `jsonyter-source-end' is source.  Reading to the
overlay's end instead would call the output source too — and this is
what `jsonyter--nb-collect-cells' writes back to the `.ipynb' file, so
every save after a run would append that run's frame rules, resolved
ANSI text and image placeholder characters to the cell's own code."
  (let ((text (buffer-substring-no-properties
               (overlay-start cell)
               (or (overlay-get cell 'jsonyter-source-end)
                   (overlay-end cell)))))
    (if (string-suffix-p "\n" text) (substring text 0 -1) text)))

;;; Staleness of shown output

;; An output on display was produced by the cell's source as it read at
;; run time (or as it was saved in the file).  That pairing is recorded
;; as a hash on the overlay, and an after-change hook compares it with
;; the live source, so an edited cell's output frame flips to
;; `jsonyter-output-border-stale-face' the moment the two part ways —
;; and back again if the edit is undone.  Only a change of verdict
;; re-renders the frame; every other keystroke costs one hash of that
;; one cell's source, so large outputs add nothing to typing latency.

(defun jsonyter--nb-output-spans (beg end)
  "Rendered-output spans overlapping BEG..END, in buffer order.
Each is a cons of the position its output starts at and the one just
past its end; a cell showing no output contributes none."
  (sort (delq nil
              (mapcar
               (lambda (o)
                 (let ((source-end (and (overlay-get o 'jsonyter-cell)
                                        (overlay-get o 'jsonyter-source-end))))
                   (and source-end
                        (< (marker-position source-end) (overlay-end o))
                        (cons (marker-position source-end) (overlay-end o)))))
               (overlays-in beg end)))
        #'car-less-than-car))

(defun jsonyter--nb-map-source-runs (beg end fn)
  "Call FN with the bounds of each run of source text between BEG and END.
The rendered output spans in between are skipped."
  (let ((pos beg))
    (dolist (span (jsonyter--nb-output-spans beg end))
      (when (< pos (car span))
        (funcall fn pos (min end (car span))))
      (setq pos (max pos (min end (cdr span)))))
    (when (< pos end)
      (funcall fn pos end))))

(defun jsonyter--nb-fontify-region (beg end loudly)
  "Fontify BEG..END as source, leaving rendered cell output alone.
LOUDLY is passed through to `font-lock-default-fontify-region'.

On `font-lock-fontify-region-function' in notebook buffers.  A cell's
output is buffer text, so the notebook language's own font-lock would
otherwise read a traceback or a printed string as code: it strips the
`face' properties the renderer put there — the resolved ANSI colours,
the stderr red, the frame around the block — and paints its own over
what is left.  Only the source between the outputs is handed on.

Nothing needs to hold `font-lock-extend-region-functions' back at the
seams: a cell owns its trailing newline and an output block ends with
its closing rule's, so every run of source both begins and ends at the
beginning of a line, and whole-line extension has nowhere to reach."
  (jsonyter--nb-map-source-runs
   beg end
   (lambda (from to) (font-lock-default-fontify-region from to loudly)))
  ;; The output spans inside the region are finished, not pending, so
  ;; report the whole of it as done rather than leaving jit-lock to come
  ;; back for them on every redisplay.
  `(jit-lock-bounds ,beg . ,end))

(defun jsonyter--nb-unfontify-region (beg end)
  "Strip font-lock's faces from BEG..END, leaving rendered cell output alone.

On `font-lock-unfontify-region-function' in notebook buffers, and the
necessary other half of `jsonyter--nb-fontify-region': output text is
not font-lock's to paint, so it is not font-lock's to strip either.
Without this, anything that unfontifies wholesale — \\[font-lock-update],
turning the mode off and on, a major-mode change — would take the
renderer's own colours with it and never put them back, since
refontifying deliberately skips the output."
  (jsonyter--nb-map-source-runs beg end #'font-lock-default-unfontify-region))

(defun jsonyter--source-hash (code)
  "Hash of CODE, as stored on an overlay to detect later source edits."
  (secure-hash 'sha1 code))

(defun jsonyter--output-update-stale (ov source)
  "Recompute whether OV's shown output is stale against SOURCE.
Refreshes OV's output display only when the verdict actually changes.
An overlay with no output, or with no recorded source hash, is never
marked stale."
  (let ((output (overlay-get ov 'jsonyter-output-string)))
    (when (and output (not (string-empty-p output)))
      (let* ((hash (overlay-get ov 'jsonyter-source-hash))
             (stale (and hash
                         (not (equal hash (jsonyter--source-hash source)))
                         t)))
        (unless (eq stale (overlay-get ov 'jsonyter-output-stale))
          (overlay-put ov 'jsonyter-output-stale stale)
          (jsonyter--nb-refresh-output ov))))))

(defun jsonyter--nb-stale-after-change (beg end _len)
  "After an edit from BEG to END, re-judge the affected cells' outputs.
On `after-change-functions' in notebook buffers.  Stands down during
cell surgery (see `jsonyter--nb-cell-surgery'), whose transient
intermediate states are not edits to any cell's source."
  (unless jsonyter--nb-cell-surgery
    (dolist (cell (delete-dups (delq nil (list (jsonyter--nb-cell-at beg)
                                               (jsonyter--nb-cell-at end)))))
      (jsonyter--output-update-stale cell (jsonyter--nb-cell-source cell)))))

;;; Building the buffer

(defun jsonyter--nb-render (notebook)
  "Replace the current buffer with a rendered view of NOTEBOOK."
  (let ((inhibit-read-only t)
        (jsonyter--nb-cell-surgery t))
    (erase-buffer)
    (dolist (cell (plist-get notebook :cells))
      (let ((start (point)))
        (insert (jsonyter--nb-text (plist-get cell :source)))
        ;; Every cell owns at least its own newline.  A cell with empty
        ;; source — what saving a freshly inserted cell writes — would
        ;; otherwise land at `bolp' without having moved point, giving it
        ;; a zero-length overlay: no line of its own in the buffer, and a
        ;; start position shared with the cell after it, so
        ;; `overlays-at' there reports two cells and document order comes
        ;; down to a tie in the sort.  Same invariant the insert path
        ;; keeps (see `jsonyter--nb-insert-cell'), which is what makes a
        ;; save-and-reopen round trip a fixed point.
        (when (or (= (point) start) (not (bolp)))
          (insert "\n"))
        ;; The cell's overlay reaches past its source, over the output
        ;; text `jsonyter--nb-make-cell' writes in after it, so the next
        ;; cell begins at the overlay's end and not at the source's.
        (goto-char (overlay-end (jsonyter--nb-make-cell start (point) cell)))))
    (goto-char (point-min))))

;;; Saving

;; The buffer holds a rendered view, not notebook JSON, so it can never
;; be written to disk directly.  Saving instead hands the cell list to
;; the jsonyter Python package's `write_notebook', which merges the new
;; source onto the file's own cells by id — preserving stored outputs,
;; metadata, attachments and Jupyter's exact JSON formatting, so an
;; unedited save is byte-identical and a one-line edit is a one-line
;; diff.

(defvar-local jsonyter--nb-file-hash nil
  "SHA-256 of the notebook file as it was last read or written.
Passed back on save so an edit made outside Emacs is detected rather
than silently clobbered.")

(defvar-local jsonyter--nb-outputs-dirty nil
  "Non-nil once a cell's output has changed in this session.
Running a cell changes no buffer text, so Emacs considers the buffer
unmodified and \\[save-buffer] short-circuits before any save hook runs.
Without tracking this, re-running cells and saving looks like a silent
failure — see `jsonyter-notebook-save-buffer'.")

(defun jsonyter--nb-hash-file (path)
  "Return the sha256 of PATH's bytes, matching the bridge's `file_hash'.
Read literally and unibyte so the digest is over raw bytes, not decoded
characters."
  (and path (file-exists-p path)
       (with-temp-buffer
         (set-buffer-multibyte nil)
         (insert-file-contents-literally path)
         (secure-hash 'sha256 (current-buffer)))))

(defun jsonyter--ensure-bridge ()
  "Make sure a bridge process is running, without starting a kernel.
Saving is a local filesystem operation, so a notebook opened purely to
read can still be saved without ever contacting a Jupyter server."
  (unless (process-live-p jsonyter--process)
    (setq jsonyter--process (jsonyter--start-bridge)))
  jsonyter--process)

(defun jsonyter--nb-collect-cells (&optional include-outputs)
  "The buffer's cells as a list of plists for `write_notebook'.

With INCLUDE-OUTPUTS, a cell touched this session — run, or explicitly
cleared, since the notebook was opened — also carries its current
`outputs'/`execution_count'.  A cell never touched omits the key
entirely, which is what tells the bridge to leave its stored output on
disk exactly as it was; see `jsonyter--nb-set-output'."
  (mapcar
   (lambda (cell)
     (append
      (list :id (or (overlay-get cell 'jsonyter-cell-id) :null)
            :cell_type (overlay-get cell 'jsonyter-cell-type)
            :source (jsonyter--nb-cell-source cell))
      (and include-outputs
           (overlay-get cell 'jsonyter-outputs-touched)
           (list :outputs (vconcat (mapcar #'jsonyter--nb-output-to-spec
                                           (overlay-get cell 'jsonyter-raw-outputs)))
                 :execution_count (or (overlay-get cell 'jsonyter-exec-count) :null)))))
   (jsonyter--nb-cells)))

(defun jsonyter--nb-do-save (include-outputs)
  "Write this notebook's cell source to its file through the bridge.
Also writes outputs when INCLUDE-OUTPUTS is non-nil.  Shared by
`jsonyter-notebook-save' and `jsonyter-notebook-save-with-outputs'."
  (unless buffer-file-name
    (user-error "This notebook buffer isn't visiting a file"))
  (jsonyter--ensure-bridge)
  (let* ((had-new-output jsonyter--nb-outputs-dirty)
         (cells (jsonyter--nb-collect-cells include-outputs))
         (result
          (condition-case err
              (jsonyter--request-sync
               "write_notebook"
               (append
                (list :path (expand-file-name buffer-file-name)
                      :cells (vconcat cells)
                      :expect_hash (or jsonyter--nb-file-hash :null))
                (and include-outputs (list :include_outputs t)))
               jsonyter-startup-timeout)
            (error
             ;; A conflict is the one failure worth explaining, since the
             ;; fix is to reload rather than to retry.
             (if (string-match-p "NotebookConflict\\|has changed\\|changed on disk\\|hash"
                                 (error-message-string err))
                 (user-error
                  "jsonyter: %s has changed on disk since it was opened; revert (%s) to reload"
                  (file-name-nondirectory buffer-file-name)
                  (substitute-command-keys "\\[revert-buffer]"))
               (signal (car err) (cdr err)))))))
    ;; Adopt the ids the bridge assigned, so cells created in this
    ;; session match up on the next save instead of being recreated.
    (let ((ids (append (plist-get result :cells) nil))
          (cell-overlays (jsonyter--nb-cells)))
      (cl-loop for cell in cell-overlays
               for id in ids
               do (overlay-put cell 'jsonyter-cell-id id)))
    (let ((written 0))
      (when include-outputs
        (dolist (cell (jsonyter--nb-cells))
          (when (overlay-get cell 'jsonyter-outputs-touched) (cl-incf written))
          (overlay-put cell 'jsonyter-outputs-touched nil)
          (overlay-put cell 'jsonyter-raw-outputs nil))
        (setq jsonyter--nb-outputs-dirty nil))
      (setq jsonyter--nb-file-hash
            (or (plist-get result :hash)
                (jsonyter--nb-hash-file buffer-file-name)))
      (set-buffer-modified-p nil)
      (set-visited-file-modtime)
      (message
       "jsonyter: wrote %s (%d cells%s)"
       (file-name-nondirectory buffer-file-name) (length cells)
       (cond (include-outputs (format ", %d with new output" written))
             (had-new-output
              " — source only; new outputs not saved (C-c C-s saves them too)")
             (t ""))))
    ;; Non-nil tells Emacs the buffer has been written.
    t))

(defun jsonyter-notebook-save ()
  "Write this notebook's cell source back to its file.
Installed on `write-contents-functions', so \\[save-buffer] uses it.
Execution results are not included; see
`jsonyter-notebook-save-with-outputs' to persist newly generated
outputs too."
  (interactive)
  (jsonyter--nb-do-save nil))

(defun jsonyter-notebook-save-with-outputs ()
  "Write this notebook's cell source AND this session's new outputs.

A cell run, or explicitly cleared, since the notebook was opened has its
stored output replaced by what is now shown; every other cell's stored
output is left exactly as it was.  Because only touched cells are
rewritten, this still produces a small diff when just a few cells were
actually re-run — but a real one for each of those, including any
embedded images."
  (interactive)
  (jsonyter--nb-do-save t))

(defun jsonyter-notebook-save-buffer ()
  "Save this notebook, saying plainly when there is nothing to write.

Running a cell changes no buffer text, so Emacs sees an unmodified
buffer and \\[save-buffer] returns without calling any save hook.  That
is indistinguishable from a save that failed, which is precisely how it
looks after re-running cells to produce new figures.  Say so instead,
and point at `jsonyter-notebook-save-with-outputs' if that is what was
wanted."
  (interactive)
  (cond
   ((buffer-modified-p) (save-buffer))
   (jsonyter--nb-outputs-dirty
    (message "jsonyter: nothing written — cell source is unchanged; %s to also save this session's new outputs"
             (substitute-command-keys "\\[jsonyter-notebook-save-with-outputs]")))
   (t (message "jsonyter: no changes to save"))))

;;; Execution

(defun jsonyter-notebook-start-kernel ()
  "Start this notebook's kernel, using the language in its metadata."
  (interactive)
  (if (jsonyter--live-p)
      (message "jsonyter: kernel already running (%s)"
               (jsonyter--session-kernel-name (jsonyter--session)))
    (let ((language (or jsonyter--nb-lang "python")))
      (message "jsonyter: starting %s kernel..." language)
      (jsonyter--connect-kernel (cons language ""))
      (message "jsonyter: kernel %s ready"
               (jsonyter--session-kernel-name (jsonyter--session))))))

(defun jsonyter--nb-ensure-kernel ()
  "Make sure a kernel is running, starting one if that is allowed."
  (unless (jsonyter--live-p)
    (unless jsonyter-notebook-auto-start-kernel
      (user-error "No kernel: M-x jsonyter-notebook-start-kernel"))
    (jsonyter-notebook-start-kernel)))

(defun jsonyter--nb-set-output (cell rendered &optional raw touched)
  "Set CELL's displayed output text to RENDERED.

When TOUCHED, also record RAW — a list of kernel-shape output plists —
as what this cell produced *this session*, which is what makes it
eligible to have its stored output replaced by
`jsonyter-notebook-save-with-outputs'.  Without TOUCHED, only the
display changes and the cell's save-eligibility is left exactly as it
was: e.g. a bridge-level failure message is not a real kernel result
and must not be recorded as one."
  (overlay-put cell 'jsonyter-output-string rendered)
  (when touched
    (overlay-put cell 'jsonyter-raw-outputs raw)
    (overlay-put cell 'jsonyter-outputs-touched t))
  (unless (jsonyter--overlay-string-cell-p cell)
    (setq jsonyter--nb-outputs-dirty t))
  (jsonyter--nb-refresh-output cell))

(defun jsonyter--nb-append-output (cell output)
  "Append one kernel OUTPUT to CELL, honoring clear_output.
A script cell's output ends up in an overlay string, so it is rendered
for one; a notebook cell's becomes buffer text and is rendered with the
slicing that needs — see `jsonyter--nb-refresh-output'."
  (if (equal (plist-get output :type) "clear_output")
      (jsonyter--nb-set-output cell "" nil t)
    (jsonyter--nb-set-output
     cell (concat (or (overlay-get cell 'jsonyter-output-string) "")
                  (jsonyter--nb-render-string
                   output (jsonyter--overlay-string-cell-p cell)))
     (append (overlay-get cell 'jsonyter-raw-outputs) (list output))
     t)))

(defun jsonyter--nb-output-to-spec (output)
  "Convert kernel-shape OUTPUT to the nbformat shape for saving.
This is what `write_notebook' expects with `include_outputs' — the
inverse of `jsonyter--nb-adapt-output', for an OUTPUT as delivered by
`execute'.

`update_display_data' has no independent slot in nbformat (it is meant
to patch an existing `display_data' in place by display_id); stored as
an ordinary `display_data' instead, a reasonable approximation for a
plain saved file.  Rich mimetypes whose data is a flat set of strings —
images, HTML, plain text, the common case for a matplotlib figure —
round-trip correctly; a mimetype whose JSON value nests further arrays
does not, since data/metadata are carried through as read, and this
library parses JSON arrays as Lisp lists rather than vectors throughout.
Not expected to matter for anything but exotic interactive-widget
output."
  (let ((type (plist-get output :type)))
    (pcase type
      ("stream" (list :output_type "stream"
                      :name (or (plist-get output :name) "stdout")
                      :text (or (plist-get output :text) "")))
      ((or "display_data" "execute_result" "update_display_data")
       (append (list :output_type (if (equal type "update_display_data")
                                      "display_data" type)
                     :data (or (plist-get output :data) (list))
                     :metadata (or (plist-get output :metadata) (list)))
               (and (equal type "execute_result")
                    (list :execution_count (plist-get output :execution_count)))))
      ("error" (list :output_type "error"
                     :ename (or (plist-get output :ename) "")
                     :evalue (or (plist-get output :evalue) "")
                     :traceback (vconcat (plist-get output :traceback))))
      (_ (list :output_type "stream" :name "stdout"
              :text (format "[jsonyter: unrecognized output type %s]\n" type))))))

(defun jsonyter-notebook-run-cell (&optional advance)
  "Execute the cell at point.  With ADVANCE, move to the next cell after."
  (interactive)
  (let ((cell (jsonyter--nb-cell-at)))
    (unless cell (user-error "No cell at point"))
    (cond
     ((member (overlay-get cell 'jsonyter-cell-type) '("markdown" "raw"))
      (message "jsonyter: %s cell — nothing to execute"
               (overlay-get cell 'jsonyter-cell-type)))
     ((jsonyter--busy-p)
      (message "jsonyter: kernel is busy (C-c C-c to interrupt)"))
     (t
      (jsonyter--nb-ensure-kernel)
      (let ((code (jsonyter--nb-cell-source cell))
            (session (jsonyter--session)))
        (if (string-blank-p code)
            (message "jsonyter: empty cell")
          ;; The output about to arrive belongs to the source being sent;
          ;; record that pairing so later edits flag the output stale.
          (overlay-put cell 'jsonyter-source-hash
                       (jsonyter--source-hash code))
          (overlay-put cell 'jsonyter-output-stale nil)
          ;; Re-running replaces the previous result outright, which is
          ;; what makes outputs disposable rather than accumulating. This
          ;; also marks the cell touched, so it is what makes a freshly
          ;; (re-)run cell eligible for `jsonyter-notebook-save-with-outputs'
          ;; even if the run produces nothing further.
          (jsonyter--nb-set-output cell "" nil t)
          (overlay-put cell 'jsonyter-running t)
          (jsonyter--nb-refresh-prompt cell)
          (setf (jsonyter--session-busy session) t)
          (setq jsonyter--nb-running-cell cell)
          (force-mode-line-update)
          (jsonyter--send
           "execute"
           (append (list :kernel_id (jsonyter--session-kernel-id session)
                         :code code)
                   (and jsonyter-stream-output '(:stream t)))
           (list
            :output (lambda (output) (jsonyter--nb-append-output cell output))
            :result
            (lambda (msg)
              (setf (jsonyter--session-busy session) nil)
              (setq jsonyter--nb-running-cell nil)
              (overlay-put cell 'jsonyter-running nil)
              (let ((err (plist-get msg :error))
                    (result (plist-get msg :result)))
                (cond
                 (err
                  (jsonyter--nb-set-output
                   cell (propertize (format "[execute failed: %s]\n"
                                            (jsonyter--error-message err))
                                    'face 'jsonyter-stderr-face)))
                 (result
                  (overlay-put cell 'jsonyter-exec-count
                               (plist-get result :execution_count))
                  ;; Any outputs streaming did not already draw (an older
                  ;; bridge streams none at all).
                  (let ((drawn (overlay-get cell 'jsonyter-output-string)))
                    (when (and (or (null drawn) (string-empty-p drawn))
                               (plist-get result :outputs))
                      (dolist (o (plist-get result :outputs))
                        (jsonyter--nb-append-output cell o)))))))
              (jsonyter--nb-refresh-prompt cell)
              (force-mode-line-update)))))))))
  (when advance (jsonyter-notebook-next-cell)))

(defun jsonyter-notebook-run-cell-and-advance ()
  "Execute the cell at point, then move to the next one."
  (interactive)
  (jsonyter-notebook-run-cell t))

(defun jsonyter-notebook-run-all ()
  "Execute every code cell in order, waiting for each to finish."
  (interactive)
  (jsonyter--nb-ensure-kernel)
  (dolist (cell (jsonyter--nb-cells))
    (when (equal (overlay-get cell 'jsonyter-cell-type) "code")
      (goto-char (overlay-start cell))
      (jsonyter-notebook-run-cell)
      (let ((deadline (+ (float-time) 3600)))
        (while (and (jsonyter--busy-p) (< (float-time) deadline))
          (accept-process-output jsonyter--process 0.05))))))

(defun jsonyter-notebook-clear-cell-output ()
  "Discard the output shown beneath the cell at point.
Also marks the cell touched, so a subsequent
`jsonyter-notebook-save-with-outputs' clears its stored output on disk
rather than leaving a stale result behind."
  (interactive)
  (let ((cell (jsonyter--nb-cell-at)))
    (unless cell (user-error "No cell at point"))
    (jsonyter--nb-set-output cell "" nil t)))

(defun jsonyter-notebook-clear-all-output ()
  "Discard every output in this notebook and blank its execution counts.
Leaves the notebook looking as though nothing has been run, which is what
you want before running a project through cleanly.  Also marks every
code cell touched, the same as `jsonyter-notebook-clear-cell-output'."
  (interactive)
  (dolist (cell (jsonyter--nb-cells))
    (when (equal (overlay-get cell 'jsonyter-cell-type) "code")
      (jsonyter--nb-set-output cell "" nil t))
    (overlay-put cell 'jsonyter-exec-count nil)
    (overlay-put cell 'jsonyter-running nil)
    (jsonyter--nb-refresh-prompt cell))
  (setq jsonyter--nb-outputs-dirty nil)
  (message "jsonyter: cleared all output"))

;;;###autoload
(defun jsonyter-clear ()
  "Clear output: every cell in a notebook, or the transcript in a REPL."
  (interactive)
  (cond
   ((bound-and-true-p jsonyter-notebook-mode) (jsonyter-notebook-clear-all-output))
   ((derived-mode-p 'jsonyter-repl-mode) (jsonyter-repl-clear))
   ((bound-and-true-p jsonyter-script-mode) (jsonyter-script-clear-all-output))
   (t (user-error "Not a jsonyter notebook, script or REPL buffer"))))

;;; Cell management

(defun jsonyter--nb-insert-cell (pos cell-type)
  "Create a new empty CELL-TYPE cell whose source begins at POS."
  (goto-char pos)
  (let* ((jsonyter--nb-cell-surgery t)
         ;; POS may be the far side of a cell's read-only output, which
         ;; is exactly where a cell inserted below one that has run
         ;; belongs.
         (inhibit-read-only t)
         (start (point))
         ;; A cell beginning exactly here would absorb the newline
         ;; inserted below: `make-overlay's FRONT-ADVANCE is nil, so text
         ;; inserted at an overlay's start falls inside it, silently
         ;; prepending a blank line to that cell's source.  Nudge such a
         ;; cell past the insertion instead, so it and the new cell stay
         ;; back to back — the front-boundary counterpart of the
         ;; rear-boundary hazard documented in `jsonyter--nb-make-cell'.
         (adjacent (seq-filter (lambda (o) (= (overlay-start o) start))
                               (jsonyter--nb-cells))))
    (insert "\n")
    (dolist (o adjacent) (move-overlay o (point) (overlay-end o)))
    (jsonyter--nb-make-cell start (point)
                            (list :id nil :cell_type cell-type :outputs nil))
    (goto-char start)))

(defun jsonyter--nb-ensure-notebook ()
  "Signal an error unless the current buffer is a rendered notebook.
The cell-editing commands are autoloaded and may be bound outside
`jsonyter-notebook-mode-map', so they check rather than trusting the
keymap they were reached through."
  (unless (bound-and-true-p jsonyter-notebook-mode)
    (user-error "Not in a jsonyter notebook buffer")))

;;;###autoload
(defun jsonyter-insert-cell-below (&optional markdown)
  "Insert an empty code cell below the cell at point.
With a prefix argument (MARKDOWN), insert a markdown cell instead."
  (interactive "P")
  (jsonyter--nb-ensure-notebook)
  (let ((cell (jsonyter--nb-cell-at)))
    (jsonyter--nb-insert-cell (if cell (overlay-end cell) (point-max))
                              (if markdown "markdown" "code"))))

;;;###autoload
(defun jsonyter-insert-cell-above (&optional markdown)
  "Insert an empty code cell above the cell at point.
With a prefix argument (MARKDOWN), insert a markdown cell instead."
  (interactive "P")
  (jsonyter--nb-ensure-notebook)
  (let ((cell (jsonyter--nb-cell-at)))
    (jsonyter--nb-insert-cell (if cell (overlay-start cell) (point-min))
                              (if markdown "markdown" "code"))))

;;;###autoload
(defun jsonyter-delete-cell ()
  "Delete the cell at point, source and output together."
  (interactive)
  (jsonyter--nb-ensure-notebook)
  (let ((cell (jsonyter--nb-cell-at)))
    (unless cell (user-error "No cell at point"))
    (when (or (string-blank-p (jsonyter--nb-cell-source cell))
              (yes-or-no-p "Delete this cell? "))
      (let* ((jsonyter--nb-cell-surgery t)
             (inhibit-read-only t)
             (start (overlay-start cell))
             (end (overlay-end cell))
             (source-end (overlay-get cell 'jsonyter-source-end))
             (src-end (marker-position source-end)))
        ;; The output leaves the way it arrived: as text that was never
        ;; part of the document.  Deleting it along with the source would
        ;; put it in the undo history, and undoing would then restore a
        ;; read-only block with no cell left to own it — text the buffer
        ;; would give no way to remove again.
        (with-silent-modifications (delete-region src-end end))
        (jsonyter--forget-undo-after src-end)
        (set-marker source-end nil)
        (delete-overlay cell)
        (delete-region start src-end)))))

;;;###autoload
(defun jsonyter-toggle-cell-type ()
  "Toggle the cell at point between code and markdown.
A cell turned into markdown loses its output, since markdown cells
cannot carry any — the same rule the bridge applies when writing."
  (interactive)
  (jsonyter--nb-ensure-notebook)
  (let ((cell (jsonyter--nb-cell-at)))
    (unless cell (user-error "No cell at point"))
    (let ((new (if (equal (overlay-get cell 'jsonyter-cell-type) "code")
                   "markdown" "code")))
      (overlay-put cell 'jsonyter-cell-type new)
      (overlay-put cell 'jsonyter-exec-count nil)
      (jsonyter--nb-set-output cell "")
      (jsonyter--nb-refresh-prompt cell)
      (message "jsonyter: cell is now %s" new))))

(defconst jsonyter--nb-cell-props
  '(jsonyter-cell-id jsonyter-cell-type jsonyter-exec-count
    jsonyter-output-string jsonyter-raw-outputs jsonyter-outputs-touched
    jsonyter-source-hash jsonyter-output-stale)
  "Overlay properties making up a cell's identity, as opposed to position.
These are the things that must travel with the text when cells move —
including this session's raw outputs and their touched flag, which
`jsonyter-notebook-save-with-outputs' writes by cell: left behind on a
move, they would be saved under whichever cell took over the old
position.

`jsonyter-source-end' is not among them: it is a marker into the text
being moved, so a swap has to re-derive it rather than hand it over —
see `jsonyter--nb-swap-cells'.")

(defun jsonyter--nb-swap-cells (a b)
  "Exchange the text and identity of adjacent cells A and B (A before B).
A cell's output is buffer text within its own span, so it travels with
the source rather than needing to be carried separately.  Returns the
position the rearranged text starts at, for `jsonyter--forget-undo-after'."
  (let* ((jsonyter--nb-cell-surgery t)
         ;; The text being moved includes each cell's read-only output.
         (inhibit-read-only t)
         ;; Undo could not put this move back in any case: the identities
         ;; that belong with the text travel as overlay properties, which
         ;; undo does not record, so replaying the text alone would leave
         ;; each cell wearing its neighbour's results — and the output it
         ;; restored, being read-only, could not then be cleared by hand.
         ;; The move stays out of the history, and entries pointing into
         ;; the rearranged text are dropped once it is bound back.
         (buffer-undo-list t)
         (cells (jsonyter--nb-cells))
         ;; Every other cell's span is unchanged by a swap, since the two
         ;; texts merely trade places. Snapshot them anyway: the
         ;; intermediate delete collapses neighbouring overlays onto
         ;; START, and the re-inserted text is then absorbed into
         ;; whichever of them begins there — which silently stretched the
         ;; following cell across the whole buffer before this was fixed.
         (spans (mapcar (lambda (o) (list o (overlay-start o) (overlay-end o)))
                        cells))
         (a-text (buffer-substring (overlay-start a) (overlay-end a)))
         (b-text (buffer-substring (overlay-start b) (overlay-end b)))
         (a-props (mapcar (lambda (p) (cons p (overlay-get a p)))
                          jsonyter--nb-cell-props))
         (b-props (mapcar (lambda (p) (cons p (overlay-get b p)))
                          jsonyter--nb-cell-props))
         ;; Where each cell's source ends, as a distance from its own
         ;; start.  The markers themselves sit in the text about to be
         ;; deleted, so they collapse onto START and cannot be read back
         ;; afterwards; only the offsets survive the move.
         (a-source-end (overlay-get a 'jsonyter-source-end))
         (b-source-end (overlay-get b 'jsonyter-source-end))
         (a-offset (- (marker-position a-source-end) (overlay-start a)))
         (b-offset (- (marker-position b-source-end) (overlay-start b)))
         (start (overlay-start a))
         (end (overlay-end b))
         (boundary (+ start (length b-text))))
    (delete-region start end)
    (goto-char start)
    (insert b-text a-text)
    (dolist (span spans)
      (let ((ov (nth 0 span)))
        (cond ((eq ov a) (move-overlay ov start boundary))
              ((eq ov b) (move-overlay ov boundary end))
              (t (move-overlay ov (nth 1 span) (nth 2 span))))))
    ;; The overlays keep their slots; the text moved, so the identities
    ;; move with it — and each slot's source now ends where the text that
    ;; landed in it says it does, not where its previous occupant's did.
    (dolist (p b-props) (overlay-put a (car p) (cdr p)))
    (dolist (p a-props) (overlay-put b (car p) (cdr p)))
    (overlay-put a 'jsonyter-source-end (set-marker b-source-end
                                                    (+ start b-offset)))
    (overlay-put b 'jsonyter-source-end (set-marker a-source-end
                                                    (+ boundary a-offset)))
    (jsonyter--nb-refresh-prompt a) (jsonyter--nb-refresh-output a)
    (jsonyter--nb-refresh-prompt b) (jsonyter--nb-refresh-output b)
    (goto-char (overlay-start b))
    start))

;;;###autoload
(defun jsonyter-move-cell-down ()
  "Move the cell at point below the following cell."
  (interactive)
  (jsonyter--nb-ensure-notebook)
  (let* ((cell (jsonyter--nb-cell-at))
         (next (and cell (seq-find (lambda (o) (> (overlay-start o)
                                                  (overlay-start cell)))
                                   (jsonyter--nb-cells)))))
    (unless cell (user-error "No cell at point"))
    (if next (jsonyter--forget-undo-after (jsonyter--nb-swap-cells cell next))
      (message "jsonyter: already the last cell"))))

;;;###autoload
(defun jsonyter-move-cell-up ()
  "Move the cell at point above the preceding cell."
  (interactive)
  (jsonyter--nb-ensure-notebook)
  (let* ((cell (jsonyter--nb-cell-at))
         (prev (and cell (car (last (seq-filter
                                     (lambda (o) (< (overlay-start o)
                                                    (overlay-start cell)))
                                     (jsonyter--nb-cells)))))))
    (unless cell (user-error "No cell at point"))
    (if prev (jsonyter--forget-undo-after (jsonyter--nb-swap-cells prev cell))
      (message "jsonyter: already the first cell"))))

;; Through 1.0.0 these commands were named `jsonyter-notebook-*'.  They
;; now carry shorter public names, which is what the keymap below binds;
;; the old names stay working as obsolete aliases.

;;;###autoload
(define-obsolete-function-alias 'jsonyter-notebook-insert-cell-below
  #'jsonyter-insert-cell-below "1.2.0")
;;;###autoload
(define-obsolete-function-alias 'jsonyter-notebook-insert-cell-above
  #'jsonyter-insert-cell-above "1.2.0")
;;;###autoload
(define-obsolete-function-alias 'jsonyter-notebook-delete-cell
  #'jsonyter-delete-cell "1.2.0")
;;;###autoload
(define-obsolete-function-alias 'jsonyter-notebook-change-cell-type
  #'jsonyter-toggle-cell-type "1.2.0")
;;;###autoload
(define-obsolete-function-alias 'jsonyter-notebook-move-cell-down
  #'jsonyter-move-cell-down "1.2.0")
;;;###autoload
(define-obsolete-function-alias 'jsonyter-notebook-move-cell-up
  #'jsonyter-move-cell-up "1.2.0")

;;; Navigation

(defun jsonyter-notebook-next-cell ()
  "Move to the start of the next cell."
  (interactive)
  (let* ((here (jsonyter--nb-cell-at))
         (next (seq-find (lambda (o)
                           (> (overlay-start o)
                              (if here (overlay-start here) (point))))
                         (jsonyter--nb-cells))))
    (if next (goto-char (overlay-start next))
      (message "jsonyter: last cell"))))

(defun jsonyter-notebook-previous-cell ()
  "Move to the start of the previous cell."
  (interactive)
  (let* ((here (jsonyter--nb-cell-at))
         (limit (if here (overlay-start here) (point)))
         (prev (car (last (seq-filter (lambda (o) (< (overlay-start o) limit))
                                      (jsonyter--nb-cells))))))
    (if prev (goto-char (overlay-start prev))
      (message "jsonyter: first cell"))))

;;; The mode

(defvar jsonyter-notebook-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "<C-return>") #'jsonyter-notebook-run-cell)
    (define-key map (kbd "C-c C-e") #'jsonyter-notebook-run-cell)
    (define-key map (kbd "<S-return>") #'jsonyter-notebook-run-cell-and-advance)
    (define-key map (kbd "C-c C-n") #'jsonyter-notebook-next-cell)
    (define-key map (kbd "C-c C-p") #'jsonyter-notebook-previous-cell)
    (define-key map (kbd "C-c C-b") #'jsonyter-notebook-run-all)
    (define-key map (kbd "C-c C-c") #'jsonyter-interrupt)
    (define-key map (kbd "C-c C-r") #'jsonyter-restart)
    (define-key map (kbd "C-c C-l") #'jsonyter-kernel-reconnect)
    (define-key map (kbd "C-c C-j") #'jsonyter-kernel-connect)
    (define-key map (kbd "C-c M-h") #'jsonyter-kernel-history)
    (define-key map (kbd "C-c M-o") #'jsonyter-notebook-clear-cell-output)
    (define-key map (kbd "C-c M-O") #'jsonyter-notebook-clear-all-output)
    (define-key map (kbd "C-c C-k") #'jsonyter-notebook-start-kernel)
    (define-key map (kbd "C-c C-a") #'jsonyter-insert-cell-above)
    (define-key map (kbd "C-c C-i") #'jsonyter-insert-cell-below)
    (define-key map (kbd "C-c C-w") #'jsonyter-delete-cell)
    (define-key map (kbd "C-c C-t") #'jsonyter-toggle-cell-type)
    (define-key map (kbd "C-c <up>") #'jsonyter-move-cell-up)
    (define-key map (kbd "C-c <down>") #'jsonyter-move-cell-down)
    (define-key map (kbd "C-x C-s") #'jsonyter-notebook-save-buffer)
    (define-key map (kbd "C-c C-s") #'jsonyter-notebook-save-with-outputs)
    map)
  "Keymap for `jsonyter-notebook-mode'.")

(define-minor-mode jsonyter-notebook-mode
  "Minor mode for Jupyter notebooks rendered by jsonyter.

Layered over the notebook language's own major mode, so syntax
highlighting and indentation are the language's own.  Cell prompts are
overlay strings; a cell's output is read-only buffer text after its
source, kept out of the undo history and out of the language's
font-lock, so undo and editing still see only the cell source.

\\{jsonyter-notebook-mode-map}"
  :lighter " Notebook"
  :keymap jsonyter-notebook-mode-map
  (if jsonyter-notebook-mode
      (progn
        (setq-local jsonyter--callbacks (make-hash-table :test #'eql))
        (setq-local jsonyter--output-start (make-marker))
        (setq-local jsonyter--output-end (make-marker))
        (set-marker-insertion-type jsonyter--output-end t)
        (setq mode-line-process '(:eval (jsonyter--mode-line-string)))
        ;; Cell output is buffer text, so a plot drawn into it is drawn
        ;; on the buffer's own line grid; see
        ;; `jsonyter--suppress-line-spacing'.
        (jsonyter--suppress-line-spacing)
        ;; Cell output is buffer text, and the language's own font-lock
        ;; must not treat it as code; see `jsonyter--nb-fontify-region'.
        (setq-local font-lock-fontify-region-function
                    #'jsonyter--nb-fontify-region)
        (setq-local font-lock-unfontify-region-function
                    #'jsonyter--nb-unfontify-region)
        (add-hook 'write-contents-functions #'jsonyter-notebook-save nil t)
        (add-hook 'kill-buffer-hook #'jsonyter--cleanup nil t)
        (add-hook 'after-change-functions
                  #'jsonyter--nb-stale-after-change nil t)
        (jsonyter-mode 1))
    (jsonyter--restore-line-spacing)
    (kill-local-variable 'font-lock-fontify-region-function)
    (kill-local-variable 'font-lock-unfontify-region-function)
    (remove-hook 'write-contents-functions #'jsonyter-notebook-save t)
    (remove-hook 'kill-buffer-hook #'jsonyter--cleanup t)
    (remove-hook 'after-change-functions #'jsonyter--nb-stale-after-change t)
    (jsonyter-mode -1)))

;;;###autoload
(defun jsonyter-notebook-open ()
  "Render the current buffer's .ipynb content as a notebook.
Intended for `auto-mode-alist':

  (add-to-list \\='auto-mode-alist \\='(\"\\\\.ipynb\\\\\\='\" . jsonyter-notebook-open))"
  (let* ((notebook (condition-case err
                       (jsonyter--nb-parse)
                     (error
                      (user-error "jsonyter: %s is not readable notebook JSON (%s)"
                                  (or buffer-file-name "buffer")
                                  (error-message-string err)))))
         (language (jsonyter--nb-language notebook))
         (mode (jsonyter--nb-major-mode language))
         (metadata (plist-get notebook :metadata))
         (format (cons (plist-get notebook :nbformat)
                       (plist-get notebook :nbformat_minor))))
    (funcall mode)
    (jsonyter-notebook-mode 1)
    (setq jsonyter--nb-metadata metadata
          jsonyter--nb-format format
          jsonyter--nb-lang language
          jsonyter--session-key (cons language "")
          jsonyter--nb-file-hash (jsonyter--nb-hash-file buffer-file-name))
    (jsonyter--nb-render notebook)
    (set-buffer-modified-p nil)
    (setq buffer-undo-list nil)
    (message
     "jsonyter: %d cells, %s kernel — C-RET run · S-RET run+advance · C-c C-b run all%s"
     (length (plist-get notebook :cells)) language
     (if (display-images-p) "" " (no image display: text output only)"))))


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
  :type 'regexp)

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
  :type '(alist :key-type symbol :value-type string))

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
    map)
  "Keymap for `jsonyter-script-mode'.")

;;;###autoload
(define-minor-mode jsonyter-script-mode
  "Run `# %%' cells in an ordinary script against a Jupyter kernel.

Output is shown inline in overlays, so the buffer's text — the file you
actually save — is never touched.

\\{jsonyter-script-mode-map}"
  :lighter " Cells"
  :keymap jsonyter-script-mode-map
  (if jsonyter-script-mode
      (progn
        (setq-local jsonyter--callbacks (make-hash-table :test #'eql))
        (setq mode-line-process '(:eval (jsonyter--mode-line-string)))
        (add-hook 'kill-buffer-hook #'jsonyter--cleanup nil t)
        (add-hook 'after-change-functions
                  #'jsonyter--script-stale-after-change nil t)
        (jsonyter-mode 1))
    (jsonyter-script-clear-all-output)
    (remove-hook 'kill-buffer-hook #'jsonyter--cleanup t)
    (remove-hook 'after-change-functions #'jsonyter--script-stale-after-change t)
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
  :type 'directory)

(defcustom jsonyter-org-stamp-results t
  "If non-nil, stamp a committed `#+RESULTS:' with its block's source hash.
Written as org's own `#+RESULTS[<hash>]:' slot, so a result reopened cold
knows which source produced it and jsonyter can flag it stale before any
kernel starts.  This is the same slot babel's `:cache yes' uses; the two
are mutually exclusive per block, so turn this off where you rely on
`:cache'."
  :type 'boolean)

(defcustom jsonyter-org-mode-lighter " Jy"
  "Mode-line lighter for `jsonyter-org-mode'."
  :type 'string)

(declare-function org-element-at-point "org-element" (&optional pom cached-only))
(declare-function org-element-type "org-element-ast" (node &optional anonymous))
(declare-function org-element-property "org-element-ast" (property node))
(declare-function org-babel-get-src-block-info "ob-core" (&optional light datum))
(declare-function org-babel-where-is-src-block-result "ob-core" (&optional insert info hash))
(declare-function org-babel-remove-result "ob-core" (&optional info keep-keyword))
(declare-function org-babel-next-src-block "ob-core" (&optional arg))
(declare-function org-babel-previous-src-block "ob-core" (&optional arg))

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

(defun jsonyter-org-inspect ()
  "Show kernel documentation for the thing at point in a jy: block."
  (interactive)
  (let ((session (jsonyter--org-session-at-point)))
    (unless (jsonyter--live-p session)
      (user-error "jsonyter: this block's kernel is not running"))
    (let* ((el (org-element-at-point))
           (body-beg (save-excursion
                       (goto-char (org-element-property :begin el))
                       (forward-line 1) (point)))
           (code (or (org-element-property :value el) ""))
           (pos (max 0 (min (length code) (- (point) body-beg))))
           (reply (jsonyter--kernel-request
                   "inspect"
                   (list :kernel_id (jsonyter--session-kernel-id session)
                         :code code :cursor_pos pos)))
           (text (and (eq (plist-get reply :found) t)
                      (jsonyter--mime (plist-get reply :data) :text/plain))))
      (if (not text)
          (message "jsonyter: no documentation found")
        (with-help-window "*jsonyter-doc*"
          (with-current-buffer standard-output
            (insert (ansi-color-apply text))))))))

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
        (jsonyter-mode 1)
        (jsonyter--org-scan-committed))
    (jsonyter-org-clear-all-output)
    (dolist (ov jsonyter--org-committed)
      (when (overlay-buffer ov) (delete-overlay ov)))
    (setq jsonyter--org-committed nil)
    (remove-hook 'kill-buffer-hook #'jsonyter--cleanup t)
    (remove-hook 'after-change-functions #'jsonyter--org-stale-after-change t)
    (jsonyter-mode -1)))

;;;###autoload
(defun jsonyter-org-mode-maybe ()
  "Enable `jsonyter-org-mode' when this Org buffer has a `jy:' session.
Suitable for `org-mode-hook'."
  (when (and (derived-mode-p 'org-mode) (jsonyter--org-buffer-has-jy-p))
    (jsonyter-org-mode 1)))


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
  :type 'boolean)

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
  :type 'integer)

(defcustom jsonyter-org-var-julia-dataframe nil
  "If non-nil, marshal a `:var' table with `:colnames yes' as a DataFrame in Julia.
Off by default: unlike Python's pandas, Julia's DataFrames.jl is not a
near-universal dependency, and jsonyter will not silently `using' a
package that may not be installed.  Turning this on is a promise that
the session already has it loaded.  With this off, or without
`:colnames', a Julia `:var' table is always a plain `Matrix'."
  :type 'boolean)

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

;;;; `.ipynb' <-> `.org' conversion (M8)

;; jsonyter already parses a notebook losslessly (`jsonyter--nb-parse') and
;; writes one back merged by cell id (`write_notebook', via
;; `jsonyter--nb-do-save'); that machinery is what makes round-tripping
;; through Org viable at all, per the feature request's Part 9.
;;
;; A cell's nbformat id is preserved in a `:PROPERTIES:' drawer immediately
;; ahead of its content -- code or prose alike.  It is deliberately *not*
;; attached to a heading the way a `:PROPERTIES:' drawer usually is:
;; nothing here reads it back with `org-entry-get' or relies on Org's own
;; property inheritance, only a plain regexp scan for
;; `:JSONYTER_CELL_ID:', so the drawer needs no heading to hang off and a
;; notebook with no heading structure at all converts just as well as one
;; with plenty.

(defcustom jsonyter-org-default-session-name "main"
  "Session name `jsonyter-org-from-notebook' opts every converted block into."
  :type 'string)

(defcustom jsonyter-org-markdown-converter nil
  "Function converting between Markdown and Org, or nil for the built-in choice.
Called as (FUNCTION TEXT DIRECTION), DIRECTION being `to-org' or
`to-markdown'; must return the converted text.  When nil, jsonyter shells
out to `pandoc' if it is on the variable `exec-path', and otherwise inserts TEXT
unchanged with a note saying so -- accurate about there being no real
conversion available, rather than silently claiming one where none
happened.  Markdown <-> Org is the one lossy step in the whole round
trip; this is the escape hatch for anyone who wants a better one."
  :type '(choice (const nil) function))

(defun jsonyter--org-markdown-convert (text direction)
  "Convert TEXT between Markdown and Org, per DIRECTION (`to-org'/`to-markdown')."
  (cond
   (jsonyter-org-markdown-converter (funcall jsonyter-org-markdown-converter text direction))
   ((executable-find "pandoc")
    (let ((from (if (eq direction 'to-org) "markdown" "org"))
          (to (if (eq direction 'to-org) "org" "markdown")))
      (with-temp-buffer
        (insert text)
        (if (zerop (call-process-region (point-min) (point-max) "pandoc"
                                        t t nil "-f" from "-t" to))
            (string-trim (buffer-string))
          (concat "[jsonyter: pandoc failed converting this cell -- inserted verbatim]\n\n"
                  text)))))
   (t (concat (format "[jsonyter: no Markdown%sOrg converter (install pandoc, or set \
`jsonyter-org-markdown-converter') -- inserted verbatim]\n\n"
                      (if (eq direction 'to-org) "->" "<-"))
              text))))

;;; notebook -> Org

(defun jsonyter--org-cell-id-drawer (id)
  "A `:PROPERTIES:' drawer string carrying nbformat cell ID, or \"\" without one."
  (if (and id (not (eq id :null)))
      (format ":PROPERTIES:\n:JSONYTER_CELL_ID: %s\n:END:\n" id)
    ""))

(defun jsonyter--org-from-notebook-code-cell (cell lang session)
  "Org text for one nbformat code CELL, opted into SESSION in LANG."
  (let* ((source (string-trim (jsonyter--nb-text (plist-get cell :source))))
         (outputs (mapcar #'jsonyter--nb-adapt-output (append (plist-get cell :outputs) nil)))
         (body (and outputs (jsonyter--org-result-body outputs))))
    (concat
     (jsonyter--org-cell-id-drawer (plist-get cell :id))
     (format "#+begin_src %s :session jy:%s\n%s\n#+end_src\n" lang session source)
     (if (and body (not (string-empty-p body)))
         (concat (if jsonyter-org-stamp-results
                     (format "#+RESULTS[%s]:\n" (substring (jsonyter--source-hash source) 0 7))
                   "#+RESULTS:\n")
                 ":results:\n" body "\n:end:\n")
       ""))))

(defun jsonyter--org-from-notebook-prose-cell (cell)
  "Org text for one nbformat markdown or raw CELL."
  (concat
   (jsonyter--org-cell-id-drawer (plist-get cell :id))
   (jsonyter--org-markdown-convert (jsonyter--nb-text (plist-get cell :source)) 'to-org)
   "\n"))

;;;###autoload
(defun jsonyter-org-from-notebook (ipynb-file org-file &optional session)
  "Write ORG-FILE as an Org rendering of IPYNB-FILE.

Each cell keeps its nbformat id in a `:PROPERTIES:' drawer, so
`jsonyter-org-to-notebook' can later merge an edited round trip back onto
the original file by id rather than regenerating it wholesale.  A stored
output is committed straight to a `#+RESULTS:' drawer, images included,
exactly as `jsonyter-org-commit-block' would write one.  SESSION
defaults to `jsonyter-org-default-session-name' and is the `jy:' session
name every code block opts into; the notebook's kernelspec becomes a
buffer-wide `#+PROPERTY:' line, so the file needs nothing further to run
its own blocks.

Interactively, prompts for both file names."
  (interactive
   (let* ((ipynb (read-file-name "Notebook to convert: " nil nil t nil
                                 (lambda (f) (string-suffix-p ".ipynb" f))))
          (default (concat (file-name-sans-extension ipynb) ".org")))
     (list ipynb (read-file-name "Write Org file: " nil default nil
                                 (file-name-nondirectory default)))))
  (when (and (file-exists-p org-file) (not (called-interactively-p 'interactive)))
    (user-error "jsonyter: %s already exists" org-file))
  (when (and (file-exists-p org-file) (called-interactively-p 'interactive)
             (not (yes-or-no-p (format "%s already exists; overwrite? " org-file))))
    (user-error "jsonyter: aborted"))
  (let* ((session (or session jsonyter-org-default-session-name))
         (notebook (with-temp-buffer
                     (insert-file-contents ipynb-file)
                     (jsonyter--nb-parse)))
         (lang (jsonyter--nb-language notebook))
         (cells (append (plist-get notebook :cells) nil))
         (buf (find-file-noselect org-file)))
    (with-current-buffer buf
      (erase-buffer)
      (insert (format "#+PROPERTY: header-args:%s :session jy:%s\n\n" lang session))
      (dolist (cell cells)
        (insert (if (equal (plist-get cell :cell_type) "code")
                    (jsonyter--org-from-notebook-code-cell cell lang session)
                  (jsonyter--org-from-notebook-prose-cell cell))
                "\n"))
      (save-buffer))
    (when (called-interactively-p 'interactive) (pop-to-buffer buf))
    (message "jsonyter: wrote %s" org-file)))

;;; Org -> notebook

(defun jsonyter--org-parse-results-drawer (info base-dir)
  "Kernel-shape outputs for INFO's block's current `#+RESULTS:' drawer, or nil.

Necessarily lossy: a `[[file:...]]' link becomes a `display_data' image,
read back from disk relative to BASE-DIR, but every text line becomes
one combined `stream' output regardless of whether it first came from a
stream or an `execute_result' -- once committed to fixed-width `: '
lines the two cannot be told apart, and interleaving between text and
images is not preserved either.  Good enough for what a committed drawer
actually is: a record that something ran and produced this, not a
faithful nbformat replica."
  (let ((pos (save-excursion (org-babel-where-is-src-block-result nil info))))
    (when pos
      (save-excursion
        (goto-char pos)
        (when (looking-at jsonyter--org-results-re)
          (let* ((el (org-element-at-point))
                 (end (org-element-property :end el))
                 lines outputs)
            (forward-line 1)
            (when (looking-at "^[ \t]*:results:[ \t]*$") (forward-line 1))
            (while (and (< (point) end) (not (looking-at "^[ \t]*:end:[ \t]*$")))
              (cond
               ((looking-at "^[ \t]*\\[\\[file:\\([^]]+\\)\\]\\]")
                (let* ((path (expand-file-name (match-string 1) base-dir))
                       (ext (downcase (or (file-name-extension path) ""))))
                  (when (file-exists-p path)
                    (push (list :output_type "display_data"
                                :data (list (intern (format ":image/%s"
                                                            (if (equal ext "jpg") "jpeg" ext)))
                                            (jsonyter--org-file-base64 path))
                                :metadata nil)
                          outputs)))
                (forward-line 1))
               ((looking-at "^[ \t]*:[ \t]?\\(.*\\)$")
                (push (match-string 1) lines)
                (forward-line 1))
               (t (forward-line 1))))
            (append (nreverse outputs)
                    (and lines
                         (list (list :output_type "stream" :name "stdout"
                                    :text (concat (mapconcat #'identity (nreverse lines) "\n")
                                                 "\n")))))))))))

(defun jsonyter--org-file-base64 (path)
  "Base64-encoded bytes of the file at PATH."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally path)
    (base64-encode-string (buffer-string))))

(defconst jsonyter--org-cell-id-re
  "^[ \t]*:PROPERTIES:[ \t]*\n[ \t]*:JSONYTER_CELL_ID:[ \t]*\\(\\S-+\\)[ \t]*\n[ \t]*:END:[ \t]*\n"
  "Matches a `jsonyter-org-from-notebook' cell-id drawer; group 1 is the id.")

(defun jsonyter--org-notebook-span-empty-p (text)
  "Non-nil when TEXT has no cell content once `#+KEYWORD:' lines are stripped.
`jsonyter-org-from-notebook' writes its `#+PROPERTY:' session line ahead
of the first cell-id drawer; that span is structural, not a cell, so it
is dropped along with genuinely blank ones."
  (string-blank-p (replace-regexp-in-string "^[ \t]*#\\+[^:\n]+:.*$" "" text)))

(defun jsonyter--org-notebook-cell-spans ()
  "This buffer's ((ID-OR-NIL . TEXT) ...), split at cell-id drawers.
TEXT runs from just after one drawer (or the start of the buffer, for
content with no id) to just before the next -- see the Commentary above
this section for why a drawer here carries no heading."
  (let (spans (id nil) (start (point-min)))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward jsonyter--org-cell-id-re nil t)
        (let ((text (buffer-substring-no-properties start (match-beginning 0))))
          (unless (jsonyter--org-notebook-span-empty-p text) (push (cons id text) spans)))
        (setq id (match-string 1) start (point)))
      (let ((text (buffer-substring-no-properties start (point-max))))
        (unless (jsonyter--org-notebook-span-empty-p text) (push (cons id text) spans))))
    (nreverse spans)))

(defun jsonyter--org-notebook-cell-from-span (id text base-dir)
  "One `write_notebook' cell plist from one (ID . TEXT) span, read from BASE-DIR."
  (let ((trimmed (string-trim text)))
    (if (string-match-p "\\`#\\+begin_src" trimmed)
        (with-temp-buffer
          (delay-mode-hooks (org-mode))
          (insert trimmed)
          (goto-char (point-min))
          (let* ((info (org-babel-get-src-block-info 'light))
                 (source (string-trim (or (nth 1 info) "")))
                 (outputs (and info (jsonyter--org-parse-results-drawer info base-dir))))
            (append (list :id (or id :null) :cell_type "code" :source source)
                    (and outputs
                         (list :outputs (vconcat (mapcar #'jsonyter--nb-output-to-spec outputs))
                               :execution_count :null)))))
      (list :id (or id :null) :cell_type "markdown"
            :source (jsonyter--org-markdown-convert trimmed 'to-markdown)))))

(defun jsonyter--org-to-notebook-cells ()
  "This buffer's cells, as a list of plists for `write_notebook'.
See `jsonyter--org-notebook-cell-spans' for how the buffer is split, and
`jsonyter--org-notebook-cell-from-span' for how one span becomes one
cell."
  (let ((base-dir (file-name-directory (or buffer-file-name default-directory))))
    (mapcar (lambda (span) (jsonyter--org-notebook-cell-from-span (car span) (cdr span) base-dir))
            (jsonyter--org-notebook-cell-spans))))

;;;###autoload
(defun jsonyter-org-to-notebook (org-file ipynb-file)
  "Write IPYNB-FILE from ORG-FILE's cells: `jy:' blocks and the prose between them.

The reverse of `jsonyter-org-from-notebook'.  A cell's `:JSONYTER_CELL_ID:'
drawer, if one is there, tells `write_notebook' which existing nbformat
cell to merge onto, so an unedited round trip reproduces the original
file and a one-block edit becomes a one-cell diff -- the same guarantee
`jsonyter-notebook-save-with-outputs' already gives a notebook buffer.  A
span with no id drawer is treated as a new cell.  A block's committed
`#+RESULTS:' is read back as that cell's output (see
`jsonyter--org-parse-results-drawer' for what is necessarily lossy about
that); a block with none keeps whatever nbformat already has on disk for
its id.

Interactively, prompts for both file names, defaulting IPYNB-FILE to
ORG-FILE's own name with the extension swapped."
  (interactive
   (let* ((org (read-file-name "Org file to convert: " nil nil t nil
                               (lambda (f) (string-suffix-p ".org" f))))
          (default (concat (file-name-sans-extension org) ".ipynb")))
     (list org (read-file-name "Write notebook: " nil default nil
                               (file-name-nondirectory default)))))
  (let* ((buf (find-file-noselect org-file))
         (cells (with-current-buffer buf (jsonyter--org-to-notebook-cells)))
         (hash (jsonyter--nb-hash-file ipynb-file)))
    (with-current-buffer buf
      (jsonyter--ensure-bridge)
      (jsonyter--request-sync
       "write_notebook"
       (list :path (expand-file-name ipynb-file)
             :cells (vconcat cells)
             :expect_hash (or hash :null)
             :include_outputs t)
       jsonyter-startup-timeout))
    (message "jsonyter: wrote %s" ipynb-file)))

(provide 'jsonyter)
;;; jsonyter.el ends here
