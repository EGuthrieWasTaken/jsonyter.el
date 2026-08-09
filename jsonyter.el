;;; jsonyter.el --- Interactive Jupyter REPLs via the jsonyter bridge -*- lexical-binding: t; -*-

;; Author: Ethan Guthrie
;; Version: 0.2.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: languages, processes, jupyter
;; URL: https://github.com/eguthrie/jsonyter.el

;;; Commentary:

;; Interactive Jupyter REPL buffers for Emacs, backed by the `jsonyter'
;; Python package (https://github.com/eguthrie/jsonyter), which exposes a
;; Jupyter server as a line-oriented JSON protocol over stdin/stdout.
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
is not on `exec-path'."
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
(defvar-local jsonyter--is-complete-supported t)
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
           (proc (make-process
                  :name "jsonyter"
                  :command jsonyter--command
                  :connection-type 'pipe
                  :noquery t
                  :coding 'utf-8-unix
                  :stderr stderr-buffer
                  :filter #'jsonyter--filter
                  :sentinel #'jsonyter--sentinel)))
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
                (jsonyter--note (format "[unparseable bridge output: %s]"
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
              (jsonyter--note
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
       (unless (equal jsonyter--kernel-state "dead")
         (setq jsonyter--kernel-state (plist-get event :execution_state))))
      ("dead"
       (cond
        ((eq (plist-get event :restart) t)
         (setq jsonyter--kernel-state "restarting")
         (jsonyter--note "[kernel is restarting]"))
        (t
         (setq jsonyter--kernel-state "dead")
         (setq jsonyter--busy nil)
         (jsonyter--note "[kernel died — C-c C-r to restart]"))))
      ("disconnected"
       (setq jsonyter--kernel-state "disconnected")
       (jsonyter--note (format "[kernel connection lost: %s]"
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
          (jsonyter--note (format "\n[jsonyter bridge exited: %s]"
                                  (string-trim event)))
          (force-mode-line-update))))))

(defun jsonyter--send (method params &optional handlers)
  "Send METHOD with PARAMS on this buffer's bridge.
HANDLERS is a plist: :result is called with the final reply plist,
:output with each incremental output.  Returns the request id."
  (unless (process-live-p jsonyter--process)
    (error "jsonyter: bridge process is not running (M-x jsonyter-start-%s to reconnect)"
           (or jsonyter--language "python")))
  (let* ((id (cl-incf jsonyter--next-id))
         (request (if params
                      (list :id id :method method :params params)
                    (list :id id :method method))))
    (puthash id (or handlers '(:result ignore)) jsonyter--callbacks)
    (process-send-string jsonyter--process
                         (concat (json-serialize request) "\n"))
    id))

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
             (if (process-live-p proc) "" " (bridge process died)")))
    (let ((err (plist-get reply :error)))
      (when err
        (error "jsonyter: %s" (or (plist-get err :message) err))))
    (plist-get reply :result)))

(defun jsonyter--live-p ()
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
  (add-hook 'kill-buffer-hook #'jsonyter--cleanup nil t))

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

(defun jsonyter--insert-encoded-image (base64-data type)
  "Insert an inline image of TYPE from BASE64-DATA, with a text fallback."
  (let* ((clean (replace-regexp-in-string "[ \t\r\n]" "" base64-data))
         (raw (ignore-errors (base64-decode-string clean)))
         (image (and raw
                     (ignore-errors
                       (apply #'create-image raw type t
                              (and jsonyter-image-max-width
                                   (list :max-width jsonyter-image-max-width)))))))
    (if (not image)
        (insert (format "[%s image: could not decode]\n" type))
      (insert-image image (format "[%s image]" type))
      (insert "\n"))))

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
    (insert-image (create-image (jsonyter--mime data :image/svg+xml) 'svg t)
                  "[svg image]")
    (insert "\n"))
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

(defun jsonyter--is-complete (code)
  "Ask the kernel whether CODE is complete input; nil if unavailable.
Stops asking for the rest of the session after the first failure, so a
kernel that does not implement is_complete costs one round trip, not
one per RET."
  (when (and jsonyter-use-is-complete jsonyter--is-complete-supported)
    (condition-case err
        (jsonyter--request-sync "is_complete"
                                (list :kernel_id jsonyter--kernel-id
                                      :code code))
      (error
       (setq jsonyter--is-complete-supported nil)
       (message "jsonyter: is_complete unavailable (%s); RET now always sends"
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
                    (jsonyter--request-sync
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
         (reply (jsonyter--request-sync
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
    (jsonyter--note "\n[kernel restarted]")
    (jsonyter--insert-prompt)))

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
    (jsonyter--note "\n[kernel shut down]")))

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
              (setq jsonyter--language language
                    jsonyter--url jsonyter-server-url)
              (setq jsonyter--process (jsonyter--start-bridge))
              (let* ((name (jsonyter--resolve-kernel-name language))
                     (kernel (jsonyter--request-sync
                              "start_kernel" (list :name name)
                              jsonyter-startup-timeout)))
                (setq jsonyter--kernel-id (plist-get kernel :id)
                      jsonyter--kernel-name (plist-get kernel :name)
                      jsonyter--kernel-state (plist-get kernel
                                                        :execution_state)))
              (jsonyter--subscribe)
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

(provide 'jsonyter)
;;; jsonyter.el ends here
