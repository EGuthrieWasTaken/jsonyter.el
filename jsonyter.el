;;; jsonyter.el --- Interactive Jupyter REPLs via the jsonyter bridge -*- lexical-binding: t; -*-

;; Author: Ethan Guthrie
;; Assisted-by: Claude:claude-fable-5
;; Version: 1.0.0
;; Package-Requires: ((emacs "27.1"))
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
;; Requires jsonyter >= 0.2 (concurrent bridge, "stream", "subscribe",
;; JUPYTER_TOKEN).  Against an older bridge the REPL still works, minus
;; live streaming and kernel-state reporting.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ansi-color)

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
Tall images are scrollable when `jsonyter-slice-images' is on, so this
is usually unnecessary; set it if you would rather shrink huge plots to
fit than scroll through them."
  :type '(choice (const :tag "No limit" nil) integer))

(defcustom jsonyter-slice-images t
  "If non-nil, insert images as a stack of one-line-tall slices.

Emacs scrolls by whole lines, and an image inserted the ordinary way
occupies a single line however tall it is.  That makes a plot taller
than the window all-or-nothing: scrolling either steps clean over it or
lands mid-image showing only its bottom edge, and the image can never be
brought fully into view.  Slicing it across as many lines as it is tall
\(what `doc-view' does for page images) lets ordinary line scrolling walk
through it like normal text."
  :type 'boolean)

(defcustom jsonyter-render-html t
  "If non-nil, render text/html output with shr when libxml is available."
  :type 'boolean)

(defcustom jsonyter-shutdown-on-kill t
  "If non-nil, shut the kernel down when its REPL buffer is killed."
  :type 'boolean)

(defcustom jsonyter-history-size 500
  "Maximum number of inputs kept in the REPL history."
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
  "The jsonyter bridge process for this REPL buffer.
The bridge handles requests concurrently, so control messages such as
`interrupt_kernel' are serviced on this same process while an execute
is still running.")
(defvar-local jsonyter--command nil
  "The exact bridge command this buffer was started with.")
(defvar-local jsonyter--url nil)
(defvar-local jsonyter--language nil)
(defvar-local jsonyter--kernel-id nil)
(defvar-local jsonyter--kernel-name nil)
(defvar-local jsonyter--kernel-state nil
  "Last kernel execution state reported by a subscription event.")
(defvar-local jsonyter--callbacks nil
  "Hash table mapping request id to a handler plist (:result F :output F).")
(defvar-local jsonyter--next-id 0)
(defvar-local jsonyter--busy nil
  "Non-nil while an execute request of ours is in flight.")
(defvar-local jsonyter--execution-count 0)
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
                       (plist-get (plist-get msg :error) :message))))))))))))

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
  "Handle an async kernel event line MSG from the bridge."
  (let* ((event (plist-get msg :event))
         (type (plist-get event :type)))
    (pcase type
      ("status"
       ;; A kernel shutting down reports `idle' on its way out, after the
       ;; shutdown_reply that told us it is gone — so once dead, stay dead
       ;; until a restart resubscribes.  A dropped socket is different: it
       ;; can come back on its own, and a status event is the proof.
       ;; Current bridges suppress that trailing status themselves, which
       ;; makes this a no-op there; it stays for older ones.
       (unless (equal jsonyter--kernel-state "dead")
         (setq jsonyter--kernel-state (plist-get event :execution_state))))
      ("dead"
       (cond
        ((eq (plist-get event :restart) t)
         (setq jsonyter--kernel-state "restarting")
         (jsonyter--announce "[kernel is restarting]"))
        (t
         (setq jsonyter--kernel-state "dead")
         (setq jsonyter--busy nil)
         (jsonyter--announce "[kernel died — C-c C-r to restart]"))))
      ("disconnected"
       (setq jsonyter--kernel-state "disconnected")
       (jsonyter--announce (format "[kernel connection lost: %s]"
                               (or (plist-get event :message) "unknown"))))
      (_ nil))
    (force-mode-line-update)))

(defun jsonyter--sentinel (proc event)
  "Note bridge PROC state changes (EVENT) in its REPL buffer."
  (let ((buf (process-get proc 'jsonyter-repl-buffer)))
    (when (and (buffer-live-p buf) (not (process-live-p proc)))
      (with-current-buffer buf
        (when (eq proc jsonyter--process)
          (setq jsonyter--busy nil
                jsonyter--kernel-state "dead")
          (jsonyter--announce (format "\n[jsonyter bridge exited: %s]"
                                  (string-trim event)))
          (force-mode-line-update))))))

(defun jsonyter--send (method params &optional handlers)
  "Send METHOD with PARAMS on this buffer's bridge.
HANDLERS is a plist: :result is called with the final reply plist,
:output with each incremental output.  Returns the request id."
  (unless (process-live-p jsonyter--process)
    (error "jsonyter: bridge process is not running (M-x jsonyter-start-%s to reconnect)"
           (or jsonyter--language "python")))
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
        (error "jsonyter: %s" (or (plist-get err :message) err))))
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

(defun jsonyter--live-p ()
  "Non-nil if this buffer has a kernel and a running bridge process."
  (and jsonyter--kernel-id (process-live-p jsonyter--process)))

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
    (define-key map (kbd "C-c C-d") #'jsonyter-repl-inspect)
    (define-key map (kbd "C-c C-k") #'jsonyter-reset)
    (define-key map (kbd "C-c M-o") #'jsonyter-repl-clear)
    map)
  "Keymap for `jsonyter-repl-mode'.")

(defun jsonyter--mode-line-string ()
  "Mode-line indicator: our request state, else the kernel's own state."
  (cond
   (jsonyter--busy ":run")
   ((equal jsonyter--kernel-state "dead") ":dead")
   ((equal jsonyter--kernel-state "restarting") ":restarting")
   ((equal jsonyter--kernel-state "disconnected") ":offline")
   ;; Busy without a request of ours in flight: another client is using
   ;; this kernel.
   ((equal jsonyter--kernel-state "busy") ":run[ext]")
   ((equal jsonyter--kernel-state "starting") ":starting")
   (t ":idle")))

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

(defun jsonyter--announce (text)
  "Report TEXT wherever this buffer's kind of transcript lives.
A REPL's transcript *is* its buffer text, so notes belong inline.  A
notebook buffer's text is the notebook's own source — writing a note
into it would corrupt the document — so those go to the echo area."
  (if (derived-mode-p 'jsonyter-repl-mode)
      (jsonyter--note text)
    (message "jsonyter: %s" (string-trim (string-trim text) "\\[" "\\]"))))

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

(defun jsonyter--image-rows (image)
  "How many text lines IMAGE should be sliced across, or nil for one.
Returns nil when slicing is off, when there is no graphical display, or
when the image's displayed size cannot be measured."
  (and jsonyter-slice-images
       (display-graphic-p)
       (ignore-errors
         (let ((pixel-height (cdr (image-size image t)))
               (line-height (max 1 (default-font-height))))
           (max 1 (ceiling pixel-height line-height))))))

(defun jsonyter--insert-image (image alt)
  "Insert IMAGE at point with ALT as its text fallback.
Tall images are sliced one text line per row so that line-based
scrolling can move through them; see `jsonyter-slice-images'."
  (let ((rows (jsonyter--image-rows image)))
    (if (and rows (> rows 1))
        ;; `insert-sliced-image' repeats its string once per row, so it
        ;; gets a single space (as `doc-view' does) rather than ALT --
        ;; otherwise the buffer's real text, and anything copied out of
        ;; it, is the alt text repeated once per slice. It also
        ;; terminates each row with its own newline, so no trailing one
        ;; is needed here.
        (insert-sliced-image image " " nil rows 1)
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
   (jsonyter--busy
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
                (list :kernel_id jsonyter--kernel-id
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
   (jsonyter--busy (message "jsonyter: kernel is busy"))
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
  (setq jsonyter--history-index -1
        jsonyter--history-stash nil
        jsonyter--busy t
        jsonyter--clear-pending nil)
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
        (params (append (list :kernel_id jsonyter--kernel-id :code code)
                        (and jsonyter-stream-output '(:stream t)))))
    (jsonyter--send
     "execute" params
     (list
      :output (lambda (output)
                (cl-incf streamed)
                (jsonyter--stream-output output))
      :result
      (lambda (msg)
        (setq jsonyter--busy nil)
        (force-mode-line-update)
        (let ((err (plist-get msg :error))
              (result (plist-get msg :result)))
          (cond
           (err
            (jsonyter--note (format "[execute failed: %s]"
                                    (plist-get err :message))))
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
        (jsonyter--insert-prompt))))))

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
             (not jsonyter--busy)
             (marker-position jsonyter--input-start)
             (>= (point) jsonyter--input-start))
    (let* ((code (jsonyter--current-input))
           (pos (- (point) jsonyter--input-start))
           (reply (ignore-errors
                    (jsonyter--kernel-request
                     "complete"
                     (list :kernel_id jsonyter--kernel-id
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
  (when jsonyter--busy (user-error "Kernel is busy"))
  (let* ((code (jsonyter--current-input))
         (pos (max 0 (min (length code) (- (point) jsonyter--input-start))))
         (reply (jsonyter--kernel-request
                 "inspect"
                 (list :kernel_id jsonyter--kernel-id
                       :code code :cursor_pos pos)))
         (text (and (eq (plist-get reply :found) t)
                    (jsonyter--mime (plist-get reply :data) :text/plain))))
    (if (not text)
        (message "jsonyter: no documentation found")
      (with-help-window "*jsonyter-doc*"
        (with-current-buffer standard-output
          (insert (ansi-color-apply text)))))))

;;;; Kernel control

(defun jsonyter--subscribe ()
  "Subscribe to async kernel state events, if the bridge supports it."
  (when jsonyter-subscribe-events
    (condition-case err
        (let ((reply (jsonyter--request-sync
                      "subscribe" (list :kernel_id jsonyter--kernel-id))))
          (setq jsonyter--kernel-state (plist-get reply :execution_state))
          t)
      (error
       ;; An older bridge has no `subscribe'; the REPL works fine without
       ;; it, only the mode line goes quiet.
       (setq jsonyter--kernel-state nil)
       (message "jsonyter: kernel events unavailable (%s)"
                (error-message-string err))
       nil))))

(defun jsonyter-interrupt ()
  "Interrupt the kernel.
The bridge handles requests concurrently, so this is acted on
immediately even while an execute is still running."
  (interactive)
  (unless jsonyter--kernel-id (user-error "No kernel in this buffer"))
  (jsonyter--request-sync "interrupt_kernel"
                          (list :kernel_id jsonyter--kernel-id))
  (message "jsonyter: interrupt sent"))

(defun jsonyter-restart ()
  "Restart the kernel, keeping the same kernel id."
  (interactive)
  (unless jsonyter--kernel-id (user-error "No kernel in this buffer"))
  (when (yes-or-no-p "Restart the kernel (all state will be lost)? ")
    (jsonyter--request-sync "restart_kernel"
                            (list :kernel_id jsonyter--kernel-id)
                            jsonyter-startup-timeout)
    ;; Drop the now-stale websocket so the next execute reconnects
    ;; cleanly.  This also drops the event subscription, so renew it.
    (ignore-errors
      (jsonyter--request-sync "disconnect"
                              (list :kernel_id jsonyter--kernel-id)))
    (setq jsonyter--busy nil
          jsonyter--execution-count 0
          jsonyter--clear-pending nil)
    (jsonyter--subscribe)
    (jsonyter--after-kernel-reset "[kernel restarted]")))

(defun jsonyter-shutdown ()
  "Shut the kernel down and stop the bridge process."
  (interactive)
  (unless jsonyter--kernel-id (user-error "No kernel in this buffer"))
  (when (yes-or-no-p "Shut the kernel down? ")
    (ignore-errors
      (jsonyter--request-sync "shutdown_kernel"
                              (list :kernel_id jsonyter--kernel-id)))
    (setq jsonyter--kernel-id nil
          jsonyter--busy nil
          jsonyter--kernel-state "dead")
    (jsonyter--kill-process)
    (jsonyter--announce "\n[kernel shut down]")))

(defun jsonyter-reset ()
  "Recover a REPL stuck at a \"kernel is busy\" prompt.
Abandons any in-flight requests, clears the busy flag and draws a fresh
prompt.  The kernel is left running: if it is genuinely still working,
interrupt it with \\[jsonyter-interrupt] first, or this prompt will sit
alongside output that is still on its way."
  (interactive)
  (when jsonyter--callbacks (clrhash jsonyter--callbacks))
  (setq jsonyter--busy nil
        jsonyter--clear-pending nil)
  (force-mode-line-update)
  (jsonyter--after-kernel-reset "[reset — kernel left running]"))

(defun jsonyter--after-kernel-reset (text)
  "Put this buffer back in a usable state after a restart or reset.
A REPL gets TEXT in its transcript and a fresh prompt.  A notebook gets
neither — writing into its text would corrupt the document — but its
cells' execution counts are blanked, since the kernel's counter has gone
back to zero and the old numbers no longer mean anything."
  (if (derived-mode-p 'jsonyter-repl-mode)
      (progn (jsonyter--note (concat "\n" text))
             (jsonyter--insert-prompt))
    (when (bound-and-true-p jsonyter-notebook-mode)
      (dolist (cell (jsonyter--nb-cells))
        (overlay-put cell 'jsonyter-exec-count nil)
        (overlay-put cell 'jsonyter-running nil)
        (jsonyter--nb-refresh-prompt cell)))
    (jsonyter--announce text)))

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
  "Kill-buffer hook: shut down the kernel and the bridge process."
  (when (and jsonyter-shutdown-on-kill
             jsonyter--kernel-id
             (process-live-p jsonyter--process))
    ;; Safe even mid-execute: shutdown_kernel is a REST call and runs on
    ;; the bridge's pool, not behind the kernel's queue.
    (ignore-errors
      (jsonyter--request-sync "shutdown_kernel"
                              (list :kernel_id jsonyter--kernel-id) 5)))
  (jsonyter--kill-process))

;;;; Starting REPLs

(defun jsonyter--connect-kernel (language)
  "Give the current buffer its own bridge process and LANGUAGE kernel.
Sets up all of the connection-related buffer-local state, subscribes to
kernel events, and leaves the buffer ready to send requests.  Shared by
REPL buffers and notebook buffers, which differ only in how they render
what comes back.

Every step is awaited in turn: the bridge opens one websocket per
kernel, and issuing two connection-opening requests concurrently is a
race that older bridges lose."
  (setq jsonyter--language language
        jsonyter--url jsonyter-server-url)
  (setq jsonyter--process (jsonyter--start-bridge))
  (let* ((name (jsonyter--resolve-kernel-name language))
         (kernel (jsonyter--request-sync "start_kernel" (list :name name)
                                         jsonyter-startup-timeout)))
    (setq jsonyter--kernel-id (plist-get kernel :id)
          jsonyter--kernel-name (plist-get kernel :name)
          jsonyter--kernel-state (plist-get kernel :execution_state)))
  (jsonyter--subscribe)
  jsonyter--kernel-id)

(defun jsonyter--start-repl (language)
  "Start (or pop to) a Jupyter REPL for LANGUAGE."
  (let* ((bufname (format "*jsonyter[%s]*" language))
         (existing (get-buffer bufname)))
    (if (and existing
             (buffer-local-value 'jsonyter--kernel-id existing)
             (process-live-p (buffer-local-value 'jsonyter--process existing)))
        (pop-to-buffer existing)
      (when existing (kill-buffer existing))
      (let ((buffer (get-buffer-create bufname)))
        (condition-case err
            (with-current-buffer buffer
              (jsonyter-repl-mode)
              (jsonyter--connect-kernel language)
              (jsonyter--note
               (format (concat "Jupyter REPL — kernel %s (%s) on %s\n"
                               "RET send · TAB complete · C-c C-c interrupt · "
                               "C-c C-r restart · C-c C-d doc · M-p/M-n history")
                       jsonyter--kernel-name
                       (substring jsonyter--kernel-id 0 8)
                       jsonyter--url))
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

;; A notebook buffer holds nothing but the cells' source text.  Prompts,
;; separators and every rendered output live in overlay strings instead,
;; which is what lets outputs be read-only and invisible to undo while
;; the source stays ordinary, editable, font-locked text: undo walks
;; your edits and never your results, and no edit can corrupt an output
;; region because there is no output region in the text to corrupt.
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

(defcustom jsonyter-notebook-separator-width 62
  "Width of the rule drawn beside a notebook cell's prompt."
  :type 'integer)

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

(defvar-local jsonyter--nb-metadata nil
  "The notebook's top-level metadata plist, as read from the file.")
(defvar-local jsonyter--nb-format nil
  "Cons of (NBFORMAT . NBFORMAT-MINOR) as read from the file.")
(defvar-local jsonyter--nb-running-cell nil
  "Overlay of the cell currently executing, if any.")

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

(defun jsonyter--nb-render-string (output)
  "Render one OUTPUT (already in kernel shape) to a propertized string.
Rendering happens in a scratch buffer so the existing output renderer —
images, sliced scrolling, ANSI, shr — can be reused verbatim; the
resulting text, display properties and all, becomes an overlay string."
  (with-temp-buffer
    (setq-local jsonyter--clear-pending nil)
    (setq-local jsonyter--output-start (copy-marker (point-min)))
    (setq-local jsonyter--output-end (copy-marker (point-max) t))
    (condition-case err
        (jsonyter--render-output output)
      (error (insert (format "[jsonyter: cannot render %s output: %s]\n"
                             (plist-get output :type)
                             (error-message-string err)))))
    (buffer-string)))

(defun jsonyter--nb-outputs-string (rendered)
  "Wrap RENDERED output text for display beneath a cell."
  (if (or (null rendered) (string-empty-p rendered))
      ""
    (concat (propertize rendered
                        'read-only t
                        'front-sticky '(read-only)
                        'rear-nonsticky t)
            (if (string-suffix-p "\n" rendered) "" "\n"))))

;;; Cell overlays

(defun jsonyter--nb-prompt (cell-type exec-count &optional running)
  "Prompt string shown above a cell of CELL-TYPE with EXEC-COUNT.
RUNNING marks a cell whose execution is still in flight."
  (let* ((markdown (equal cell-type "markdown"))
         (label (cond (markdown "Markdown")
                      (running "In [*]:")
                      (t (format "In [%s]:" (or exec-count " ")))))
         (rule (make-string (max 4 (- jsonyter-notebook-separator-width
                                      (length label)))
                            ?─)))
    (concat "\n"
            (propertize label 'face (if markdown
                                        'jsonyter-notebook-markdown-face
                                      'jsonyter-notebook-cell-face))
            " "
            (propertize rule 'face 'jsonyter-notebook-rule-face)
            "\n")))

(defun jsonyter--nb-refresh-prompt (cell)
  "Update CELL's prompt overlay string from its stored state."
  (overlay-put cell 'before-string
               (jsonyter--nb-prompt (overlay-get cell 'jsonyter-cell-type)
                                    (overlay-get cell 'jsonyter-exec-count)
                                    (overlay-get cell 'jsonyter-running))))

(defun jsonyter--nb-refresh-output (cell)
  "Update CELL's output overlay string from its stored rendered text."
  (let ((body (jsonyter--nb-outputs-string
               (overlay-get cell 'jsonyter-output-string))))
    (overlay-put
     cell 'after-string
     (if (string-empty-p body)
         ""
       ;; Output must begin on a line of its own.  A notebook cell always
       ;; ends with its own newline, but a script cell can end mid-line —
       ;; the last cell of a file with no final newline — and an
       ;; after-string there is displayed running on from the last line
       ;; of code, which is exactly where print output must not appear.
       (let ((end (overlay-end cell)))
         (if (or (= end (point-min)) (eq (char-before end) ?\n))
             body
           (concat "\n" body)))))))

(defun jsonyter--nb-make-cell (start end cell)
  "Create the overlay for CELL spanning START..END.
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
    (jsonyter--nb-refresh-prompt ov)
    (let ((rendered (mapconcat (lambda (o)
                                 (jsonyter--nb-render-string
                                  (jsonyter--nb-adapt-output o)))
                               (plist-get cell :outputs) "")))
      (overlay-put ov 'jsonyter-output-string rendered)
      (jsonyter--nb-refresh-output ov))
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
  "The source text of CELL, without its trailing newline."
  (let ((text (buffer-substring-no-properties (overlay-start cell)
                                              (overlay-end cell))))
    (if (string-suffix-p "\n" text) (substring text 0 -1) text)))

;;; Building the buffer

(defun jsonyter--nb-render (notebook)
  "Replace the current buffer with a rendered view of NOTEBOOK."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (dolist (cell (plist-get notebook :cells))
      (let ((start (point)))
        (insert (jsonyter--nb-text (plist-get cell :source)))
        (unless (bolp) (insert "\n"))
        (jsonyter--nb-make-cell start (point) cell)))
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
      (message "jsonyter: kernel already running (%s)" jsonyter--kernel-name)
    (let ((language (or jsonyter--language "python")))
      (message "jsonyter: starting %s kernel..." language)
      (jsonyter--connect-kernel language)
      (message "jsonyter: kernel %s ready" jsonyter--kernel-name))))

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
  (unless (overlay-get cell 'jsonyter-script-cell)
    (setq jsonyter--nb-outputs-dirty t))
  (jsonyter--nb-refresh-output cell))

(defun jsonyter--nb-append-output (cell output)
  "Append one kernel OUTPUT to CELL, honoring clear_output."
  (if (equal (plist-get output :type) "clear_output")
      (jsonyter--nb-set-output cell "" nil t)
    (jsonyter--nb-set-output
     cell (concat (or (overlay-get cell 'jsonyter-output-string) "")
                  (jsonyter--nb-render-string output))
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
     ((equal (overlay-get cell 'jsonyter-cell-type) "markdown")
      (message "jsonyter: markdown cell — nothing to execute"))
     (jsonyter--busy
      (message "jsonyter: kernel is busy (C-c C-c to interrupt)"))
     (t
      (jsonyter--nb-ensure-kernel)
      (let ((code (jsonyter--nb-cell-source cell)))
        (if (string-blank-p code)
            (message "jsonyter: empty cell")
          ;; Re-running replaces the previous result outright, which is
          ;; what makes outputs disposable rather than accumulating. This
          ;; also marks the cell touched, so it is what makes a freshly
          ;; (re-)run cell eligible for `jsonyter-notebook-save-with-outputs'
          ;; even if the run produces nothing further.
          (jsonyter--nb-set-output cell "" nil t)
          (overlay-put cell 'jsonyter-running t)
          (jsonyter--nb-refresh-prompt cell)
          (setq jsonyter--busy t
                jsonyter--nb-running-cell cell)
          (force-mode-line-update)
          (jsonyter--send
           "execute"
           (append (list :kernel_id jsonyter--kernel-id :code code)
                   (and jsonyter-stream-output '(:stream t)))
           (list
            :output (lambda (output) (jsonyter--nb-append-output cell output))
            :result
            (lambda (msg)
              (setq jsonyter--busy nil
                    jsonyter--nb-running-cell nil)
              (overlay-put cell 'jsonyter-running nil)
              (let ((err (plist-get msg :error))
                    (result (plist-get msg :result)))
                (cond
                 (err
                  (jsonyter--nb-set-output
                   cell (propertize (format "[execute failed: %s]\n"
                                            (plist-get err :message))
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
    (unless (equal (overlay-get cell 'jsonyter-cell-type) "markdown")
      (goto-char (overlay-start cell))
      (jsonyter-notebook-run-cell)
      (let ((deadline (+ (float-time) 3600)))
        (while (and jsonyter--busy (< (float-time) deadline))
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
    (unless (equal (overlay-get cell 'jsonyter-cell-type) "markdown")
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
  (let ((start (point)))
    (insert "\n")
    (jsonyter--nb-make-cell start (point)
                            (list :id nil :cell_type cell-type :outputs nil))
    (goto-char start)))

(defun jsonyter-notebook-insert-cell-below (&optional markdown)
  "Insert an empty code cell below the cell at point.
With a prefix argument (MARKDOWN), insert a markdown cell instead."
  (interactive "P")
  (let ((cell (jsonyter--nb-cell-at)))
    (jsonyter--nb-insert-cell (if cell (overlay-end cell) (point-max))
                              (if markdown "markdown" "code"))))

(defun jsonyter-notebook-insert-cell-above (&optional markdown)
  "Insert an empty code cell above the cell at point.
With a prefix argument (MARKDOWN), insert a markdown cell instead."
  (interactive "P")
  (let ((cell (jsonyter--nb-cell-at)))
    (jsonyter--nb-insert-cell (if cell (overlay-start cell) (point-min))
                              (if markdown "markdown" "code"))))

(defun jsonyter-notebook-delete-cell ()
  "Delete the cell at point, source and output together."
  (interactive)
  (let ((cell (jsonyter--nb-cell-at)))
    (unless cell (user-error "No cell at point"))
    (when (or (string-blank-p (jsonyter--nb-cell-source cell))
              (yes-or-no-p "Delete this cell? "))
      (let ((start (overlay-start cell)) (end (overlay-end cell)))
        (delete-overlay cell)
        (delete-region start end)))))

(defun jsonyter-notebook-change-cell-type ()
  "Toggle the cell at point between code and markdown.
A cell turned into markdown loses its output, since markdown cells
cannot carry any — the same rule the bridge applies when writing."
  (interactive)
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
    jsonyter-output-string)
  "Overlay properties making up a cell's identity, as opposed to position.
These are the things that must travel with the text when cells move.")

(defun jsonyter--nb-swap-cells (a b)
  "Exchange the text and identity of adjacent cells A and B (A before B)."
  (let* ((cells (jsonyter--nb-cells))
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
    ;; move with it.
    (dolist (p b-props) (overlay-put a (car p) (cdr p)))
    (dolist (p a-props) (overlay-put b (car p) (cdr p)))
    (jsonyter--nb-refresh-prompt a) (jsonyter--nb-refresh-output a)
    (jsonyter--nb-refresh-prompt b) (jsonyter--nb-refresh-output b)
    (goto-char (overlay-start b))))

(defun jsonyter-notebook-move-cell-down ()
  "Move the cell at point below the following cell."
  (interactive)
  (let* ((cell (jsonyter--nb-cell-at))
         (next (and cell (seq-find (lambda (o) (> (overlay-start o)
                                                  (overlay-start cell)))
                                   (jsonyter--nb-cells)))))
    (unless cell (user-error "No cell at point"))
    (if next (jsonyter--nb-swap-cells cell next)
      (message "jsonyter: already the last cell"))))

(defun jsonyter-notebook-move-cell-up ()
  "Move the cell at point above the preceding cell."
  (interactive)
  (let* ((cell (jsonyter--nb-cell-at))
         (prev (and cell (car (last (seq-filter
                                     (lambda (o) (< (overlay-start o)
                                                    (overlay-start cell)))
                                     (jsonyter--nb-cells)))))))
    (unless cell (user-error "No cell at point"))
    (if prev (jsonyter--nb-swap-cells prev cell)
      (message "jsonyter: already the first cell"))))

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
    (define-key map (kbd "C-c M-o") #'jsonyter-notebook-clear-cell-output)
    (define-key map (kbd "C-c M-O") #'jsonyter-notebook-clear-all-output)
    (define-key map (kbd "C-c C-k") #'jsonyter-notebook-start-kernel)
    (define-key map (kbd "C-c C-a") #'jsonyter-notebook-insert-cell-above)
    (define-key map (kbd "C-c C-i") #'jsonyter-notebook-insert-cell-below)
    (define-key map (kbd "C-c C-w") #'jsonyter-notebook-delete-cell)
    (define-key map (kbd "C-c C-t") #'jsonyter-notebook-change-cell-type)
    (define-key map (kbd "C-c <up>") #'jsonyter-notebook-move-cell-up)
    (define-key map (kbd "C-c <down>") #'jsonyter-notebook-move-cell-down)
    (define-key map (kbd "C-x C-s") #'jsonyter-notebook-save-buffer)
    (define-key map (kbd "C-c C-s") #'jsonyter-notebook-save-with-outputs)
    map)
  "Keymap for `jsonyter-notebook-mode'.")

(define-minor-mode jsonyter-notebook-mode
  "Minor mode for Jupyter notebooks rendered by jsonyter.

Layered over the notebook language's own major mode, so syntax
highlighting and indentation are the language's own.  Cell prompts and
outputs are overlay strings, not buffer text, so undo and editing see
only the cell source.

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
        (add-hook 'write-contents-functions #'jsonyter-notebook-save nil t)
        (add-hook 'kill-buffer-hook #'jsonyter--cleanup nil t)
        (jsonyter-mode 1))
    (remove-hook 'write-contents-functions #'jsonyter-notebook-save t)
    (remove-hook 'kill-buffer-hook #'jsonyter--cleanup t)
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
          jsonyter--language language
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

(defun jsonyter--script-output-overlay (start end)
  "The output overlay for the cell spanning START..END, creating it once."
  (or (seq-find (lambda (o) (overlay-get o 'jsonyter-script-cell))
                (overlays-in (max (point-min) (1- end)) end))
      (let ((ov (make-overlay (max start (1- end)) end)))
        (overlay-put ov 'jsonyter-script-cell t)
        (push ov jsonyter--script-cells)
        ov)))

(defun jsonyter-script-run-cell (&optional advance)
  "Execute the script cell at point, showing its output inline.
With ADVANCE, move to the next cell afterwards."
  (interactive)
  (when jsonyter--busy
    (user-error "jsonyter: kernel is busy (C-c C-c to interrupt)"))
  (unless (jsonyter--live-p)
    (jsonyter--connect-kernel (jsonyter--script-language)))
  (pcase-let* ((`(,start . ,end) (jsonyter--script-cell-bounds))
               (code (string-trim (buffer-substring-no-properties start end)))
               (ov (jsonyter--script-output-overlay start end)))
    (if (string-blank-p code)
        (message "jsonyter: empty cell")
      (overlay-put ov 'jsonyter-output-string "")
      (jsonyter--nb-refresh-output ov)
      (setq jsonyter--busy t)
      (force-mode-line-update)
      (jsonyter--send
       "execute"
       (append (list :kernel_id jsonyter--kernel-id :code code)
               (and jsonyter-stream-output '(:stream t)))
       (list
        :output (lambda (output) (jsonyter--nb-append-output ov output))
        :result (lambda (msg)
                  (setq jsonyter--busy nil)
                  (force-mode-line-update)
                  (let ((err (plist-get msg :error))
                        (result (plist-get msg :result)))
                    (cond
                     (err (jsonyter--nb-set-output
                           ov (format "[execute failed: %s]\n"
                                      (plist-get err :message))))
                     (result
                      (let ((drawn (overlay-get ov 'jsonyter-output-string)))
                        (when (and (or (null drawn) (string-empty-p drawn))
                                   (plist-get result :outputs))
                          (dolist (o (plist-get result :outputs))
                            (jsonyter--nb-append-output ov o))))))))))))
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
  (forward-line -1)
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
        (jsonyter-mode 1))
    (jsonyter-script-clear-all-output)
    (remove-hook 'kill-buffer-hook #'jsonyter--cleanup t)
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

(provide 'jsonyter)
;;; jsonyter.el ends here
