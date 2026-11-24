;;; jsonyter-repl.el --- REPL buffers -*- lexical-binding: t; -*-

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

;; REPL buffers.  One part of jsonyter.el, which loads
;; every part; see jsonyter.el for the overview and the entry points.

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
(require 'jsonyter-core)

;; Defined in other parts of the package, which load after this one.
(declare-function jsonyter--nb-cells "jsonyter-notebook")
(declare-function jsonyter--nb-refresh-prompt "jsonyter-notebook")
(declare-function jsonyter--ensure-live-bridge "jsonyter-attach")
(declare-function jsonyter--short-id "jsonyter-attach")
(declare-function jsonyter-kernel-history "jsonyter-attach")
(declare-function jsonyter-kernel-connect "jsonyter-attach")
(declare-function jsonyter-kernel-reconnect "jsonyter-attach")
(declare-function jsonyter-sync "jsonyter-sync")
(declare-function jsonyter--org-babel-ensure-plumbing "jsonyter-babel")
(declare-function image-size "image" (spec &optional pixels frame))

;;;; Line spacing

;; A sliced image tiles only if each row of the buffer is exactly as
;; tall as the slice it shows.  `line-spacing' breaks that: Emacs adds
;; the leading below the image glyph as readily as below a character,
;; so every slice ends up sitting on a bar of background and the plot
;; is drawn through a set of blinds.  It cannot be fixed per line --
;; the leading comes from the buffer (or the frame), not from anything
;; the text carries — so a buffer that shows slices has to go without
;; it.  See `jsonyter-suppress-line-spacing'.

(defvar jsonyter--display-frame-override nil
  "Frame `jsonyter--display-frame' should answer with, bypassing its own
buffer-window lookup.  Nil almost everywhere; let-bound by
`jsonyter--nb-render-string' around the scratch buffer it renders a
notebook cell's output into, which -- being a `with-temp-buffer' -- has
no window of its own for that lookup to find.  Left unset there,
`jsonyter--display-frame' would fall back to the selected frame inside
the scratch buffer too: the very bug it exists to avoid, one call frame
further in.")

(defun jsonyter--display-frame ()
  "A frame whose metrics this buffer's own display can be measured against.

Output arrives through `jsonyter--filter', a process filter: it sets
`current-buffer' to the REPL or notebook buffer but has no reason to
touch the selected frame, and normally does not.  `default-font-height',
`frame-char-height' and `display-graphic-p' all default to measuring
the *selected* frame when not told otherwise, so a plot that comes in
while some other frame is selected -- an Emacs daemon with more than one
`emacsclient' frame, `ace-window' between them, or simply a frame the
user last clicked into that is not the one showing this buffer -- gets
sliced to a line height that has nothing to do with the frame it is
about to appear in.  In a single-frame Emacs `selected-frame' and this
always agree, which is why the bug is invisible there.

`jsonyter--display-frame-override' wins when set.  Otherwise prefers a
window actually showing this buffer, on any frame, over the selected
one; falls back to the selected frame when the buffer is not displayed
anywhere right now, which measures no worse than before this function
existed."
  (or jsonyter--display-frame-override
      (let ((window (get-buffer-window (current-buffer) t)))
        (if window (window-frame window) (selected-frame)))))

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
    (define-key map (kbd "C-c C-k") #'jsonyter-unstick)
    (define-key map (kbd "C-c M-o") #'jsonyter-repl-clear)
    (define-key map (kbd "C-c C-y") #'jsonyter-sync)
    map)
  "Keymap for `jsonyter-repl-mode'.")

(defcustom jsonyter-mode-line-show-kernel-id t
  "Whether the mode line shows the current kernel's short id.

Shown appended to the state tag, e.g. `:idle[3f8a9c21]' -- the leading 8
characters of the kernel id, from `jsonyter--short-id'.  Nothing is shown
when there is no kernel (`:no-kernel' already says that), and the
multi-session summary (`:2 kernels!') never carries one, since an id
there would be unreadable.

Set to nil on a narrow frame or if `mode-line-process' is already
crowded; the id is always available from `jsonyter-current-kernel-id'
regardless."
  :type 'boolean
  :group 'jsonyter)

(defun jsonyter--session-status-tag (session)
  "The mode-line tag for one SESSION: our request state, else the kernel's.
Appends SESSION's short kernel id per `jsonyter-mode-line-show-kernel-id'.
This is the one place that happens, so every surface built on it -- REPL,
notebook, script, and Org at point via `jsonyter--mode-line-string' --
gets it for free."
  (let* ((state (jsonyter--session-state session))
         (transfer (jsonyter--session-transfer session))
         (kernel-id (jsonyter--session-kernel-id session))
         (tag
          (cond
           ;; A transfer (or export -- same slot, see `jsonyter--export-run')
           ;; runs on the REST pool, so it can be in flight while the kernel
           ;; is idle or even busy; when there is one, its progress is what
           ;; the user is watching for.  Export carries no percentage --
           ;; there are no `progress' events for it -- so it gets a bare
           ;; tag instead of a fake `0%'.
           ((and transfer (equal (plist-get transfer :phase) "export")) ":export")
           ;; A sync (same slot again, see `jsonyter--sync-run') carries a
           ;; file counter once transfers start, but nothing during its
           ;; `scan' phase -- there is no total to show yet.
           ((and transfer (equal (plist-get transfer :phase) "sync"))
            (if (plist-get transfer :files_total)
                (format ":sync %s/%s" (or (plist-get transfer :file_index) 0)
                        (plist-get transfer :files_total))
              ":sync"))
           (transfer (format ":%s %d%%"
                             (if (equal (plist-get transfer :phase) "download")
                                 "down" "up")
                             (or (plist-get transfer :pct) 0)))
           ((jsonyter--session-busy session) ":run")
           ((equal state "dead") ":dead")
           ((equal state "restarting") ":restarting")
           ((equal state "disconnected") ":offline")
           ;; Busy without a request of ours in flight: another client is
           ;; using this kernel.
           ((equal state "busy") ":run[ext]")
           ((equal state "starting") ":starting")
           ((null kernel-id) ":no-kernel")
           (t ":idle"))))
    (if (and jsonyter-mode-line-show-kernel-id kernel-id)
        (concat tag "[" (jsonyter--short-id kernel-id) "]")
      tag)))

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
        (format ":%d kernel%s%s%s" (length sessions)
                (if (cdr sessions) "s" "")
                (if (seq-some #'jsonyter--session-busy sessions) "!" "")
                (if (seq-some #'jsonyter--session-transfer sessions) "~" ""))))
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
  "Fit IMAGE to the line grid so that slicing it into ROWS tiles.
Two things about the image itself decide whether its slices sit flush
or each on its own band of background.

Its height: a slice is only as tall as its own share of the image, so
unless that height is an exact multiple of LINE-HEIGHT every slice
comes up short of the line it sits on, and the shortfall is drawn as a
stripe across the picture, once per slice.  Rounding the height to a
whole number of lines removes the shortfall.  Both dimensions are
pinned rather than just the height because `:max-width' and
`:max-height' would otherwise still be free to shrink the result to
preserve the aspect ratio, undoing the fit; `:width' and `:height' take
precedence over them.

Its baseline: an image glyph's `:ascent' says how much of it sits above
the text baseline, and the default, 50, puts the baseline through the
middle of every slice.  That is harmless in a row holding nothing but
the slice.  But a row that also holds a glyph drawn with the buffer's
text font -- and `display-line-numbers-mode' puts one on every row --
is asked for that font's full ascent above the baseline, while the
slice still asks for half its height below it, and the row grows to
the sum: with a 17px font, a 13px ascent plus a 9px half-slice makes
a 22px row for a 17px slice, and the 5px left over are drawn as
background under each one.  `center' anchors a slice so that its
ascent is exactly the font's -- `image_ascent' in image.c arranges
that for a glyph as tall as the font's line -- and every row, line
numbers or not, comes out one line tall.

Those are two of the three ways slices come out banded; `line-spacing'
is the third, and `jsonyter-suppress-line-spacing' deals with it."
  (let* ((size (image-size image t))
         (height (cdr size))
         (target (* rows line-height)))
    (unless (zerop height)
      (setf (image-property image :width)
            (max 1 (round (* (car size) (/ (float target) height))))
            (image-property image :height) target
            (image-property image :ascent) 'center))))

(defun jsonyter--insert-image (image alt)
  "Insert IMAGE at point with ALT as its text fallback.
Tall images are sliced one text line per row so that line-based
scrolling can move through them; see `jsonyter-slice-images'.  Output
bound for a script cell's overlay string is inserted whole instead,
since slices would not be lines there at all — see
`jsonyter--string-output'.

Measured against `jsonyter--display-frame' rather than whatever frame
Emacs currently has selected — see there for why the two are not always
the same frame, and what happens to the fit when they are not."
  (with-selected-frame (jsonyter--display-frame)
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
        (insert "\n")))))

(defvar jsonyter--output-image-max-width nil
  "Pixel ceiling on image width for the output being rendered, or nil.
Bound by `jsonyter--nb-render-string' to `jsonyter-notebook-output-width'
columns' worth of pixels so a figure in a notebook or script cell lines
up with the output frame; `jsonyter--image-scale-props' takes the
tighter of this and `jsonyter-image-max-width'.  Unset in a REPL.")

(defun jsonyter--image-scale-props ()
  "Scaling properties to hand `create-image', per the size options."
  (let ((max-width (cond ((and jsonyter-image-max-width
                               jsonyter--output-image-max-width)
                          (min jsonyter-image-max-width
                               jsonyter--output-image-max-width))
                         (t (or jsonyter-image-max-width
                                jsonyter--output-image-max-width)))))
    (append (and max-width (list :max-width max-width))
            (and jsonyter-image-max-height
                 (list :max-height jsonyter-image-max-height)))))

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
  "Restart SESSION's kernel (default the session in play), keeping its id.
The kernel process itself is replaced, so all of its state is lost; to
merely unstick a REPL stuck at \"kernel is busy\" without touching the
kernel at all, see `jsonyter-unstick'."
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

;; Named to sit with the other `jsonyter-kernel-*' commands
;; (`jsonyter-kernel-connect', `jsonyter-kernel-reconnect',
;; `jsonyter-kernel-history') where a user looking for kernel operations
;; -- report #3's "restart the kernel, keeping its id" -- will find it by
;; `M-x' completion.  An alias, not a rename: `jsonyter-restart' is the
;; name in the README, the commentary key table and every mode's keymap
;; (`C-c C-r'), and `jsonyter-org-restart' delegates to it by that name.
;;;###autoload
(defalias 'jsonyter-kernel-restart #'jsonyter-restart
  "Restart this session's kernel, keeping its id and discarding its state.
An alias for `jsonyter-restart', named to sit with the other
`jsonyter-kernel-*' commands (`jsonyter-kernel-connect',
`jsonyter-kernel-reconnect', `jsonyter-kernel-history') where a user
looking for kernel operations will find it by completion.")

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

(defun jsonyter-unstick (&optional session)
  "Recover a REPL stuck at a \"kernel is busy\" prompt.
Abandons any in-flight requests, clears SESSION's busy flag and draws a
fresh prompt.  The kernel is left running: if it is genuinely still
working, interrupt it with \\[jsonyter-interrupt] first, or this prompt
will sit alongside output that is still on its way.

This never touches the kernel itself — only Emacs's own busy-tracking
state.  To restart the kernel and discard its state, keeping its id, use
`jsonyter-restart' (aka `jsonyter-kernel-restart') instead."
  (interactive)
  (let ((session (or session (jsonyter--command-session))))
    (when jsonyter--callbacks (clrhash jsonyter--callbacks))
    (setf (jsonyter--session-busy session) nil)
    (setq jsonyter--clear-pending nil)
    (force-mode-line-update)
    (jsonyter--after-kernel-reset "[reset — kernel left running]" session)))

;;;###autoload
(define-obsolete-function-alias 'jsonyter-reset #'jsonyter-unstick "2.3.0")

(defun jsonyter--after-kernel-reset (text &optional session)
  "Put this buffer back in a usable state after a restart or reset.
A REPL gets TEXT in its transcript and a fresh prompt.  A notebook gets
neither — writing into its text would corrupt the document — but its
cells' execution counts are blanked, since the kernel's counter has gone
back to zero and the old numbers no longer mean anything.  SESSION names
the affected session for the echo-area note in a multi-kernel buffer."
  ;; A restarted kernel may have a different working directory, and a
  ;; stale contents-path mapping is worse than none -- so drop it and let
  ;; the next transfer command re-probe.  The remote browser's sticky
  ;; directory goes with it, since it was seeded from that mapping.
  (when session
    (setf (jsonyter--session-contents-dir session) nil
          (jsonyter--session-contents-dir-probed session) nil
          (jsonyter--session-remote-directory session) nil))
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

(provide 'jsonyter-repl)
;;; jsonyter-repl.el ends here
