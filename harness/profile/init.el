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

(defun jy-image-pixel-bbox (pos)
  "Pixel (LEFT TOP WIDTH HEIGHT) of the image at POS, sliced or whole.
POS must be the image's first character -- its top-left slice if it has
more than one, the car of `jy-image-positions'.  WIDTH/HEIGHT are the
image's full displayed extent, every sliced row included however many
lines it was split across, not just the one glyph at POS.

LEFT/TOP are relative to the frame's own content area -- the coordinate
space a screenshot from `eh-shot-to-file' (`x-export-frames') is in --
rather than to the X display.  `window-absolute-pixel-position' answers
in the latter (DESIGN §6.3: that is what a click needs, since xdotool
targets the screen), which on a reparenting window manager is the
frame's position on screen, not (0, 0); using it to crop a screenshot
directly picks the wrong rectangle by exactly that offset."
  (let* ((disp (get-char-property pos 'display))
         (spec (cond
                ((and (consp disp) (consp (car disp)) (eq (caar disp) 'slice))
                 (cadr disp))
                ((and (consp disp) (eq (car disp) 'image)) disp)))
         (size (and spec (image-size spec t)))
         (xy (window-absolute-pixel-position pos))
         (frame-xy (frame-edges nil 'native)))
    (unless (and spec size xy)
      (error "jsonyter-harness: no image at %d to measure" pos))
    (list (- (car xy) (nth 0 frame-xy))
          (- (cdr xy) (nth 1 frame-xy))
          (round (car size)) (round (cdr size)))))

(defun jy-bbox-unique-colors (bbox &optional inset)
  "Screenshot the frame and count the distinct colours inside BBOX.
BBOX is (LEFT TOP WIDTH HEIGHT), as `jy-image-pixel-bbox' returns; each
edge is inset by INSET pixels first (default 1) so that anti-aliasing
against whatever sits just outside the image never enters the count.

For an image with no internal edges of its own -- a flat fill, say --
this is a direct pixel-level check that slicing actually tiled: a `line-
spacing' leak or a slice cut a fraction short of its line both draw
through as an unfilled band, which is a second colour here regardless
of how clean the slice geometry looks from the display properties
alone."
  (cl-destructuring-bind (left top width height) bbox
    (let* ((inset (or inset 1))
           (shot (expand-file-name "unique-colors-shot.png" eh-run-dir))
           (crop (expand-file-name "unique-colors-crop.png" eh-run-dir)))
      (eh-shot-to-file shot)
      (let ((code (call-process "convert" nil nil nil shot
                                 "-crop" (format "%dx%d+%d+%d"
                                                  (max 1 (- width (* 2 inset)))
                                                  (max 1 (- height (* 2 inset)))
                                                  (+ left inset) (+ top inset))
                                 "+repage" crop)))
        (unless (zerop code) (error "jsonyter-harness: convert (crop) exited %d" code)))
      (with-temp-buffer
        (call-process "identify" nil t nil "-format" "%k" crop)
        (string-to-number (buffer-string))))))

;;;; Assertion helpers that survive a different Emacs build
;;
;; Both of these exist because the first real container run (Emacs 28.2)
;; failed four assertions that pass on 29.3.  Neither was a jsonyter bug;
;; both were assertions of mine that had quietly encoded properties of
;; the *build* rather than of the package.

(defun jy-expect-decoded-image (pos natural-width natural-height)
  "Assert POS shows a decoded image of the fixture NATURAL-WIDTH x NATURAL-HEIGHT.

Deliberately not an exact pixel-size assertion.  `jsonyter--fit-image-to-lines'
rescales a sliced image so its height is a whole number of text lines --
which is precisely what makes slices tile instead of band -- so the
displayed width is a function of the frame's line height, not of the
fixture.  A 300x500 fixture comes out 296px wide at a 17px line height,
302px at 18px, and 298px at 16px.  Asserting the natural width therefore
tests the font, and passes or fails depending on which Emacs build ran it.

What is invariant, and what actually separates a decoded image from a
placeholder box or the wrong file: it has a real pixel size, in the
neighbourhood of the fixture's, with the aspect ratio preserved."
  (let* ((display (get-char-property pos 'display))
         (spec (cond
                ((and (consp display) (consp (car display)) (eq (caar display) 'slice))
                 (cadr display))
                ((and (consp display) (eq (car display) 'image)) display)))
         (size (and spec (ignore-errors (image-size spec t)))))
    (eh-expect spec (format "no image display property at %d" pos))
    (eh-expect size "the image has no measurable size -- it did not decode")
    (let* ((width (float (car size)))
           (height (float (cdr size)))
           (natural-aspect (/ (float natural-width) natural-height))
           (aspect (/ width height)))
      (eh-expect (and (> width 0) (> height 0))
                 (format "image decoded to a zero dimension: %sx%s" width height))
      (eh-expect (< (abs (- aspect natural-aspect)) (* 0.02 natural-aspect))
                 (format "aspect ratio %.4f is not the fixture's %.4f -- wrong image?"
                         aspect natural-aspect))
      ;; Generous, and on purpose: fitting to whole lines can shrink or
      ;; grow the image by up to half a line per axis. The bound is here
      ;; to catch a placeholder or the wrong fixture, not to pin pixels.
      (eh-expect (> width (* 0.7 natural-width))
                 (format "image is %spx wide, far below the fixture's %d -- placeholder?"
                         width natural-width)))))

(defun jy-expect-faced-text (text face)
  "Assert every character of the first match for TEXT carries FACE.

Stronger than checking the first character alone, and self-diagnosing:
on failure it reports the properties actually present, because \"got
nil\" on one Emacs build and a pass on another is exactly the kind of
result a bare assertion cannot explain."
  (save-excursion
    (goto-char (point-min))
    (unless (search-forward text nil t)
      (ert-fail (format "%S never appears in the buffer" text)))
    (let ((beg (match-beginning 0))
          (end (match-end 0))
          (unfaced '()))
      (dolist (pos (number-sequence beg (1- end)))
        (let ((resolved (get-char-property pos 'face)))
          (unless (or (eq resolved face)
                      (and (listp resolved) (memq face resolved)))
            (push pos unfaced))))
      (when unfaced
        (setq unfaced (nreverse unfaced))
        (ert-fail
         (format "%S is not faced %s at %d of %d positions; properties: %s"
                 text face (length unfaced) (- end beg)
                 (mapconcat (lambda (pos)
                              (format "%d=%S" pos (text-properties-at pos)))
                            (seq-take unfaced 4) " ")))))))
