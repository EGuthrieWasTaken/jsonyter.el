;;; jsonyter-convert.el --- .ipynb <-> .org conversion -*- lexical-binding: t; -*-

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

;; .ipynb <-> .org conversion.  One part of jsonyter.el, which loads
;; every part; see jsonyter.el for the overview and the entry points.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'jsonyter-org)
(require 'jsonyter-notebook)

(declare-function org-element-at-point "org-element" (&optional pom cached-only))
(declare-function org-element-type "org-element-ast" (node &optional anonymous))
(declare-function org-element-property "org-element-ast" (property node))
(declare-function org-babel-get-src-block-info "ob-core" (&optional light datum))
(declare-function org-babel-where-is-src-block-result "ob-core" (&optional insert info hash))
(defvar org-babel-src-block-regexp)

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
  :type 'string
  :group 'jsonyter)

(defcustom jsonyter-org-markdown-converter nil
  "Function converting between Markdown and Org, or nil for the built-in choice.
Called as (FUNCTION TEXT DIRECTION), DIRECTION being `to-org' or
`to-markdown'; must return the converted text.  When nil, jsonyter shells
out to `pandoc' if it is on the variable `exec-path', and otherwise inserts TEXT
unchanged with a note saying so -- accurate about there being no real
conversion available, rather than silently claiming one where none
happened.  Markdown <-> Org is the one lossy step in the whole round
trip; this is the escape hatch for anyone who wants a better one."
  :type '(choice (const nil) function)
  :group 'jsonyter)

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
  "nbformat-shape outputs for INFO's block's current `#+RESULTS:' drawer, or nil.

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
this section for why a drawer here carries no heading.

A buffer with no `:JSONYTER_CELL_ID:' drawer at all -- any Org file
`jsonyter-org-from-notebook' did not itself write -- falls back to
`jsonyter--org-notebook-cell-spans--by-block': without this, the whole
buffer is one span with a nil id, which `jsonyter--org-notebook-cell-from-span'
then reads as a single markdown cell containing every `#+begin_src' block
verbatim, silently, since only the first span's shape is ever consulted
to tell code from prose."
  (if (save-excursion (goto-char (point-min))
                      (re-search-forward jsonyter--org-cell-id-re nil t))
      (jsonyter--org-notebook-cell-spans--by-drawer)
    (jsonyter--org-notebook-cell-spans--by-block)))

(defun jsonyter--org-notebook-cell-spans--by-drawer ()
  "`jsonyter--org-notebook-cell-spans', the original drawer-splitting path."
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

(defun jsonyter--org-notebook-cell-spans--by-block ()
  "`jsonyter--org-notebook-cell-spans', the no-drawer fallback.
Splits at `jy:' `#+begin_src'/`#+end_src' boundaries instead of drawers:
the prose before the first block, between two blocks, or after the last
becomes a markdown span; each block's own `#+begin_src' through
`#+end_src' text becomes a code span -- exactly the two shapes
`jsonyter--org-notebook-cell-from-span' already knows how to read.  Every
span's id is nil, so every cell comes out as new; there is no drawer
here to merge onto.  A non-`jy:' block is left embedded in the
surrounding prose span, same as any other text -- only `jy:' blocks are
\"cells\" for this conversion, per `jsonyter-org-to-notebook''s own
docstring.

Deliberately does not walk blocks via `jsonyter--org-goto-next-jy-block'
\(built on `org-babel-next-src-block'): that command's \"next\" is
relative to the *line point is already on*, so when the very first thing
in the buffer is a block, starting the scan at `point-min' -- sitting
squarely on that block's own `#+begin_src' line -- makes it skip that
block entirely and jump to the *second* one, silently folding the whole
first block into the leading prose span instead of splitting it out.
Scanning with `org-babel-src-block-regexp' directly has no such
\"current line\" exclusion."
  (require 'ob-core)
  (let (spans (start (point-min)))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward org-babel-src-block-regexp nil t)
        ;; `jsonyter--org-in-jy-block-p' parses the block with org-babel,
        ;; which does its own regexp searches and clobbers this loop's
        ;; match data -- capture everything from THIS match before
        ;; calling it, or `(match-end 0)' below reads someone else's
        ;; match and point can fail to advance, looping forever.
        (let ((block-start (match-beginning 0))
              (after-match (match-end 0)))
          (goto-char block-start)
          (if (jsonyter--org-in-jy-block-p)
              (let* ((el (org-element-at-point))
                     (raw-end (org-element-property :end el))
                     (block-end
                      (save-excursion
                        (goto-char block-start)
                        (if (re-search-forward "^[ \t]*#\\+end_src.*\n" raw-end t)
                            (point)
                          raw-end)))
                     ;; Extend the span over the block's own `#+RESULTS:',
                     ;; the way the `--by-drawer' path gets it for free by
                     ;; splitting at the *next* drawer instead -- without
                     ;; this, the results fall into the following prose
                     ;; span, the code cell is rebuilt with no outputs at
                     ;; all (nothing to find when the span is re-parsed in
                     ;; its own temp buffer), and the drawer's raw text is
                     ;; re-emitted as a markdown cell.
                     (result-end
                      (save-excursion
                        (goto-char block-start)
                        (let* ((info (org-babel-get-src-block-info 'light))
                               (pos (and info (org-babel-where-is-src-block-result nil info))))
                          (when pos
                            (goto-char pos)
                            (org-element-property :end (org-element-at-point)))))))
                (when (and result-end (> result-end block-end))
                  (setq block-end result-end))
                (let ((prose (buffer-substring-no-properties start block-start)))
                  (unless (jsonyter--org-notebook-span-empty-p prose)
                    (push (cons nil prose) spans)))
                (push (cons nil (buffer-substring-no-properties block-start block-end)) spans)
                (setq start block-end)
                (goto-char block-end))
            ;; Not a jy: block: leave it for the surrounding prose span
            ;; and resume scanning right after this match.
            (goto-char after-match))))
      (let ((prose (buffer-substring-no-properties start (point-max))))
        (unless (jsonyter--org-notebook-span-empty-p prose)
          (push (cons nil prose) spans))))
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
                 ;; Already nbformat shape (`jsonyter--org-parse-results-drawer'
                 ;; produces exactly what `write_notebook' wants) -- NOT run
                 ;; through `jsonyter--nb-output-to-spec', which converts from
                 ;; the kernel protocol's `:type'-keyed shape instead, and
                 ;; would turn every one of these into an unrecognized-output
                 ;; placeholder.
                 (outputs (and info (jsonyter--org-parse-results-drawer info base-dir))))
            (append (list :id (or id :null) :cell_type "code" :source source)
                    (and outputs
                         (list :outputs (vconcat outputs)
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

Works equally on a hand-authored file that has never round-tripped
through `jsonyter-org-from-notebook' and so has no id drawers at all: see
`jsonyter--org-notebook-cell-spans' for how the split adapts.

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

(provide 'jsonyter-convert)
;;; jsonyter-convert.el ends here
