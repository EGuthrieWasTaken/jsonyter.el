;;; jsonyter-latex.el --- LaTeX preview for notebook and Org buffers -*- lexical-binding: t; -*-

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

;; LaTeX preview for notebook and Org buffers.  One part of jsonyter.el, which loads
;; every part; see jsonyter.el for the overview and the entry points.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'jsonyter-notebook)

;;;; LaTeX preview

;; Math in a markdown cell is raw TeX in this buffer.  The commands below
;; typeset each fragment with the user's own `latex' and `dvipng' (or
;; `dvisvgm') and lay the result over the fragment's text as an overlay
;; `display' image, so the cell's source -- and the saved file -- never
;; change.  Org's own preview code is deliberately not used: it finds
;; fragments with `org-element', which means nothing in a notebook buffer.

(defcustom jsonyter-latex-preview-dpi 140
  "Resolution, in dots per inch, of a LaTeX preview image (dvipng only)."
  :type 'integer
  :group 'jsonyter)

(defcustom jsonyter-latex-preview-converter 'auto
  "Program that turns the DVI file `latex' writes into an image.
`auto' uses dvipng when it is installed, else dvisvgm."
  :type '(choice (const :tag "Whichever is installed" auto)
                 (const dvipng)
                 (const dvisvgm))
  :group 'jsonyter)

(defcustom jsonyter-latex-preview-preamble
  "\\usepackage{amsmath}\n\\usepackage{amssymb}"
  "LaTeX lines placed before every previewed fragment's `\\begin{document}'.
The lines of `jsonyter-notebook-latex-macros' follow them."
  :type 'string
  :group 'jsonyter)

(defcustom jsonyter-latex-preview-cache-directory
  (expand-file-name "jsonyter-latex" temporary-file-directory)
  "Directory holding rendered LaTeX preview images, named by content hash."
  :type 'directory
  :group 'jsonyter)

(defcustom jsonyter-notebook-latex-preview-on-open nil
  "Non-nil means preview the math in every markdown cell when a notebook opens."
  :type 'boolean
  :group 'jsonyter)

(defconst jsonyter--latex-fence-regexp
  "^[ \t]*```[^\n]*\\(?:.\\|\n\\)*?\n[ \t]*```[ \t]*$"
  "Matches a fenced code block (the fences included) in markdown text.")

(defconst jsonyter--latex-code-span-regexp "`[^`\n]*`"
  "Matches an inline code span, backticks included.")

(defconst jsonyter--latex-env-regexp
  (concat "\\\\begin{\\(equation\\|align\\|gather\\|multline\\|eqnarray\\|flalign\\)"
          "\\(\\*?\\)}\\(?:.\\|\n\\)*?\\\\end{\\1\\2}")
  "Matches a display-math environment, starred or not, whole.")

(defconst jsonyter--latex-display-dollars-regexp
  "\\$\\$\\(\\(?:.\\|\n\\)*?\\)\\$\\$"
  "Matches `$$...$$'; group 1 is the TeX between the dollars.")

(defconst jsonyter--latex-bracket-regexps
  '(("\\\\\\[\\(\\(?:.\\|\n\\)*?\\)\\\\\\]" . display)
    ("\\\\(\\(\\(?:.\\|\n\\)*?\\)\\\\)" . inline))
  "Alist of (REGEXP . KIND) for the backslash-bracket and backslash-paren forms.
Group 1 of each regexp is the TeX inside.")

(defun jsonyter--latex-mask-code (text)
  "Return TEXT with the characters inside code replaced by spaces.
Code is a fenced block (`jsonyter--latex-fence-regexp') or an inline
span (`jsonyter--latex-code-span-regexp').  Newlines are kept, so the
result has TEXT's length and line structure and an offset found in it
is an offset in TEXT.  This keeps a dollar sign inside code from being
read as math."
  (let ((blank (lambda (match) (replace-regexp-in-string "[^\n]" " " match))))
    (let ((text (replace-regexp-in-string jsonyter--latex-fence-regexp blank text)))
      (replace-regexp-in-string jsonyter--latex-code-span-regexp blank text))))

(defun jsonyter--latex-find-envs (text)
  "Return the math environments in TEXT as a list of (BEG END env BODY).
BEG and END are string offsets, END exclusive, and BODY is the whole
matched text, the opening and closing environment markers included.
The list is in text order, nil when there are none."
  (let ((pos 0)
        (out nil))
    (while (string-match jsonyter--latex-env-regexp text pos)
      (push (list (match-beginning 0)
                   (match-end 0)
                   'env
                   (match-string 0 text))
            out)
      (setq pos (match-end 0)))
    (nreverse out)))

(defun jsonyter--latex-find-display-dollars (text)
  "Return the double-dollar fragments in TEXT as (BEG END display BODY) lists.
BODY is the TeX between the dollars.  The list is in text order, nil
when there are none."
  (let ((pos 0)
        (out nil))
    (while (string-match jsonyter--latex-display-dollars-regexp text pos)
      (push (list (match-beginning 0)
                   (match-end 0)
                   'display
                   (match-string 1 text))
            out)
      (setq pos (match-end 0)))
    (nreverse out)))

(defun jsonyter--latex-find-brackets (text)
  "Return the backslash-bracket and backslash-parenthesis fragments in TEXT.
Each is (BEG END KIND BODY): KIND is `display' for the bracket form and
`inline' for the parenthesis form, and BODY is the TeX inside.  The
list is in text order, nil when there are none."
  (let ((out nil))
    (dolist (spec jsonyter--latex-bracket-regexps)
      (let ((pos 0))
        (while (string-match (car spec) text pos)
          (push (list (match-beginning 0) (match-end 0)
                      (cdr spec) (match-string 1 text))
                out)
          (setq pos (match-end 0)))))
    (sort out (lambda (a b) (< (car a) (car b))))))

(defun jsonyter--latex-inline-open-p (text pos)
  "Non-nil when the dollar sign at offset POS of TEXT may open `$...$'.
It may not when the character before it is a backslash (an escaped
dollar), or when the character after it is missing, a dollar sign, a
space, a tab or a newline."
  (let ((prev (and (> pos 0) (aref text (1- pos))))
        (next (and (< (1+ pos) (length text)) (aref text (1+ pos)))))
    (not (or (eq prev ?\\)
               (null next)
               (memq next '(?$ ?\s ?\t ?\n))))))

(defun jsonyter--latex-inline-close-p (text pos)
  "Non-nil when the dollar sign at offset POS of TEXT may close `$...$'.
It may not when the character before it is a space, a tab, a newline or
a backslash, or when the character after it is a digit (which is how
\"costs $5 and $6\" is told from math)."
  (let ((before (and (> pos 0) (aref text (1- pos))))
        (after (and (< (1+ pos) (length text)) (aref text (1+ pos)))))
    (not (or (null before)
               (memq before '(?\s ?\t ?\n ?\\))
               (and after (<= ?0 after ?9))))))

(defun jsonyter--latex-inline-find-close (text open)
  "Return the offset of the dollar sign that closes the one opened at OPEN.
Return nil if there is none.  A blank line between the two ends the
search, since inline math does not span paragraphs, and a candidate
that `jsonyter--latex-inline-close-p' refuses is skipped."
  (let ((search (1+ open)) (n (length text)) close)
    (while (and (not close) (< search n) (string-match "\\$" text search))
      (let ((c (match-beginning 0)))
        (cond ((string-match-p "\n[ \t]*\n" (substring text (1+ open) c))
               (setq search n))
              ((jsonyter--latex-inline-close-p text c)
               (setq close c))
              (t (setq search (1+ c))))))
    close))

(defun jsonyter--latex-find-inline-dollars (text)
  "Return the inline dollar fragments in TEXT as (BEG END inline BODY) lists.
BEG is the offset of the opening dollar, END is one past the closing
dollar, and BODY is the TeX between them.  A dollar sign that cannot
open or close math, such as an escaped one or a price, is skipped (see
`jsonyter--latex-inline-open-p' and `jsonyter--latex-inline-close-p').
The list is in text order, nil when there are none."
  (let ((pos 0) (n (length text)) out)
    (while (and (< pos n) (string-match "\\$" text pos))
      (let* ((open (match-beginning 0))
             (close (and (jsonyter--latex-inline-open-p text open)
                         (jsonyter--latex-inline-find-close text open))))
        (if close
            (progn
              (push (list open (1+ close) 'inline
                          (substring text (1+ open) close))
                    out)
              (setq pos (1+ close)))
          (setq pos (1+ open)))))
    (nreverse out)))

(defun jsonyter--latex-fragments (text)
  "Return every math fragment in TEXT as (BEG END KIND BODY), in text order.
KIND is `inline', `display' or `env'.  Code is ignored (see
`jsonyter--latex-mask-code').  A span claimed by one form of math is not
claimed again by another: environments win over double dollars, those
over the backslash-bracket and backslash-parenthesis forms, and those
over single dollars."
  (let ((work (jsonyter--latex-mask-code text))
        (found nil))
    (dolist (finder '(jsonyter--latex-find-envs
                      jsonyter--latex-find-display-dollars
                      jsonyter--latex-find-brackets
                      jsonyter--latex-find-inline-dollars))
      (dolist (f (funcall finder work))
        (push f found)
        (setq work (concat (substring work 0 (nth 0 f))
                           (replace-regexp-in-string
                            "[^\n]" " " (substring work (nth 0 f) (nth 1 f)))
                           (substring work (nth 1 f))))))
    (sort found (lambda (a b) (< (car a) (car b))))))

(defun jsonyter--latex-document (body kind)
  "Return a complete LaTeX document that typesets the fragment BODY.
KIND is `inline', `display' or `env' and decides how BODY is wrapped: in
dollar signs, in display brackets, or not at all, since an environment
brings its own.  The document is an article with an empty page style,
and `jsonyter-latex-preview-preamble' and the lines of
`jsonyter-notebook-latex-macros' come ahead of the body."
  (concat "\\documentclass[12pt]{article}\n"
         (concat jsonyter-latex-preview-preamble "\n")
         (concat (mapconcat #'identity jsonyter-notebook-latex-macros "\n")
                   (if jsonyter-notebook-latex-macros "\n" ""))
         "\\pagestyle{empty}\n\\begin{document}\n"
         (cond ((eq kind 'inline) (concat "$" body "$"))
               ((eq kind 'display) (concat "\\[" body "\\]"))
               (t body))
         "\n\\end{document}\n"))

(defun jsonyter--latex-converter ()
  "Return `dvipng', `dvisvgm' or nil: the program to turn DVI into an image.
With `jsonyter-latex-preview-converter' set to `auto', prefer dvipng if
`executable-find' finds it, else dvisvgm if found, else nil.  With an
explicit choice, return it only if `executable-find' finds a program of
that name, else nil."
  (let ((choice jsonyter-latex-preview-converter))
    (if (eq choice 'auto)
        (cond ((executable-find "dvipng") 'dvipng)
              ((executable-find "dvisvgm") 'dvisvgm)
              (t nil))
      (and (executable-find (symbol-name choice))
           choice))))

(defun jsonyter--latex-cache-file (document converter dpi fg)
  "Return the cache path of the image for DOCUMENT rendered by CONVERTER.
The name is a hash of DOCUMENT, CONVERTER, DPI and FG, so changing any
of them gives a new file, and it ends in `.svg' for `dvisvgm' and
`.png' otherwise.  The file lives in
`jsonyter-latex-preview-cache-directory'."
  (expand-file-name
   (concat (secure-hash 'sha1 (format "%s\n%s\n%s\n%s" document converter dpi fg))
             (if (eq converter 'dvisvgm) ".svg" ".png"))
   jsonyter-latex-preview-cache-directory))

(defun jsonyter--latex-fg (&optional face)
  "Return FACE's foreground, default `default', as a dvipng colour string.
The result looks like \"rgb 1.000 0.000 0.000\".  A colour Emacs cannot
resolve gives black."
  (let* ((color (face-foreground (or face 'default) nil 'default))
         (rgb (and (stringp color) (color-name-to-rgb color))))
    (if rgb
        (format "rgb %.3f %.3f %.3f" (nth 0 rgb) (nth 1 rgb) (nth 2 rgb))
      "rgb 0.000 0.000 0.000")))

(defun jsonyter--latex-first-error (log-file)
  "Return the first line of LOG-FILE that starts with \"! \", else \"unknown error\".
\"unknown error\" is also the answer when LOG-FILE is not readable."
  (or (and (file-readable-p log-file)
           (with-temp-buffer
             (insert-file-contents log-file)
             (goto-char (point-min))
             (let ((match (re-search-forward "^! .*$" nil t)))
               (if match
                   (match-string 0)
                   nil))))
       "unknown error"))

(defun jsonyter--latex-render (document converter dpi fg)
  "Typeset DOCUMENT into an image file and return its path.
Images are cached: when `jsonyter--latex-cache-file' already exists for
these arguments it is returned without running anything.  Otherwise
`latex' runs on DOCUMENT in a temporary directory, CONVERTER (`dvipng'
or `dvisvgm') turns the result into an image at DPI dots per inch in
colour FG, and the image is copied into the cache; the temporary
directory is always removed.  Signal a `user-error' carrying LaTeX's
first error line when `latex' fails, or naming CONVERTER when it
fails."
  (let ((out (jsonyter--latex-cache-file document converter dpi fg)))
    (unless (file-exists-p out)
      (let* ((dir (make-temp-file "jsonyter-latex-" t))
             (default-directory (file-name-as-directory dir))
             (image (if (eq converter 'dvisvgm) "doc.svg" "doc.png")))
        (unwind-protect
            (progn
              (with-temp-file (expand-file-name "doc.tex" dir) (insert document))
              (unless (eq 0 (call-process "latex" nil nil nil "-interaction=nonstopmode"
                                          "-halt-on-error" "doc.tex"))
                (user-error "jsonyter: LaTeX failed: %s"
                            (jsonyter--latex-first-error
                             (expand-file-name "doc.log" dir))))
              (unless (eq 0 (if (eq converter 'dvisvgm)
                                (call-process "dvisvgm" nil nil nil "--no-fonts" "--exact"
                                              "-o" image "doc.dvi")
                              (call-process "dvipng" nil nil nil "-T" "tight"
                                            "-D" (number-to-string dpi)
                                            "-bg" "Transparent" "-fg" fg
                                            "-o" image "doc.dvi")))
                (user-error "jsonyter: %s failed" converter))
              (make-directory (file-name-directory out) t)
              (copy-file (expand-file-name image dir) out t))
          (delete-directory dir t))))
    out))

(defun jsonyter--latex-image (file)
  "Return a `display' value showing the image FILE.
That is an `svg' or `png' image, by the file's extension, centered on
its line, when this Emacs can display one; otherwise a short
placeholder string naming the file."
  (let ((type (if (string-suffix-p ".svg" file) 'svg 'png)))
    (if (and (display-images-p) (image-type-available-p type))
        (create-image file type nil :ascent 'center)
      (format "[math: %s]" (file-name-nondirectory file)))))

(defun jsonyter--latex-check-tools ()
  "Signal a `user-error' unless LaTeX preview can run; return nil if it can.
Preview needs `latex' and either `dvipng' or `dvisvgm' on the
`exec-path'; the error names what is missing."
  (unless (executable-find "latex")
    (user-error "jsonyter: LaTeX preview needs `latex' on the exec-path"))
  (unless (jsonyter--latex-converter)
    (user-error "jsonyter: LaTeX preview needs `dvipng' or `dvisvgm' on the exec-path")))

(defun jsonyter--nb-latex-clear (beg end)
  "Delete every LaTeX preview overlay between BEG and END; return how many.
A preview overlay has a non-nil `jsonyter-latex-preview' property.  Other
overlays are left alone."
  (let ((n 0))
    (dolist (ov (overlays-in beg end))
      (when (overlay-get ov 'jsonyter-latex-preview)
        (delete-overlay ov)
        (setq n (1+ n))))
    n))

(defun jsonyter--nb-latex-overlay-modified (ov after _beg _end &optional _len)
  "Delete preview overlay OV when the text under it is about to change.
For an overlay's `modification-hooks': it runs before and after a change
and acts only before, so the source reappears as soon as it is edited."
  (unless after (delete-overlay ov)))

(defun jsonyter--nb-latex-preview-cell (cell)
  "Show the math in markdown cell CELL as images; return how many were shown.
Previews already in CELL are replaced.  Each fragment of the cell's
source (see `jsonyter--latex-fragments') is typeset at
`jsonyter-latex-preview-dpi', in the buffer's foreground colour, and
covered by an overlay that displays the image, shows the TeX as its
tooltip and is deleted when the text beneath it is edited.  A fragment
that fails to typeset is skipped, with LaTeX's first error line in the
echo area, and does not stop the others."
  (let* ((start (overlay-start cell))
         (source (jsonyter--nb-cell-source cell))
         (fg (jsonyter--latex-fg))
         (converter (jsonyter--latex-converter))
         (count 0))
    (jsonyter--nb-latex-clear start (overlay-end cell))
    (dolist (frag (jsonyter--latex-fragments source))
      (condition-case err
          (let* ((doc (jsonyter--latex-document (nth 3 frag) (nth 2 frag)))
                 (file (jsonyter--latex-render doc converter
                                               jsonyter-latex-preview-dpi fg))
                 (ov (make-overlay (+ start (nth 0 frag))
                                   (+ start (nth 1 frag)))))
            (overlay-put ov 'jsonyter-latex-preview t)
            (overlay-put ov 'display (jsonyter--latex-image file))
            (overlay-put ov 'evaporate t)
            (overlay-put ov 'help-echo (nth 3 frag))
            (overlay-put ov 'modification-hooks
                         '(jsonyter--nb-latex-overlay-modified))
            (setq count (1+ count)))
        (user-error
         (message "jsonyter: LaTeX preview skipped -- %s" (cadr err)))))
    count))

(defun jsonyter--nb-latex-markdown-cells ()
  "Return the cells that can be previewed.
Those are the markdown cells other than the managed LaTeX macros cell."
  (let ((macros (jsonyter--nb-latex-cell)))
    (seq-filter (lambda (c)
                  (and (equal (overlay-get c 'jsonyter-cell-type) "markdown")
                       (not (eq c macros))))
                (jsonyter--nb-cells))))

(defun jsonyter--nb-latex-target-cells (all)
  "Return the cells a preview command acts on.
With ALL, every previewable cell; otherwise only the cell at point, which
must be a markdown cell other than the macros cell, or a `user-error' is
signalled."
  (if all
      (jsonyter--nb-latex-markdown-cells)
    (let ((cell (jsonyter--nb-cell-at)))
      (if (and cell (memq cell (jsonyter--nb-latex-markdown-cells)))
          (list cell)
        (user-error "jsonyter: not a markdown cell")))))

;;;###autoload
(defun jsonyter-notebook-latex-preview (&optional all)
  "Show the math in the markdown cell at point as images.
With a prefix argument ALL, do it for every markdown cell.  The math it
finds is dollar-delimited (single or double), the backslash-bracket and
backslash-parenthesis forms, and the amsmath environments; code blocks
and spans are skipped.  Needs `latex' and `dvipng' or `dvisvgm'.  Report
how many fragments were previewed and return that number."
  (interactive "P")
  (jsonyter--nb-ensure-notebook)
  (jsonyter--latex-check-tools)
  (let ((n 0))
    (dolist (cell (jsonyter--nb-latex-target-cells all))
      (setq n (+ n (jsonyter--nb-latex-preview-cell cell))))
    (message "jsonyter: previewed %d LaTeX fragment%s" n (if (= n 1) "" "s"))
    n))

;;;###autoload
(defun jsonyter-notebook-latex-preview-clear (&optional all)
  "Remove LaTeX preview images from the cell at point; with ALL, every cell.
The source text underneath is untouched.  Report how many previews were
removed and return that number."
  (interactive "P")
  (jsonyter--nb-ensure-notebook)
  (let ((n 0))
    (dolist (cell (if all
                      (jsonyter--nb-cells)
                    (let ((c (jsonyter--nb-cell-at))) (and c (list c)))))
      (setq n (+ n (jsonyter--nb-latex-clear (overlay-start cell)
                                             (overlay-end cell)))))
    (message "jsonyter: removed %d LaTeX preview%s" n (if (= n 1) "" "s"))
    n))

;;;###autoload
(defun jsonyter-notebook-latex-preview-toggle (&optional all)
  "Preview the markdown cell at point, or clear it if previews are showing.
With a prefix argument ALL, act on every cell: previews are cleared
when any cell has one showing, and made otherwise."
  (interactive "P")
  (jsonyter--nb-ensure-notebook)
  (let* ((cells (if all
                    (jsonyter--nb-cells)
                  (let ((c (jsonyter--nb-cell-at))) (and c (list c)))))
         (showing (seq-some
                   (lambda (c)
                     (seq-some (lambda (ov) (overlay-get ov 'jsonyter-latex-preview))
                               (overlays-in (overlay-start c) (overlay-end c))))
                   cells)))
    (if showing
        (jsonyter-notebook-latex-preview-clear all)
      (jsonyter-notebook-latex-preview all))))

(provide 'jsonyter-latex)
;;; jsonyter-latex.el ends here
