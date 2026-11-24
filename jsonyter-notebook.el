;;; jsonyter-notebook.el --- Rendered .ipynb notebooks -*- lexical-binding: t; -*-

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

;; Rendered .ipynb notebooks.  One part of jsonyter.el, which loads
;; every part; see jsonyter.el for the overview and the entry points.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
;; `syntax-ppss-flush-cache', `string-to-syntax' -- for keeping a cell's
;; syntax from bleeding into the next; see `jsonyter--nb-syntax-propertize'.
(require 'syntax)
(require 'image)

;; Defined in other parts of the package, which load after this one.
(declare-function jsonyter-notebook-latex-preview "jsonyter-latex")
(declare-function jsonyter-notebook-latex-preview-toggle "jsonyter-latex")
(declare-function jsonyter-notebook-export "jsonyter-export")
(declare-function jsonyter-sync "jsonyter-sync")
(declare-function jsonyter-script-clear-all-output "jsonyter-script")
(declare-function json-encode-string "json" (string))
(require 'jsonyter-repl)
(require 'jsonyter-attach)

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
  :type '(alist :key-type string :value-type function)
  :group 'jsonyter)

(defcustom jsonyter-notebook-auto-start-kernel t
  "If non-nil, start a kernel on the first cell execution in a notebook.
With nil, `jsonyter-notebook-start-kernel' must be called explicitly."
  :type 'boolean
  :group 'jsonyter)

(defface jsonyter-notebook-cell-face
  '((t :inherit jsonyter-prompt-face))
  "Face for a notebook cell's prompt line."
  :group 'jsonyter)

(defface jsonyter-notebook-markdown-face
  '((t :inherit font-lock-doc-face))
  "Face for the prompt line of a markdown cell."
  :group 'jsonyter)

(defface jsonyter-notebook-rule-face
  '((t :inherit shadow))
  "Face for the rule drawn beside a cell prompt."
  :group 'jsonyter)

(defface jsonyter-code-cell-face
  '((t :inherit jsonyter-notebook-cell-face))
  "Face for the boundary label of a code cell."
  :group 'jsonyter)

(defface jsonyter-markdown-cell-face
  '((t :inherit jsonyter-notebook-markdown-face))
  "Face for the boundary label of a markdown cell."
  :group 'jsonyter)

(defface jsonyter-raw-cell-face
  '((t :inherit shadow :weight bold))
  "Face for the boundary label of a raw cell."
  :group 'jsonyter)

(defface jsonyter-output-border-face
  '((t :inherit jsonyter-notebook-rule-face))
  "Face for the rules framing a cell's rendered output."
  :group 'jsonyter)

(defface jsonyter-output-border-stale-face
  '((t :inherit warning))
  "Face for the output frame of a cell edited since its output was made.
Flags output that may no longer match the cell's current source; the
frame reverts to `jsonyter-output-border-face' when the cell is re-run
\(or the edit is undone)."
  :group 'jsonyter)

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

(defun jsonyter--nb-json-for-wire (value)
  "Reshape parsed-JSON VALUE so `json-serialize' can encode it.
VALUE comes from `json-parse-buffer' with `:object-type' plist and
`:array-type' list, so an object and an array are both Lisp lists; they
are told apart by whether the car is a keyword.  Returns VALUE with:
- a plist (a non-nil list whose car is a keyword) kept as a plist, every
  value converted the same way;
- any other non-nil list turned into a vector of its converted elements;
- a vector turned into a vector of its converted elements;
- anything else (string, number, nil, t, :null, :false) returned as is."
  (cond
   ((null value) nil)
   ((vectorp value)
    (vconcat (mapcar #'jsonyter--nb-json-for-wire value)))
   ((and (consp value) (keywordp (car value)))
    (let ((out nil)
           (rest value))
      (while rest
        (push (car rest) out)
        (push (jsonyter--nb-json-for-wire (cadr rest)) out)
        (setq rest (cddr rest)))
      (nreverse out)))
   ((consp value)
    (vconcat (mapcar #'jsonyter--nb-json-for-wire value)))
   (t value)))

(defun jsonyter--nb-data-for-wire (data)
  "Reshape mimebundle DATA so `json-serialize' can encode it.
DATA is an output's `:data' or `:metadata' plist.  nbformat lets any
mimetype's value be a list of line fragments instead of one string
\(`jsonyter--mime' joins such a list for rendering), and `json-serialize'
cannot encode a Lisp list as a JSON array, so a list of strings is
joined into one string here.  A value under a JSON mimetype, or any list
that is not all strings (image metadata, say), is structured JSON and
goes through `jsonyter--nb-json-for-wire' instead.  Values that are not
lists pass through unchanged."
  (cl-loop for (key val) on data by #'cddr
           append (list key (cond
                            ((not (listp val)) val)
                            ((string-match-p "json" (symbol-name key))
                             (jsonyter--nb-json-for-wire val))
                            ((cl-every #'stringp val) (jsonyter--mime data key))
                            (t (jsonyter--nb-json-for-wire val))))))

(defun jsonyter--nb-output-for-wire (output)
  "Reshape nbformat-shape OUTPUT so `json-serialize' can encode it.
nbformat permits a stream's `:text', an error's `:traceback', and any
mimebundle value under an output's `:data'/`:metadata' to be stored as a
list of line fragments rather than one string; `json-serialize' has no
way to tell such a list from a malformed plist, and signals instead of
encoding it.  OUTPUT is expected in nbformat shape (keyed by
`:output_type') -- see `jsonyter--nb-collect-cells' for outputs read
straight from a file, and `jsonyter--nb-output-to-spec' for outputs
converted from the kernel protocol. Metadata is converted as structured
JSON, never joined as text."
  (pcase (plist-get output :output_type)
    ("stream"
     (plist-put (copy-sequence output) :text
               (jsonyter--nb-text (plist-get output :text))))
    ((or "display_data" "execute_result")
     (let ((out (copy-sequence output)))
       (setq out (plist-put out :data (jsonyter--nb-data-for-wire (plist-get output :data))))
       (plist-put out :metadata (jsonyter--nb-json-for-wire (plist-get output :metadata)))))
    ("error"
     (plist-put (copy-sequence output) :traceback
               (vconcat (plist-get output :traceback))))
    (_ output)))

(defun jsonyter--nb-outputs-for-wire (outputs)
  "OUTPUTS (a list of nbformat-shape output plists, as read from a file)
reshaped into a vector ready for `json-serialize' -- see
`jsonyter--nb-output-for-wire'."
  (vconcat (mapcar #'jsonyter--nb-output-for-wire outputs)))

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
        (spacing line-spacing)
        ;; Same idea, for which frame's font metrics an image gets fit
        ;; to: computed here, in the buffer this output is actually
        ;; headed for, while `jsonyter--display-frame' can still find it
        ;; from its window.  A temp buffer has no window at all, so
        ;; without this override the scratch buffer would fall back to
        ;; the selected frame regardless of which one is showing the
        ;; notebook -- see `jsonyter--display-frame-override'.
        (jsonyter--display-frame-override (jsonyter--display-frame))
        ;; Cap image width at `jsonyter-notebook-output-width' columns so
        ;; a figure lines up with the output frame.  Computed here for
        ;; the same reason as the frame override -- the scratch buffer
        ;; has no frame of its own to ask.  A failure to measure (no
        ;; usable frame) just means no cap, exactly as before.
        (jsonyter--output-image-max-width
         (and (integerp jsonyter-notebook-output-width)
              (> jsonyter-notebook-output-width 0)
              (ignore-errors
                (* jsonyter-notebook-output-width
                   (frame-char-width (jsonyter--display-frame)))))))
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
           (width (max (+ 5 (length label)) jsonyter-notebook-output-width))
           (rule (make-string (- width (1+ (length label))) ?─)))
      (concat
       (propertize (concat label " " rule "\n") 'face face 'help-echo help)
       rendered
       (if (string-suffix-p "\n" rendered) "" "\n")
       (propertize
        (concat (make-string width ?─) "\n")
        'face face 'help-echo help)))))

;;; Cell overlays

(defun jsonyter--nb-cell-type-face (cell-type)
  "Face for the boundary label of a CELL-TYPE cell."
  (pcase cell-type
    ("markdown" 'jsonyter-markdown-cell-face)
    ("raw" 'jsonyter-raw-cell-face)
    (_ 'jsonyter-code-cell-face)))

;; Per-cell line numbers (see `jsonyter-notebook-line-numbers').  A prompt
;; is an overlay string of several rows and a cell's output is buffer text,
;; so Emacs's own numbers land on the prompt's spacer row and count every
;; output row.  When this is non-nil Emacs's numbers are off in the buffer
;; and each source line is numbered from 1 within its cell instead: lines
;; 2..n by a `line-prefix' text property set by `jsonyter--nb-number-lines',
;; and line 1 by the tail of its cell's
;; prompt string, because the first screen row of line 1 is the spacer row
;; and that is where a `line-prefix' on it would be drawn.
(defvar-local jsonyter--nb-numbers-active nil
  "Non-nil while this notebook buffer shows per-cell line numbers.")

(defvar display-fill-column-indicator-column)

(defvar-local jsonyter--nb-indicator-restore nil
  "How to undo `jsonyter--nb-shift-fill-column-indicator'.
Either (set . VALUE), the buffer's own value of
`display-fill-column-indicator-column', or the symbol `kill'.")

(defun jsonyter--nb-source-end (cell)
  "Position where CELL's source ends and its rendered output begins.
The overlay's own end when the cell has no `jsonyter-source-end' marker."
  (let ((marker (overlay-get cell 'jsonyter-source-end)))
    (or (and marker (marker-position marker)) (overlay-end cell))))

(defun jsonyter--nb-line-count (cell)
  "Number of lines in CELL's source: at least 1.
Rendered output after `jsonyter-source-end' is not counted."
  (max 1 (count-lines (overlay-start cell) (jsonyter--nb-source-end cell))))

(defun jsonyter--nb-number-digits (count)
  "Width of the number column for a cell of COUNT lines: two at least."
  (max 2 (length (number-to-string count))))

(defun jsonyter--nb-number-string (n digits)
  "The gutter text for line N: N right-aligned in DIGITS columns, then a space.
It wears the `line-number' face, so it matches Emacs's own numbers."
  (let ((text (number-to-string n)))
    (propertize (concat (make-string (max 0 (- digits (length text))) ?\s)
                        text " ")
                'face 'line-number)))

(defun jsonyter--nb-prompt (cell-type exec-count &optional running gutter)
  "Prompt string shown above a cell of CELL-TYPE with EXEC-COUNT.
RUNNING marks a cell whose execution is still in flight.  GUTTER, when
non-nil, is a string put after the prompt's last newline, so it is shown
on the row of the cell's first source line: the number of that line.

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
            "\n"
            gutter)))

(defun jsonyter--nb-refresh-prompt (cell)
  "Update CELL's prompt overlay string from its stored state.
While per-cell numbers are showing, also record the cell's line count and
column width on the overlay and end the prompt with its first line's
number; see `jsonyter--nb-numbers-update'."
  (let ((digits (and jsonyter--nb-numbers-active
                     (let ((count (jsonyter--nb-line-count cell)))
                       (overlay-put cell 'jsonyter-line-count count)
                       (overlay-put cell 'jsonyter-number-digits
                                    (jsonyter--nb-number-digits count))))))
    (overlay-put cell 'before-string
                 (jsonyter--nb-prompt (overlay-get cell 'jsonyter-cell-type)
                                      (overlay-get cell 'jsonyter-exec-count)
                                      (overlay-get cell 'jsonyter-running)
                                      (and digits
                                           (jsonyter--nb-number-string
                                            1 digits))))))

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

Point gets the same treatment as the adjacent cell overlays just below:
a plain `save-excursion' saves point as an insertion-type-nil marker,
which `delete-region' collapses to SRC-END and which then sits in
*front* of the freshly inserted output — exactly the corruption this
function already routes around for `adjacent'.  An insertion-type-t
marker collapses to SRC-END the same way but rides back out to the end
of the inserted text, so point ends up where the adjacent overlays end
up: past the new output, at the start of whatever comes next.  A point
that was strictly before SRC-END (still in the cell's source) or
strictly after the old OUT-END (past this cell entirely) is untouched
by the edit either way.

`with-silent-modifications' keeps the rewrite out of the undo history
and out of the buffer's modified flag — output is a result, not part of
the document, exactly as it was when it lived in an overlay string — and
stands `after-change-functions' down for the same reason
`jsonyter--nb-cell-surgery' does.  That also means Emacs's usual
`syntax-ppss' cache invalidation (hung off `before-change-functions')
never runs for this edit, so it is flushed explicitly from SRC-END: a
cell re-run whose new output changes what `jsonyter--nb-syntax-propertize'
blanks there would otherwise leave stale parse state behind."
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
         (point-marker (copy-marker (point) t))
         (new-end
          (let ((jsonyter--nb-cell-surgery t))
            (with-silent-modifications
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
              (point)))))
    (goto-char point-marker)
    (set-marker point-marker nil)
    (syntax-ppss-flush-cache src-end)
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
    ;; The file's own outputs, in nbformat shape (`:output_type', not the
    ;; kernel protocol's `:type') -- kept separate from `jsonyter-raw-outputs'
    ;; (kernel shape, set only by `jsonyter--nb-set-output' with TOUCHED)
    ;; so a cell nothing has re-run this session can still contribute its
    ;; stored results to an export; see `jsonyter--nb-collect-cells'.
    (overlay-put ov 'jsonyter-file-outputs (plist-get cell :outputs))
    (jsonyter--nb-refresh-prompt ov)
    (when jsonyter--nb-numbers-active
      (jsonyter--nb-number-lines ov start end))
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

(defun jsonyter--nb-prose-spans (beg end)
  "Non-code (markdown/raw) cells' own source spans overlapping BEG..END,
in buffer order.  A markdown or raw cell's source is prose or a raw
payload, not this notebook's kernel language."
  (sort (delq nil
              (mapcar
               (lambda (o)
                 (let ((source-end (and (overlay-get o 'jsonyter-cell)
                                        (not (equal (overlay-get o 'jsonyter-cell-type) "code"))
                                        (overlay-get o 'jsonyter-source-end))))
                   (and source-end
                        (< (overlay-start o) (marker-position source-end))
                        (cons (overlay-start o) (marker-position source-end)))))
               (overlays-in beg end)))
        #'car-less-than-car))

(defun jsonyter--nb-non-code-spans (beg end)
  "Spans within BEG..END that are not this notebook's kernel-language code:
a cell's rendered output (`jsonyter--nb-output-spans') and a non-code
cell's own source (`jsonyter--nb-prose-spans'), merged and in buffer
order.

Painting and parsing the buffer as one language are two faces of the
same problem — the buffer holds three kinds of text under a single
major mode and syntax table, and only a code cell's source is really
that language — so both `jsonyter--nb-fontify-region'/
`jsonyter--nb-unfontify-region' (what gets painted) and
`jsonyter--nb-syntax-propertize' (what `syntax-ppss' is allowed to
parse as a string/comment/paren delimiter) key off this same set of
spans."
  (sort (append (jsonyter--nb-output-spans beg end) (jsonyter--nb-prose-spans beg end))
        #'car-less-than-car))

(defun jsonyter--nb-map-source-runs (beg end fn)
  "Call FN with the bounds of each run of code-cell source text between
BEG and END.  Rendered output and non-code cell source in between are
skipped — see `jsonyter--nb-non-code-spans'."
  (let ((pos beg))
    (dolist (span (jsonyter--nb-non-code-spans beg end))
      (when (< pos (car span))
        (funcall fn pos (min end (car span))))
      (setq pos (max pos (min end (cdr span)))))
    (when (< pos end)
      (funcall fn pos end))))

(defun jsonyter--nb-fontify-region (beg end loudly)
  "Fontify BEG..END as code, leaving output and non-code source alone.
LOUDLY is passed through to `font-lock-default-fontify-region'.

On `font-lock-fontify-region-function' in notebook buffers.  A cell's
output is buffer text, so the notebook language's own font-lock would
otherwise read a traceback or a printed string as code: it strips the
`face' properties the renderer put there — the resolved ANSI colours,
the stderr red, the frame around the block — and paints its own over
what is left.  A markdown/raw cell's source is buffer text too, and is
not this notebook's kernel language either — highlighting \"and\" as a
Python keyword because it happens to share the buffer with Python code
is exactly as wrong as painting a traceback.  Only a code cell's own
source is handed on.

Nothing needs to hold `font-lock-extend-region-functions' back at the
seams: a cell owns its trailing newline and an output block ends with
its closing rule's, so every run of source both begins and ends at the
beginning of a line, and whole-line extension has nowhere to reach."
  (jsonyter--nb-map-source-runs
   beg end
   (lambda (from to) (font-lock-default-fontify-region from to loudly)))
  ;; The non-code spans inside the region are finished, not pending, so
  ;; report the whole of it as done rather than leaving jit-lock to come
  ;; back for them on every redisplay.
  `(jit-lock-bounds ,beg . ,end))

(defun jsonyter--nb-unfontify-region (beg end)
  "Strip font-lock's faces from BEG..END, leaving output and non-code
source alone.

On `font-lock-unfontify-region-function' in notebook buffers, and the
necessary other half of `jsonyter--nb-fontify-region': output text and
a non-code cell's source are not font-lock's to paint, so they are not
font-lock's to strip either.  Without this, anything that unfontifies
wholesale — \\[font-lock-update], turning the mode off and on, a
major-mode change — would take the renderer's own colours with it and
never put them back, since refontifying deliberately skips both."
  (jsonyter--nb-map-source-runs beg end #'font-lock-default-unfontify-region))

(defvar-local jsonyter--nb-inert-table nil
  "The inert syntax table last built, as (BASE . TABLE).
BASE is the buffer's syntax table it was built from; see
`jsonyter--nb-inert-syntax-table'.")

(defun jsonyter--nb-inert-syntax-table ()
  "The syntax table that goes on text that is not kernel-language code.

Every character is punctuation, so none of it can open or close a
string, comment or pair.  The exception is whitespace: a character the
buffer's own syntax table gives the whitespace or the comment-end class,
which in practice means the space, the tab and above all the newline,
keeps exactly the entry the language mode gave it.  Packages that walk
the buffer backward a line at a time, such as ESS when it indents, step
over the newline ending the previous cell with `forward-comment', which
moves only over whitespace and comment ends; with the newline as
punctuation it cannot move, and the walk goes round forever on the first
line of every code cell.

The table is built from the buffer's current syntax table and kept
until that changes."
  (let ((base (syntax-table)))
    (if (eq (car jsonyter--nb-inert-table) base)
        (cdr jsonyter--nb-inert-table)
      (let ((table (make-char-table 'syntax-table (string-to-syntax "."))))
        (dotimes (char 128)
          (when (memq (syntax-class (aref base char)) '(0 12))
            (aset table char (aref base char))))
        (setq jsonyter--nb-inert-table (cons base table))
        table))))

(defun jsonyter--nb-syntax-propertize (beg end)
  "`syntax-propertize-function' for `jsonyter-notebook-mode'.

The buffer holds three kinds of text under one major mode and therefore
one syntax table: code-cell source, non-code-cell source, and rendered
output.  `jsonyter--nb-fontify-region'/`jsonyter--nb-unfontify-region'
already confine what gets *painted* to code-cell source, but nothing
otherwise stops `font-lock-default-fontify-region' from resolving string
and comment state through `syntax-ppss', which parses forward from
`point-min' (or the last cached parse point) through every intervening
character — prose and rendered output included.  So one unbalanced
string, comment or paired delimiter anywhere in the buffer changes the
fontification of everything after it, to the end of the buffer.

Covers each `jsonyter--nb-non-code-spans' span with
`jsonyter--nb-inert-syntax-table', so none of them can open or close
anything while its whitespace stays whitespace.  Covering the whole span
rather than only neutralizing delimiters is simpler and cheap: an output
span is already rewritten wholesale on every re-run
\(`jsonyter--nb-show-output-as-text'\), and a markdown/raw cell's source
is ordinarily short.

`parse-sexp-lookup-properties' must be non-nil for a `syntax-table' text
property to take effect at all; `jsonyter-notebook-mode' sets it
buffer-locally rather than relying on the language mode to have done
so."
  (let ((table (jsonyter--nb-inert-syntax-table)))
    (dolist (span (jsonyter--nb-non-code-spans beg end))
      (let ((from (max beg (car span))) (to (min end (cdr span))))
        (when (< from to)
          (put-text-property from to 'syntax-table table))))))

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

(defun jsonyter--nb-forget-cells ()
  "Delete every cell overlay in this buffer, with its source-end marker.
`erase-buffer' does not remove overlays: each cell's overlay survives as
an empty one at the top of the buffer.  A re-render must therefore forget
the cells it replaces, or every revert stacks another full set of empty
cells there, each still drawing its prompt."
  (dolist (cell (jsonyter--nb-cells))
    (let ((marker (overlay-get cell 'jsonyter-source-end)))
      (when (markerp marker)
        (set-marker marker nil))
      (delete-overlay cell)))
    )

(defun jsonyter--nb-drop-empty-cells ()
  "Delete every cell overlay that covers no text; return how many.
Such an overlay is what a cell leaves behind when everything it covered
is deleted, and it no longer names a line of the notebook.  The
overlay's `jsonyter-source-end' marker is detached too.  Cells that
cover text are left alone."
  (let ((count 0))
    (dolist (cell (jsonyter--nb-cells))
      (when (= (overlay-start cell) (overlay-end cell))
        (let ((marker (overlay-get cell 'jsonyter-source-end)))
          (when (markerp marker)
            (set-marker marker nil)))
        (delete-overlay cell)
        (setq count (1+ count))))
    count))

(defun jsonyter--nb-adopt-stray-text ()
  "Bring text typed after the last cell into a cell; return t if there was any.
Cells tile the buffer, so text past the end of the last cell belongs to
none of them and a save would not write it.  It joins the last cell, or,
when that cell shows output, a new code cell, so that it never becomes
part of the read-only output block.  A missing final newline is
supplied, and point stays where it was.  Return nil, changing nothing,
when there is no such text or no cells."
  (let* ((cells (jsonyter--nb-cells))
         (last (if (null cells) nil (car (last cells))))
         (start (if last (overlay-end last) nil)))
    (if (or (null last) (not (< (overlay-end last) (point-max))))
        nil
      (let ((jsonyter--nb-cell-surgery t)
            (inhibit-read-only t))
        (save-excursion
          (goto-char (point-max))
          (unless (bolp)
            (insert "\n")))
        (if (< (marker-position (overlay-get last 'jsonyter-source-end))
             (overlay-end last))
            (jsonyter--nb-make-cell start (point-max)
                                   (list :id nil :cell_type "code" :outputs nil))
            (move-overlay last (overlay-start last) (point-max))
            (set-marker (overlay-get last 'jsonyter-source-end) (point-max))
            (jsonyter--nb-numbers-update last start (point-max)))
        t))))

(defun jsonyter--nb-empty-cell-p (cell)
  "Non-nil when CELL has blank source and shows no output.
Blank means nothing but whitespace.  A blank cell that still shows
output is not empty."
  (and (string-blank-p (jsonyter--nb-cell-source cell))
        (>= (marker-position (overlay-get cell 'jsonyter-source-end))
            (overlay-end cell))))

;;;###autoload
(defun jsonyter-notebook-prune ()
  "Delete every empty cell in this notebook; return how many were removed.
A cell is empty when its source is blank and it shows no output; one
that is blank but shows output is kept, and so is the notebook's last
remaining cell.  Cells that have collapsed to nothing, which an old
re-render could leave behind, are removed and counted too.  When
anything was removed the buffer is marked modified; either way the
result is reported in the echo area."
  (interactive)
  (jsonyter--nb-ensure-notebook)
  (let ((removed (jsonyter--nb-drop-empty-cells)))
    (dolist (cell (jsonyter--nb-cells))
      (when (and (jsonyter--nb-empty-cell-p cell)
                   (not (null (cdr (jsonyter--nb-cells)))))
        (jsonyter--nb-excise-cell cell)
        (setq removed (1+ removed))))
    (when (> removed 0)
      (set-buffer-modified-p t)
      (message "jsonyter: removed %d empty cell%s"
                 removed
                 (if (= removed 1) "" "s")))
    (when (<= removed 0)
      (message "jsonyter: no empty cells"))
    removed))

(defun jsonyter--nb-stale-after-change (beg end _len)
  "After an edit from BEG to END, re-judge the affected cells' outputs.
On `after-change-functions' in notebook buffers.  Stands down during
cell surgery (see `jsonyter--nb-cell-surgery'), whose transient
intermediate states are not edits to any cell's source."
  (unless jsonyter--nb-cell-surgery
    (jsonyter--nb-drop-empty-cells)
    (jsonyter--nb-adopt-stray-text)
    (dolist (cell (delete-dups (delq nil (list (jsonyter--nb-cell-at beg)
                                               (jsonyter--nb-cell-at end)))))
      (jsonyter--nb-numbers-update cell beg end)
      (jsonyter--output-update-stale cell (jsonyter--nb-cell-source cell)))))

;;; Per-cell line numbers

(defun jsonyter--nb-number-lines (cell from to)
  "Set the per-cell number properties on CELL's source lines from FROM to TO.
Covers every source line that begins between the start of FROM's line and
TO, clipped to the cell's source; output text is never touched.  The first
line of a cell gets only a `wrap-prefix' of blanks, since its number is the
tail of the cell's prompt string; every later line gets its number as a
`line-prefix' and the same width of blanks as a `wrap-prefix', so a line
that wraps continues under its text.

This is done eagerly, by whatever changes the lines, and not left to
jit-lock: Emacs reads a row's `line-prefix' as it starts the row, before
jit-lock has fontified the text there, so a prefix set lazily showed its
old number on the first row of every changed region until something else
redrew it.  Ordinary edits are cheap, since only the edited lines and,
when the line count changed, the rest of the cell are visited."
  (let* ((start (overlay-start cell))
         (limit (jsonyter--nb-source-end cell))
         (stop (min to limit))
         (digits (or (overlay-get cell 'jsonyter-number-digits) 2))
         (blank (make-string (1+ digits) ?\s)))
    (when (< (max from start) stop)
      (with-silent-modifications
        (save-excursion
          (goto-char (max from start))
          (forward-line 0)
          (let ((n (1+ (count-lines start (point)))))
            (while (< (point) stop)
              (let ((here (point))
                    (next (min limit (progn (forward-line 1) (point)))))
                (if (= here start)
                    (progn (remove-text-properties here next '(line-prefix nil))
                           (add-text-properties here next (list 'wrap-prefix blank)))
                  (add-text-properties here next
                                       (list 'line-prefix
                                             (jsonyter--nb-number-string n digits)
                                             'wrap-prefix blank)))
                (setq n (1+ n))))))))))

(defun jsonyter--nb-numbers-update (cell beg end)
  "Bring CELL's per-cell numbers in step after an edit that left BEG..END.
Does nothing unless numbers are showing.  Recounts CELL's source lines
and compares with the count stored on the overlay.  Lines before the edit
keep their numbers.  The edited lines are always renumbered, since text
inserted without inheriting, or kept from a deleted line, can carry the
wrong prefix.  When the count changed, every later line of the cell is
renumbered too, and when the column width changed as well the prompt is
redrawn and the whole cell renumbered, since every prefix changed.
Returns non-nil when the count or the width changed."
  (when jsonyter--nb-numbers-active
    (let* ((count (jsonyter--nb-line-count cell))
           (digits (jsonyter--nb-number-digits count))
           (widened (not (eql digits (overlay-get cell 'jsonyter-number-digits))))
           (changed (or widened
                        (not (eql count (overlay-get cell 'jsonyter-line-count))))))
      (when changed
        (jsonyter--nb-refresh-prompt cell))
      (jsonyter--nb-number-lines
       cell
       (if widened (overlay-start cell) beg)
       (if changed (jsonyter--nb-source-end cell)
         (save-excursion (goto-char end) (forward-line 1) (point))))
      changed)))

(defun jsonyter--nb-strip-number-props (string)
  "Return STRING without `line-prefix' and `wrap-prefix' properties.
A `filter-return' on `filter-buffer-substring-function' while per-cell
numbers are showing, so that source copied or killed from a notebook does
not carry its numbers into whatever it is pasted into."
  (remove-list-of-text-properties 0 (length string)
                                  '(line-prefix wrap-prefix) string)
  string)

(defun jsonyter--nb-shift-fill-column-indicator ()
  "Move the fill-column indicator right by the width of a number gutter.
Per-cell numbers are a `line-prefix', which lies inside the text area,
and `display-fill-column-indicator' counts columns from the left edge of
that area, so without this it is drawn that many columns before the point
where source text reaches the fill column: a line of exactly `fill-column'
characters would cross it.  Emacs's own numbers sit outside the text area
and need no such shift.  The shift is the narrowest gutter, that of a cell
under a hundred lines; a longer cell's gutter is a column wider, so its
text ends a column past the indicator.  The indicator follows
`fill-column' as it was when the numbers started."
  (setq jsonyter--nb-indicator-restore
        (if (local-variable-p 'display-fill-column-indicator-column)
            (cons 'set display-fill-column-indicator-column)
          'kill))
  (setq-local display-fill-column-indicator-column
              (+ (if (and (boundp 'display-fill-column-indicator-column)
                          (integerp display-fill-column-indicator-column))
                     display-fill-column-indicator-column
                   fill-column)
                 (1+ (jsonyter--nb-number-digits 1)))))

(defun jsonyter--nb-restore-fill-column-indicator ()
  "Undo `jsonyter--nb-shift-fill-column-indicator'."
  (pcase jsonyter--nb-indicator-restore
    (`(set . ,value)
     (setq-local display-fill-column-indicator-column value))
    ('kill
     (kill-local-variable 'display-fill-column-indicator-column)))
  (setq jsonyter--nb-indicator-restore nil))

(defun jsonyter--nb-numbers-activate ()
  "Start showing per-cell numbers in this notebook buffer."
  (setq jsonyter--nb-numbers-active t)
  (jsonyter--nb-shift-fill-column-indicator)
  (add-function :filter-return (local 'filter-buffer-substring-function)
                #'jsonyter--nb-strip-number-props)
  (dolist (cell (jsonyter--nb-cells))
    (jsonyter--nb-refresh-prompt cell)
    (jsonyter--nb-number-lines cell (overlay-start cell) (overlay-end cell))))

(defun jsonyter--nb-numbers-deactivate ()
  "Stop showing per-cell numbers and take every one of them out of the buffer.
Strips the properties from each cell's source, redraws the prompts without
the number and, when `display-line-numbers-mode' is on, gives the buffer
Emacs's own numbers back."
  (when jsonyter--nb-numbers-active
    (setq jsonyter--nb-numbers-active nil)
    (jsonyter--nb-restore-fill-column-indicator)
    (remove-function (local 'filter-buffer-substring-function)
                     #'jsonyter--nb-strip-number-props)
    (with-silent-modifications
      (dolist (cell (jsonyter--nb-cells))
        (remove-list-of-text-properties (overlay-start cell)
                                        (jsonyter--nb-source-end cell)
                                        '(line-prefix wrap-prefix))))
    (dolist (cell (jsonyter--nb-cells))
      (jsonyter--nb-refresh-prompt cell))
    (when (bound-and-true-p display-line-numbers-mode)
      (setq-local display-line-numbers t))))

(defun jsonyter--nb-line-numbers-sync ()
  "Bring this notebook's numbering in step with the user's setting.
On `display-line-numbers-mode-hook' (buffer-locally), which runs after the
mode has set `display-line-numbers', and once when `jsonyter-notebook-mode'
starts.  Per-cell numbers are wanted when `jsonyter-notebook-line-numbers'
is `cell', the mode is on and its numbering is absolute (`t'): relative and
visual numbering are left to Emacs.  While they are showing,
`display-line-numbers' is set back to nil, so Emacs's own numbers are not
drawn too, and the mode stays on to record that the user wants numbers."
  (let ((want (and (eq jsonyter-notebook-line-numbers 'cell)
                   (bound-and-true-p display-line-numbers-mode)
                   (eq display-line-numbers t))))
    (cond ((and want (not jsonyter--nb-numbers-active))
           (jsonyter--nb-numbers-activate))
          ((and (not want) jsonyter--nb-numbers-active)
           (jsonyter--nb-numbers-deactivate)))
    (when jsonyter--nb-numbers-active
      (setq-local display-line-numbers nil))))

;;; Building the buffer

(defun jsonyter--nb-render (notebook)
  "Replace the current buffer with a rendered view of NOTEBOOK."
  (let ((inhibit-read-only t)
        (jsonyter--nb-cell-surgery t))
    (jsonyter--nb-forget-cells)
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

(defun jsonyter--nb-collect-cells (&optional include-outputs all-outputs)
  "The buffer's cells as a list of plists for `write_notebook' or export.

With INCLUDE-OUTPUTS, a cell touched this session — run, or explicitly
cleared, since the notebook was opened — also carries its current
`outputs'/`execution_count'.  A cell never touched omits the key
entirely, which is what tells the bridge to leave its stored output on
disk exactly as it was; see `jsonyter--nb-set-output'.

ALL-OUTPUTS is for `export_notebook' only — `write_notebook' must never
pass it.  A code cell that has not been touched this session then
contributes the outputs it was read from the file with
\(`jsonyter-file-outputs', already in nbformat shape — not the kernel
shape `jsonyter--nb-output-to-spec' converts from\), rather than omitting
the key, so an export of a notebook nothing has been re-run in still
carries its stored results instead of coming out blank.  Has no effect
unless INCLUDE-OUTPUTS is also set.  Also omits `:id' entirely for a new
cell instead of sending `:null', since this path hands the notebook
straight to nbformat rather than through `write_notebook''s own id
assignment."
  (mapcar
   (lambda (cell)
     (let ((touched (overlay-get cell 'jsonyter-outputs-touched))
           (code-p (equal (overlay-get cell 'jsonyter-cell-type) "code"))
           (id (overlay-get cell 'jsonyter-cell-id)))
       (append
        (if (and all-outputs (not id)) nil (list :id (or id :null)))
        (list :cell_type (overlay-get cell 'jsonyter-cell-type)
              :source (jsonyter--nb-cell-source cell))
        (cond
         ((and include-outputs touched)
          (list :outputs (vconcat (mapcar #'jsonyter--nb-output-to-spec
                                          (overlay-get cell 'jsonyter-raw-outputs)))
                :execution_count (or (overlay-get cell 'jsonyter-exec-count) :null)))
         ((and include-outputs all-outputs code-p)
          (list :outputs (jsonyter--nb-outputs-for-wire (overlay-get cell 'jsonyter-file-outputs))
                :execution_count (or (overlay-get cell 'jsonyter-exec-count) :null)))))))
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
images, HTML, plain text, the common case for a matplotlib figure, and
the list-of-line-fragments shape the kernel protocol really uses for
many of them — round-trip correctly, reshaped for the wire the same way
`jsonyter--mime' reshapes them for rendering; a mimetype whose JSON
value nests further arrays does not, since this library parses JSON
arrays as Lisp lists rather than vectors throughout.  Not expected to
matter for anything but exotic interactive-widget output."
  (let ((type (plist-get output :type)))
    (pcase type
      ("stream" (list :output_type "stream"
                      :name (or (plist-get output :name) "stdout")
                      :text (jsonyter--nb-text (plist-get output :text))))
      ((or "display_data" "execute_result" "update_display_data")
       (append (list :output_type (if (equal type "update_display_data")
                                      "display_data" type)
                     :data (jsonyter--nb-data-for-wire (plist-get output :data))
                     :metadata (jsonyter--nb-data-for-wire (plist-get output :metadata)))
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

(defun jsonyter--nb-put-cell (pos cell-type source)
  "Insert a CELL-TYPE cell carrying SOURCE, beginning at POS.
Like `jsonyter--nb-insert-cell' but with content: SOURCE (a string, a
trailing newline optional) becomes the whole of the new cell's source.
Returns the new cell overlay."
  (goto-char pos)
  (let* ((jsonyter--nb-cell-surgery t)
         (inhibit-read-only t)
         (start (point))
         (adjacent (seq-filter (lambda (o) (= (overlay-start o) start))
                               (jsonyter--nb-cells)))
         (text (if (string-suffix-p "\n" source) source (concat source "\n"))))
    (insert text)
    (dolist (o adjacent) (move-overlay o (point) (overlay-end o)))
    (prog1 (jsonyter--nb-make-cell
            start (point)
            (list :id nil :cell_type cell-type :outputs nil))
      (goto-char start))))

;;; LaTeX macros

(defconst jsonyter--nb-latex-marker "<!-- jsonyter:latex-macros -->"
  "Sentinel first line of the markdown cell jsonyter keeps LaTeX macros in.
An HTML comment, so it renders as nothing; its job is to let
`jsonyter-notebook-insert-latex-macros' find and replace its own cell
rather than stack another one on every call.")

(defun jsonyter--nb-latex-source ()
  "Markdown source for the LaTeX-macros cell, or nil if none are configured."
  (when jsonyter-notebook-latex-macros
    (concat jsonyter--nb-latex-marker "\n$$\n"
            (mapconcat #'identity jsonyter-notebook-latex-macros "\n")
            "\n$$")))

(defun jsonyter--nb-latex-cell ()
  "The jsonyter-managed LaTeX-macros cell overlay in this buffer, or nil."
  (seq-find (lambda (c)
              (and (equal (overlay-get c 'jsonyter-cell-type) "markdown")
                   (string-prefix-p jsonyter--nb-latex-marker
                                    (jsonyter--nb-cell-source c))))
            (jsonyter--nb-cells)))

;;;###autoload
(defun jsonyter-notebook-insert-latex-macros ()
  "Put a markdown cell of LaTeX macro definitions at the top of the notebook.

The macros come from `jsonyter-notebook-latex-macros' — one entry per
line, typically a \\newcommand.  The cell is marked with a sentinel HTML
comment, so calling this again replaces that cell rather than adding a
second one; MathJax in Jupyter (and nbconvert) reads the \\newcommands
and applies them to every later cell's math.

With `jsonyter-notebook-latex-macros' nil, an existing macros cell is
removed."
  (interactive)
  (jsonyter--nb-ensure-notebook)
  (let ((existing (jsonyter--nb-latex-cell))
        (source (jsonyter--nb-latex-source))
        (n (length jsonyter-notebook-latex-macros)))
    (unless (or existing source)
      (user-error "jsonyter: set `jsonyter-notebook-latex-macros' first"))
    (when existing (jsonyter--nb-excise-cell existing))
    (if source
        (progn
          (jsonyter--nb-put-cell (point-min) "markdown" source)
          (goto-char (point-min))
          (set-buffer-modified-p t)
          (message "jsonyter: %d LaTeX macro%s at the top of the notebook"
                   n (if (= n 1) "" "s")))
      (set-buffer-modified-p t)
      (message "jsonyter: removed the LaTeX-macros cell"))))

(defun jsonyter--nb-ensure-notebook ()
  "Signal an error unless the current buffer is a rendered notebook.
The cell-editing commands are autoloaded and may be bound outside
`jsonyter-notebook-mode-map', so they check rather than trusting the
keymap they were reached through."
  (unless (bound-and-true-p jsonyter-notebook-mode)
    (user-error "Not in a jsonyter notebook buffer")))

;;;###autoload
(defun jsonyter-insert-cell-below (&optional arg)
  "Insert an empty cell below the cell at point.
With no prefix argument the cell is a code cell; `C-u' makes it
markdown and `C-u C-u' makes it raw.  A Lisp caller may pass one of
the strings code, markdown or raw; see `jsonyter--nb-type-from-prefix'."
  (interactive "P")
  (jsonyter--nb-ensure-notebook)
  (let ((cell (jsonyter--nb-cell-at)))
    (jsonyter--nb-insert-cell (if cell (overlay-end cell) (point-max))
                              (jsonyter--nb-type-from-prefix arg))))

;;;###autoload
(defun jsonyter-insert-cell-above (&optional arg)
  "Insert an empty cell above the cell at point.
With no prefix argument the cell is a code cell; `C-u' makes it
markdown and `C-u C-u' makes it raw.  A Lisp caller may pass one of
the strings code, markdown or raw; see `jsonyter--nb-type-from-prefix'."
  (interactive "P")
  (jsonyter--nb-ensure-notebook)
  (let ((cell (jsonyter--nb-cell-at)))
    (jsonyter--nb-insert-cell (if cell (overlay-start cell) (point-min))
                              (jsonyter--nb-type-from-prefix arg))))

;;;###autoload
(defun jsonyter-split-cell ()
  "Split the cell at point into an upper and a lower cell.
Point must be within the cell's own source, not its rendered output.
The upper cell gets the source up to point, the lower cell the rest;
both keep the original cell's type and start with no id and no output.
Point ends at the start of the lower cell."
  (interactive)
  (jsonyter--nb-ensure-notebook)
  (let ((cell (jsonyter--nb-cell-at)))
    (unless cell (user-error "No cell at point"))
    (let ((start (overlay-start cell))
          (source-end (jsonyter--nb-source-end cell))
          (split (point)))
      (when (> split source-end)
        (user-error "jsonyter: point is in the cell's output, not its source"))
      (let ((cell-type (overlay-get cell 'jsonyter-cell-type))
            (upper (buffer-substring-no-properties start split))
            (lower (buffer-substring-no-properties split source-end)))
        (jsonyter--nb-excise-cell cell)
        (let ((upper-cell (jsonyter--nb-put-cell start cell-type upper)))
          (jsonyter--nb-put-cell (overlay-end upper-cell) cell-type lower))
        (set-buffer-modified-p t)))))

(defun jsonyter--nb-excise-cell (cell)
  "Remove CELL from the buffer — source and output together — no questions asked."
  (let* ((jsonyter--nb-cell-surgery t)
         (inhibit-read-only t)
         (start (overlay-start cell))
         (end (overlay-end cell))
         (source-end (overlay-get cell 'jsonyter-source-end))
         (src-end (marker-position source-end)))
    ;; The output leaves the way it arrived: as text that was never part
    ;; of the document.  Deleting it along with the source would put it
    ;; in the undo history, and undoing would then restore a read-only
    ;; block with no cell left to own it — text the buffer would give no
    ;; way to remove again.
    (with-silent-modifications (delete-region src-end end))
    ;; Only that silent delete needs the history trimmed after it; a cell
    ;; with no output (src-end = end) had nothing removed silently, so
    ;; trimming here would throw away undo entries for the whole rest of
    ;; the buffer for no reason — which `jsonyter-notebook-insert-latex-macros'
    ;; would hit every time it refreshes the top-of-buffer macros cell.
    (when (> end src-end)
      (jsonyter--forget-undo-after src-end))
    (set-marker source-end nil)
    (delete-overlay cell)
    (delete-region start src-end)))

;;;###autoload
(defun jsonyter-delete-cell ()
  "Delete the cell at point, source and output together."
  (interactive)
  (jsonyter--nb-ensure-notebook)
  (let ((cell (jsonyter--nb-cell-at)))
    (unless cell (user-error "No cell at point"))
    (when (or (string-blank-p (jsonyter--nb-cell-source cell))
              (yes-or-no-p "Delete this cell? "))
      (jsonyter--nb-excise-cell cell))))

(defun jsonyter--nb-next-cell-type (type)
  "The cell type that follows TYPE when cycling: code, markdown, raw, code.
TYPE is \"code\", \"markdown\" or \"raw\"; anything else (including nil)
is treated like \"raw\" and gives \"code\"."
  (cond ((equal type "code") "markdown")
        ((equal type "markdown") "raw")
        ((equal type "raw") "code")
        (t "code")))

(defun jsonyter--nb-type-from-prefix (arg)
  "The cell type a cell-inserting command's argument ARG asks for.
ARG is the raw prefix argument or a Lisp caller's value:
- nil gives \"code\";
- the list (16), i.e. `C-u C-u', gives \"raw\";
- a string \"code\", \"markdown\" or \"raw\" is returned as is, and any
  other string signals (user-error \"jsonyter: unknown cell type %s\" ARG);
- any other non-nil value (t, (4), a number) gives \"markdown\", which is
  what a bare prefix argument always meant."
  (cond
   ((null arg) "code")
   ((stringp arg)
    (if (member arg '("code" "markdown" "raw"))
        arg
      (user-error "jsonyter: unknown cell type %s" arg)))
   ((equal arg '(16)) "raw")
   (t "markdown")))

(defun jsonyter--nb-set-type (cell type)
  "Change cell overlay CELL to TYPE: \"code\", \"markdown\" or \"raw\".
Any other TYPE signals a `user-error' before anything changes.  The
cell's execution count and output are dropped, since only a code cell
can carry them; its source is untouched.  The prompt is redrawn and the
cell's syntax and font-lock state refreshed, so a former code cell stops
being highlighted as code."
  (if (not (member type '("code" "markdown" "raw")))
      (user-error "jsonyter: unknown cell type %s" type)
    (overlay-put cell 'jsonyter-cell-type type)
    (overlay-put cell 'jsonyter-exec-count nil)
    (jsonyter--nb-set-output cell "")
    (jsonyter--nb-refresh-prompt cell)
    (syntax-ppss-flush-cache (overlay-start cell))
    (font-lock-flush (overlay-start cell) (overlay-end cell))))

;;;###autoload
(defun jsonyter-set-cell-type (type)
  "Set the cell at point to TYPE: \"code\", \"markdown\" or \"raw\".
Interactively, read TYPE with completion over those three names.
Changing the type drops the cell's output and execution count (see
`jsonyter--nb-set-type').  Signal a `user-error' outside a notebook,
when there is no cell at point, or for any other TYPE."
  (interactive (list (completing-read "Cell type: " '("code" "markdown" "raw") nil t)))
  (jsonyter--nb-ensure-notebook)
  (let ((cell (jsonyter--nb-cell-at)))
    (unless cell (user-error "No cell at point"))
    (jsonyter--nb-set-type cell type)
    (message "jsonyter: cell is now %s" type)))

;;;###autoload
(defun jsonyter-toggle-cell-type ()
  "Cycle the cell at point through code, markdown and raw.
A cell turned into markdown or raw loses its output, since only
code cells can carry any."
  (interactive)
  (jsonyter--nb-ensure-notebook)
  (let ((cell (jsonyter--nb-cell-at)))
    (unless cell (user-error "No cell at point"))
    (let ((new (jsonyter--nb-next-cell-type
                (overlay-get cell 'jsonyter-cell-type))))
      (jsonyter--nb-set-type cell new)
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
    (define-key map (kbd "C-c C-x") #'jsonyter-notebook-export)
    (define-key map (kbd "C-c C-v") #'jsonyter-notebook-latex-preview-toggle)
    (define-key map (kbd "C-c C-y") #'jsonyter-sync)
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
  :group 'jsonyter
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
        ;; Painting is only half of it: `syntax-ppss' parses straight
        ;; through output and non-code source alike, so an unbalanced
        ;; string/comment/paren delimiter in either re-colours every cell
        ;; after it.  `syntax-table' text properties need this non-nil to
        ;; take effect at all; do not rely on the language mode having set
        ;; it.  See `jsonyter--nb-syntax-propertize'.
        (setq-local parse-sexp-lookup-properties t)
        (setq-local syntax-propertize-function #'jsonyter--nb-syntax-propertize)
        (syntax-ppss-flush-cache (point-min))
        (add-hook 'write-contents-functions #'jsonyter-notebook-save nil t)
        (add-hook 'kill-buffer-hook #'jsonyter--cleanup nil t)
        (add-hook 'after-change-functions
                  #'jsonyter--nb-stale-after-change nil t)
        ;; Per-cell line numbers, when the user has line numbers on; see
        ;; `jsonyter-notebook-line-numbers'.
        (add-hook 'display-line-numbers-mode-hook
                  #'jsonyter--nb-line-numbers-sync nil t)
        (unless jsonyter--nb-numbers-active
          (jsonyter--nb-line-numbers-sync))
        (jsonyter-mode 1))
    (jsonyter--restore-line-spacing)
    (kill-local-variable 'font-lock-fontify-region-function)
    (kill-local-variable 'font-lock-unfontify-region-function)
    (kill-local-variable 'parse-sexp-lookup-properties)
    (kill-local-variable 'syntax-propertize-function)
    (remove-hook 'write-contents-functions #'jsonyter-notebook-save t)
    (remove-hook 'kill-buffer-hook #'jsonyter--cleanup t)
    (remove-hook 'after-change-functions #'jsonyter--nb-stale-after-change t)
    (remove-hook 'display-line-numbers-mode-hook
                 #'jsonyter--nb-line-numbers-sync t)
    (jsonyter--nb-numbers-deactivate)
    (jsonyter-mode -1)))

(defun jsonyter--nb-new-id ()
  "A fresh cell id for a notebook written at nbformat 4.5."
  (substring (md5 (format "%s-%s-%s" (float-time)
                          (random most-positive-fixnum) (emacs-pid)))
             0 12))

(defconst jsonyter--nb-kernelspec-defaults
  '(("python" "python3" "Python 3")
    ("r"      "ir"      "R")
    ("julia"  "julia"   "Julia")
    ("sas"    "sas"     "SAS"))
  "(LANGUAGE NAME DISPLAY-NAME) triples for a blank notebook's kernelspec.
`jsonyter-kernel-names' still overrides NAME; a language not listed here
falls back to the language string for NAME and its capitalization for
DISPLAY-NAME.  The value is only a hint for other tools — jsonyter
resolves the real spec from the server on the first run either way.")

(defun jsonyter--nb-blank-json (language)
  "The JSON text of a blank nbformat 4.5 notebook for LANGUAGE.
One empty code cell, a `kernelspec' resolved through
`jsonyter-kernel-names' then `jsonyter--nb-kernelspec-defaults', and
Jupyter's own one-space indentation so an unedited save is a no-op.
Every interpolated string is JSON-encoded, so an odd LANGUAGE cannot
produce a file that will not parse."
  (require 'json)
  (let* ((known (assoc-string language jsonyter--nb-kernelspec-defaults t))
         (name (json-encode-string
                (or (cdr (assoc-string language jsonyter-kernel-names t))
                    (nth 1 known)
                    language)))
         (display (json-encode-string (or (nth 2 known) (capitalize language))))
         (lang (json-encode-string language))
         (id (json-encode-string (jsonyter--nb-new-id))))
    (format "{
 \"cells\": [
  {
   \"cell_type\": \"code\",
   \"execution_count\": null,
   \"id\": %s,
   \"metadata\": {},
   \"outputs\": [],
   \"source\": []
  }
 ],
 \"metadata\": {
  \"kernelspec\": {
   \"display_name\": %s,
   \"language\": %s,
   \"name\": %s
  },
  \"language_info\": {
   \"name\": %s
  }
 },
 \"nbformat\": 4,
 \"nbformat_minor\": 5
}
"
            id display lang name lang)))

;;;###autoload
(defun jsonyter-notebook-new (path &optional language)
  "Create a new blank notebook at PATH and open it rendered.

The file is a valid nbformat 4.5 notebook with one empty code cell and
a kernelspec for LANGUAGE (default \"python\"; resolved through
`jsonyter-kernel-names' for the spec name).  No kernel is started and
the server is not contacted — that happens on the first run, exactly as
for a notebook opened from disk.

Interactively, prompts for the language and the file name."
  (interactive
   (let ((language (read-string "Notebook kernel language: " nil nil "python")))
     (list (read-file-name "New notebook: " nil nil nil "untitled.ipynb")
           language)))
  (let ((file (expand-file-name path))
        (language (if (or (null language) (string-blank-p language))
                      "python"
                    (string-trim language))))
    (unless (string-suffix-p ".ipynb" file)
      (setq file (concat file ".ipynb")))
    (when (file-exists-p file)
      (user-error "jsonyter: %s already exists" file))
    (unless (file-directory-p (file-name-directory file))
      (user-error "jsonyter: no such directory: %s" (file-name-directory file)))
    (with-temp-file file
      (insert (jsonyter--nb-blank-json language)))
    (find-file file)
    (unless (bound-and-true-p jsonyter-notebook-mode)
      (jsonyter-notebook-open))
    (when jsonyter-notebook-latex-macros
      (jsonyter-notebook-insert-latex-macros))
    (message
     "jsonyter: new %s notebook — C-c C-i add a cell · C-RET run · C-x C-s save"
     language)
    (current-buffer)))

(defvar jsonyter-notebook-latex-preview-on-open)

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
    (when jsonyter-notebook-latex-preview-on-open
      (condition-case err
          (jsonyter-notebook-latex-preview t)
        (user-error (message "%s" (cadr err)))))
    (message
     "jsonyter: %d cells, %s kernel — C-RET run · S-RET run+advance · C-c C-b run all%s"
     (length (plist-get notebook :cells)) language
     (if (display-images-p) "" " (no image display: text output only)"))))

(provide 'jsonyter-notebook)
;;; jsonyter-notebook.el ends here
