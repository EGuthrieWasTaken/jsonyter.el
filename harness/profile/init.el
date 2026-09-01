;;; init.el --- the sandboxed Emacs config for the jsonyter profile -*- lexical-binding: t; -*-

;; The *only* configuration the Emacs under test sees beyond the
;; harness's own determinism block (emacs-harness DESIGN.md 7.1, 8.4).
;; Everything here is either what jsonyter's own README tells a user to
;; write, or something the harness needs to be deterministic -- and
;; nothing else.  A profile that quietly works around a rough edge is a
;; profile that stops finding it.

;; `profile.el' -- the manifest of waiters, snapshot properties and log
;; buffers -- is loaded from here, not by the harness core.  Skipping
;; this line is silent: the session still starts, but `eh wait
;; jsonyter-idle' fails with "no such waiter" forever.
(load (expand-file-name "profile.el" eh-profile-dir))

;;;; The package under test

;; Bind-mounted read-only at /srv/package by `eh run'.  The environment
;; override is what lets the same profile run under batch ERT against a
;; working tree, with no container (see harness/README.md).
(defvar jy-harness-package-dir
  (or (getenv "JSONYTER_SRC") "/srv/package")
  "Where jsonyter.el is being read from.")

(add-to-list 'load-path jy-harness-package-dir)
(require 'jsonyter)

;;;; Exactly what the README tells a user to write

(add-to-list 'auto-mode-alist '("\\.ipynb\\'" . jsonyter-notebook-open))
(add-hook 'python-mode-hook #'jsonyter-script-mode-maybe)
(add-hook 'org-mode-hook #'jsonyter-org-mode-maybe)

(setq jsonyter-server-url "http://127.0.0.1:8888"
      jsonyter-server-token nil
      jsonyter-server-token-file nil)

;;;; Determinism

;; Shorter than the defaults on purpose.  These bound how long a *broken*
;; run takes to report itself, and the fake bridge answers in
;; milliseconds; the 120s startup default would turn one wrong fixture
;; into a two-minute CI stall with nothing to show for it.  Scenarios
;; that need the real timeout behaviour let-bind it themselves.
(setq jsonyter-startup-timeout 20
      jsonyter-request-timeout 5
      jsonyter-exec-timeout nil)

;; Kernel spec resolution is scripted in base.jsonl, and pinning the name
;; here would skip it -- so leave `jsonyter-kernel-names' alone.

;;;; Pointing jsonyter at the fake bridge

;; The substitution the whole profile turns on: `jsonyter-command' is
;; jsonyter's own "how do I launch my backend" option, so the package
;; starts its bridge exactly as it always does, appends its own --url and
;; token flags, and never learns that what answers is a fixture.
;;
;; The default covers the everyday path.  A scenario that needs a
;; different backend calls `jy-use-scripts' before it opens anything.

(defun jy-use-scripts (&rest scripts)
  "Point `jsonyter-command' at `eh-fake-bridge' running SCRIPTS.

SCRIPTS come first, then `base.jsonl' (the connection lifecycle every
buffer walks through), then `python.jsonl' (the everyday execute rules).
Rules match in order and first match wins, so that ordering is what lets
a scenario's script *override* the defaults rather than merely add to
them -- `unauthorized.jsonl' has to answer the very `list_kernelspecs'
that `base.jsonl' answers happily, and layering it after base would
leave it dead code that never matches.

Strings that are not `.jsonl' names -- a `--fault' and its argument,
say -- pass through to `eh-fake-bridge' untouched.

Call this before the buffer that will use it exists: `jsonyter-command'
is read when the bridge process starts and never again."
  (setq jsonyter-command
        (apply #'eh-fake-bridge-command
               (append scripts (list "base.jsonl" "python.jsonl")))))

(defun jy-use-real-bridge ()
  "Point `jsonyter-command' at the real `jsonyter' Python bridge.

For the handful of scenarios the fake cannot answer: saving a notebook
goes through the bridge's own `write_notebook', so what a save produces
is a file the *backend* wrote, and a fixture cannot stand in for it.
That path needs no Jupyter server and starts no kernel -- the Python
package handles .ipynb locally -- so it stays cheap.  Scenarios that
call this must be gated on `:needs (:executable \"jsonyter\")\'."
  (setq jsonyter-command '("jsonyter")))

(jy-use-scripts)

;; Every scenario starts from the everyday fake backend, whatever the
;; scenario before it did.  `jsonyter-command' is a global: without this,
;; one scenario calling `jy-use-real-bridge' leaves every later scenario
;; pointed at a real bridge talking to a Jupyter server that is not
;; running, and they fail with a connection error that has nothing to do
;; with what they were testing.
(add-hook 'eh-scenario-setup-functions #'jy-use-scripts)

;;;; Helpers the profile's waiters and scenarios are built on
;;
;; Deliberately thin: they read jsonyter's *observable* state -- the
;; mode-line tag a user actually sees, the process that is actually
;; running -- rather than reaching into session structs.  A waiter built
;; on an internal accessor keeps passing after that internal changes
;; shape, which is the failure mode that makes a suite worthless.

(defun jy-harness--jsonyter-buffer ()
  "A live jsonyter buffer to read state from: this one, or the only one."
  (if (bound-and-true-p jsonyter-mode)
      (current-buffer)
    (seq-find (lambda (b) (buffer-local-value 'jsonyter-mode b)) (buffer-list))))

(defmacro jy-harness--in-buffer (&rest body)
  "Run BODY in the jsonyter buffer in play; nil if there isn't one."
  (declare (indent 0) (debug t))
  `(let ((buffer (jy-harness--jsonyter-buffer)))
     (when (buffer-live-p buffer)
       (with-current-buffer buffer ,@body))))

(defun jy-harness--bridge-live-p ()
  (jy-harness--in-buffer (process-live-p jsonyter--process)))

(defun jy-harness--kernel-live-p ()
  (jy-harness--in-buffer (jsonyter--live-p)))

(defun jy-harness-state ()
  "The mode-line status tag for the session in play, e.g. \":idle\".
The tag, not an internal flag: it is what a user reads, and asserting on
it means an assertion cannot pass while the mode line lies."
  (jy-harness--in-buffer (jsonyter--mode-line-string)))

(defun jy-harness--state-p (tag)
  (equal (jy-harness-state) tag))

(defun jy-harness--settled-p ()
  "Non-nil once nothing is in flight: no busy session, no pending request."
  (jy-harness--in-buffer
    (and (not (seq-some #'jsonyter--session-busy (jsonyter--session-list)))
         (or (null jsonyter--callbacks)
             (zerop (hash-table-count jsonyter--callbacks))))))

;;;; Scenario-facing helpers

(defun jy-start-repl (&optional language)
  "Start a REPL for LANGUAGE (default python) and wait for its kernel.
Returns the REPL buffer, selected.  Every scenario that needs a live
kernel starts here rather than repeating the wait, because forgetting
the wait is the one mistake that produces a suite which passes locally
and fails in CI."
  (jsonyter-start (or language "python"))
  ;; `jsonyter--start-repl' pops to the REPL, which selects its window --
  ;; but it does that from inside a `with-current-buffer', whose unwind
  ;; then puts `current-buffer' back to whatever it was.  So the session
  ;; is looking at the REPL while Lisp running here is not, and a
  ;; scenario that reads `(buffer-string)' straight after gets the empty
  ;; scratch buffer.  Key-driven assertions hide this, because
  ;; `execute-kbd-macro' goes through the command loop and follows the
  ;; selected window; anything reading buffer state directly does not.
  (set-buffer (window-buffer (selected-window)))
  (unless (bound-and-true-p jsonyter-mode)
    (error "jsonyter-harness: starting a REPL did not leave one selected"))
  (eh-wait #'jy-harness--kernel-live-p 20)
  (eh-wait #'jy-harness--settled-p 20)
  (current-buffer))

(defun jy-wait-idle (&optional timeout)
  "Wait until nothing is in flight in the jsonyter buffer in play."
  (eh-wait #'jy-harness--settled-p (or timeout 20)))

(defun jy-cells ()
  "The notebook cell overlays in this buffer, in document order."
  (jsonyter--nb-cells))

(defun jy-cell (n)
  "The Nth notebook cell overlay (0-based)."
  (or (nth n (jy-cells)) (error "jsonyter-harness: no cell %d" n)))

(defun jy-goto-cell (n)
  "Put point on the source of the Nth notebook cell (0-based)."
  (goto-char (overlay-start (jy-cell n))))

(defun jy-cell-source-region (n)
  "The (BEG END) of cell N's source text."
  (let ((cell (jy-cell n)))
    (list (overlay-start cell)
          (marker-position (overlay-get cell 'jsonyter-source-end)))))

(defun jy-cell-output-region (n)
  "The (BEG END) of cell N's rendered output, or nil if it has none."
  (let* ((cell (jy-cell n))
         (beg (marker-position (overlay-get cell 'jsonyter-source-end)))
         (end (overlay-end cell)))
    (and (< beg end) (list beg end))))

(defun jy-cell-has-output-p (n)
  "Non-nil once cell N has rendered output."
  (let ((region (jy-cell-output-region n)))
    (and region (> (- (nth 1 region) (nth 0 region)) 1))))

(defun jy-cell-output-string (n)
  "Cell N's rendered output as plain text."
  (let ((region (jy-cell-output-region n)))
    (if region
        (buffer-substring-no-properties (nth 0 region) (nth 1 region))
      "")))

;; The harness core declares these two with no default implementation on
;; purpose: "cell" means something different in every package, so the
;; profile is the only place that can say what it means here.
(defalias 'eh-goto-cell #'jy-goto-cell)
(defalias 'eh-cell-has-output-p #'jy-cell-has-output-p)

(defun jy-image-positions (&optional beg end)
  "Buffer positions between BEG and END that carry an image display prop."
  (let ((positions '())
        (pos (or beg (point-min)))
        (limit (or end (point-max))))
    (while (< pos limit)
      (let ((disp (get-char-property pos 'display)))
        (when (or (and (consp disp) (eq (car disp) 'image))
                  (and (consp disp) (consp (car disp)) (eq (caar disp) 'slice)))
          (push pos positions)))
      (setq pos (1+ pos)))
    (nreverse positions)))
