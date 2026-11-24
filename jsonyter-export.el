;;; jsonyter-export.el --- Notebook and script export -*- lexical-binding: t; -*-

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

;; Notebook and script export.  One part of jsonyter.el, which loads
;; every part; see jsonyter.el for the overview and the entry points.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'jsonyter-convert)
(require 'jsonyter-script)
(require 'jsonyter-transfer)
(require 'jsonyter-notebook)

(declare-function org-element-at-point "org-element" (&optional pom cached-only))
(declare-function org-element-type "org-element-ast" (node &optional anonymous))
(declare-function org-element-property "org-element-ast" (property node))
(declare-function org-babel-get-src-block-info "ob-core" (&optional light datum))
(declare-function org-babel-where-is-src-block-result "ob-core" (&optional insert info hash))
(defvar org-babel-src-block-regexp)

;;;; Notebook document export (HTML, PDF, LaTeX, ... via the bridge)

;; Two bridge verbs new in jsonyter 2.0.0, both dispatched on the REST
;; pool, never a kernel worker -- so a multi-minute PDF render cannot
;; queue behind a running `execute', and export is safe to fire while a
;; cell is running.  It is deliberately NOT gated by `jsonyter--busy-p'.
;;
;; POST, not GET: a notebook buffer's `.ipynb' is a local file (see
;; `jsonyter--nb-do-save'), so `server_path' -- a path in the Jupyter
;; server's own Contents API namespace -- is the wrong mode for the
;; ordinary case, where there is no such server path at all.  Every
;; command here builds its notebook from the buffer's own cells (the
;; `cells' param, POST) instead, which also exports what the user is
;; looking at right now -- unsaved edits and this session's outputs
;; included -- rather than whatever is last saved to disk.  `server_path'
;; is reserved for `jsonyter-remote-dired-export', which genuinely has a
;; real server path in hand.

(defvar-local jsonyter--export-formats-cache nil
  "Cons (PROCESS . REPLY) memoizing the last `list_export_formats' call.
The probe result cannot change under a running server, so there is
nothing to invalidate beyond a changed bridge process; see
`jsonyter--list-export-formats'.")

(defun jsonyter--list-export-formats (&optional refresh)
  "This buffer's bridge's export capability.
A (:available :formats :reason) plist -- never errors for an
unavailable endpoint, since the bridge itself guarantees that, so this
is always safe to call.  Cached per bridge process; pass REFRESH to
force a fresh probe.

Degrades an old bridge that predates this verb entirely to a clear
message rather than a raw protocol error: export needs jsonyter
>= 2.0.0, and the commentary header's own version note has been bumped
to say so."
  (jsonyter--ensure-bridge)
  (if (and (not refresh)
           jsonyter--export-formats-cache
           (eq (car jsonyter--export-formats-cache) jsonyter--process))
      (cdr jsonyter--export-formats-cache)
    (let ((reply
           (condition-case err
               (jsonyter--request-sync "list_export_formats" nil jsonyter-startup-timeout)
             (error
              (if (string-match-p
                   "unknown method\\|no such method\\|not supported\\|unrecognized"
                   (error-message-string err))
                  (user-error
                   "jsonyter: this bridge does not support export (needs jsonyter >= 2.0.0; upgrade with `pip install -U jsonyter')")
                (signal (car err) (cdr err)))))))
      (setq jsonyter--export-formats-cache (cons jsonyter--process reply))
      reply)))

(defun jsonyter--export-format-names (formats)
  "Format-name strings from FORMATS, `list_export_formats''s own plist."
  (let (names)
    (cl-loop for (key _val) on formats by #'cddr
             do (push (substring (symbol-name key) 1) names))
    (nreverse names)))

;;;###autoload
(defun jsonyter-notebook-export-formats ()
  "Show the export formats this notebook's Jupyter server offers.
The first thing to reach for when debugging why an export command
refuses to run, or before waiting on a slow one that will only fail."
  (interactive)
  (unless (bound-and-true-p jsonyter-notebook-mode)
    (user-error "jsonyter: not a notebook buffer"))
  (let ((probe (jsonyter--list-export-formats 'refresh)))
    (if (plist-get probe :available)
        (message "jsonyter: export formats on %s: %s"
                 jsonyter-server-url
                 (mapconcat #'identity
                            (jsonyter--export-format-names (plist-get probe :formats))
                            ", "))
      (message "jsonyter: export not available on %s -- %s"
               jsonyter-server-url
               (or (plist-get probe :reason) "unknown reason")))))

(defconst jsonyter--export-format-extensions
  '(("html" . ".html") ("markdown" . ".md") ("pdf" . ".pdf")
    ("latex" . ".tex") ("webpdf" . ".pdf") ("qtpdf" . ".pdf")
    ("qtpng" . ".png") ("slides" . ".slides.html") ("script" . ".txt")
    ("asciidoc" . ".adoc") ("rst" . ".rst") ("notebook" . ".ipynb"))
  "Best-guess extension per nbconvert format name, for defaulting a
`read-file-name' prompt before the export has actually run -- the
server's own, canonical `extension' is only known from the export
result itself (see the design notes' §4.4), which does not exist yet at
prompt time.  Whatever TO-PATH the user confirms is what
`jsonyter-notebook-export' actually writes to, this guess or not.")

(defun jsonyter--export-format-guess-extension (format)
  "A reasonable default extension for FORMAT, for prompting only."
  (or (cdr (assoc format jsonyter--export-format-extensions))
      (concat "." format)))

(defun jsonyter--revert-if-visiting (path)
  "Revert the buffer visiting PATH, if one is open."
  (let ((buf (find-buffer-visiting path)))
    (when buf
      (condition-case nil
          (with-current-buffer buf
            (revert-buffer t (not (buffer-modified-p)) t))
        (error nil)))))

(defun jsonyter--export-run (session params on-success)
  "Run `export_notebook' with PARAMS through this buffer's bridge, async.

There are no `progress' events for export (unlike a file transfer), so
this shows a plain \"exporting...\" message plus an `:export' mode-line
tag rather than a percentage.  Reuses `jsonyter--session-transfer' --
the established pattern (`jsonyter--transfer-run') for a REST-pool
operation that wants to show itself in the mode line -- rather than
inventing a parallel slot; `jsonyter--session-status-tag' renders the
`export' phase specially, with no percentage.

SESSION may be nil (a notebook that has never had a kernel); the
mode-line tag is then simply not shown, harmlessly.  ON-SUCCESS is
called with the result plist on success; a failure is reported in the
echo area via `jsonyter--error-message', which renders `ExportError''s
own `hint' and `available_formats'."
  (let ((format (plist-get params :format)))
    (when session
      (setf (jsonyter--session-transfer session) (list :phase "export"))
      (force-mode-line-update t))
    (message "jsonyter: exporting to %s..." format)
    (condition-case err
        (jsonyter--send
         "export_notebook" params
         (list
          :result
          (lambda (msg)
            (when session
              (setf (jsonyter--session-transfer session) nil)
              (force-mode-line-update t))
            (let ((rerr (plist-get msg :error))
                  (result (plist-get msg :result)))
              (cond
               (rerr (message "jsonyter: export to %s failed — %s"
                              format (jsonyter--error-message rerr)))
               (result (funcall on-success result)))))))
      (error
       ;; `jsonyter--send' signalled synchronously (a dead bridge): no
       ;; reply is coming, so clear the tag it just set.
       (when session
         (setf (jsonyter--session-transfer session) nil)
         (force-mode-line-update t))
       (signal (car err) (cdr err))))))

;;;###autoload
(defun jsonyter-notebook-export (format to-path &optional timeout)
  "Export this notebook to FORMAT, writing the result to TO-PATH.

Always includes this session's outputs and every cell's stored results
\(see `jsonyter--nb-collect-cells''s ALL-OUTPUTS parameter\), so the
export reflects the buffer as it stands right now -- unsaved edits
included -- not merely what was last saved to disk.  Also sends the
notebook's own top-level metadata \(`jsonyter--nb-metadata'\), so
nbconvert's templates still see a `kernelspec' and `language_info' --
without it, `export_notebook' has only `:cells' to build a document
from and has no language to highlight by.

Runs on the bridge's REST pool, not a kernel worker: safe to run while a
cell is executing, and not gated by a busy kernel the way running a cell
is.  Asynchronous, since a PDF or webpdf render is seconds-to-minutes
\(bounded by TIMEOUT, default `jsonyter-export-timeout'\), and blocking
Emacs for that long is not acceptable.

Interactively, FORMAT is read via `completing-read' over what this
server's `list_export_formats' actually offers -- never a hardcoded
list, so a third-party exporter the server registers shows up for free
-- refusing early, before any request that would take two minutes to
fail, when the server offers none at all.  TO-PATH is read via
`read-file-name', defaulting to the buffer's own name with a best-guess
extension for FORMAT; see `jsonyter--export-format-guess-extension'."
  (interactive
   (progn
     (unless (bound-and-true-p jsonyter-notebook-mode)
       (user-error "jsonyter: not a notebook buffer"))
     (let* ((probe (jsonyter--list-export-formats))
            (formats (and (plist-get probe :available)
                         (jsonyter--export-format-names (plist-get probe :formats)))))
       (unless formats
         (user-error "jsonyter: export not available on %s -- %s"
                     jsonyter-server-url
                     (or (plist-get probe :reason) "unknown reason")))
       (let* ((format (completing-read "Export format: " formats nil t))
              (default (concat (file-name-sans-extension
                                (or buffer-file-name "untitled"))
                               (jsonyter--export-format-guess-extension format))))
         (list format
               (read-file-name "Export to: " nil default nil
                               (file-name-nondirectory default)))))))
  (unless (bound-and-true-p jsonyter-notebook-mode)
    (user-error "jsonyter: not a notebook buffer"))
  (jsonyter--ensure-bridge)
  (let* ((cells (jsonyter--nb-collect-cells t t))
         (session (jsonyter--session-put jsonyter--session-key))
         (path (expand-file-name to-path)))
    (jsonyter--export-run
     session
     (list :format format :cells (vconcat cells) :to_path path
           :metadata (or jsonyter--nb-metadata (list))
           :include_outputs t :timeout (or timeout jsonyter-export-timeout))
     (lambda (result)
       (jsonyter--revert-if-visiting (plist-get result :path))
       (dolist (res (append (plist-get result :resources) nil))
         (jsonyter--revert-if-visiting (plist-get res :path)))
       (message "jsonyter: exported %s to %s (%s)%s"
                (plist-get result :format)
                (plist-get result :path)
                (file-size-human-readable (or (plist-get result :bytes) 0)
                                          nil " " "B")
                (let ((n (length (plist-get result :resources))))
                  (if (> n 0) (format ", %d resource%s" n (if (= n 1) "" "s")) "")))))))

;; Thin wrappers for the formats worth a name of their own.  Each reads
;; TO-PATH the same way `jsonyter-notebook-export' itself does, with
;; FORMAT already fixed, and calls straight into it -- so a missing
;; exporter is still caught by that command's own probe check before any
;; request that would take two minutes to fail.

(defun jsonyter--export-read-to-path (format)
  "Read a TO-PATH for FORMAT the way `jsonyter-notebook-export' does."
  (let ((default (concat (file-name-sans-extension (or buffer-file-name "untitled"))
                         (jsonyter--export-format-guess-extension format))))
    (read-file-name "Export to: " nil default nil (file-name-nondirectory default))))

;;;###autoload
(defun jsonyter-notebook-export-html (to-path)
  "Export this notebook to HTML, writing the result to TO-PATH.
A thin wrapper around `jsonyter-notebook-export' with FORMAT fixed to
\"html\"; see its docstring for what this does."
  (interactive (list (jsonyter--export-read-to-path "html")))
  (jsonyter-notebook-export "html" to-path))

;;;###autoload
(defun jsonyter-notebook-export-markdown (to-path)
  "Export this notebook to Markdown, writing the result to TO-PATH.
A thin wrapper around `jsonyter-notebook-export' with FORMAT fixed to
\"markdown\"; see its docstring for what this does."
  (interactive (list (jsonyter--export-read-to-path "markdown")))
  (jsonyter-notebook-export "markdown" to-path))

;;;###autoload
(defun jsonyter-notebook-export-pdf (to-path)
  "Export this notebook to PDF, writing the result to TO-PATH.
A thin wrapper around `jsonyter-notebook-export' with FORMAT fixed to
\"pdf\"; see its docstring for what this does.  Needs pandoc and a LaTeX
engine on the Jupyter server -- see the README's \"Exporting\" section."
  (interactive (list (jsonyter--export-read-to-path "pdf")))
  (jsonyter-notebook-export "pdf" to-path))

;;;###autoload
(defun jsonyter-notebook-export-latex (to-path)
  "Export this notebook to LaTeX, writing the result to TO-PATH.
A thin wrapper around `jsonyter-notebook-export' with FORMAT fixed to
\"latex\"; see its docstring for what this does."
  (interactive (list (jsonyter--export-read-to-path "latex")))
  (jsonyter-notebook-export "latex" to-path))

;;;###autoload
(defun jsonyter-notebook-export-webpdf (to-path)
  "Export this notebook to PDF via a headless browser, writing the
result to TO-PATH.  A thin wrapper around `jsonyter-notebook-export'
with FORMAT fixed to \"webpdf\"; see its docstring for what this does.
Needs playwright and chromium on the Jupyter server -- see the README's
\"Exporting\" section."
  (interactive (list (jsonyter--export-read-to-path "webpdf")))
  (jsonyter-notebook-export "webpdf" to-path))

;;;###autoload
(defun jsonyter-notebook-export-slides (to-path)
  "Export this notebook to reveal.js slides, writing the result to TO-PATH.
A thin wrapper around `jsonyter-notebook-export' with FORMAT fixed to
\"slides\"; see its docstring for what this does."
  (interactive (list (jsonyter--export-read-to-path "slides")))
  (jsonyter-notebook-export "slides" to-path))

;;;; Script export (`# %%' dividers, for people who do not use notebooks)

;; A local text transformation, not an export through the bridge: nbconvert's
;; `script'/`python' exporters were tried and rejected (see the design notes
;; in TRIAGE-2026-09-12.md §4.10.1) -- `script' drops markdown and cell
;; dividers entirely for every language but Python, and `python' writes
;; `# In[1]:' dividers that `jsonyter-script-cell-regexp' does not match.
;; So this needs no Jupyter server, kernel or bridge at all, and stays that
;; way deliberately: it must keep working offline.
;;
;; Direction is one-way -- notebook/Org -> script -- by decision, not by
;; limitation.  For Python, R and Julia the round trip falls out for free
;; anyway, since `# %%' is exactly what `jsonyter-script-cell-regexp'
;; matches; nothing here is designed around preserving that, and it is not
;; required.  SAS does not get it, on purpose -- see `jsonyter-script-export-languages'.

(defcustom jsonyter-script-export-languages
  '(("python" :extension ".py" :divider "# %%" :comment-line "# ")
    ("r"      :extension ".R"  :divider "# %%" :comment-line "# ")
    ("julia"  :extension ".jl" :divider "# %%" :comment-line "# ")
    ("sas"    :extension ".sas" :divider "* %%;" :comment-block ("/* " . " */")))
  "How `jsonyter-notebook-export-script' and `jsonyter-org-export-script'
render one language's cells as a plain script, in Jupytext's \"percent\"
format.

Keyed by language name, matched case-insensitively against both a
notebook's own lowercase `language_info.name' and Org's own-cased
`#+begin_src LANG'.  Each value is a plist:

  :extension     File extension to default to when prompting, dot included.
  :divider       The `# %%'-style cell-boundary marker, written verbatim
                 before every cell.
  :comment-line  A markdown/raw cell's lines are prefixed with this, one
                 by one, blank lines included.  Mutually exclusive with
                 :comment-block.
  :comment-block A markdown/raw cell is wrapped once in (OPEN . CLOSE)
                 instead of commented line by line.  For a language whose
                 line-comment syntax is unsafe to split prose across --
                 SAS's `* text;' comment statement is terminated by the
                 *first* semicolon, so commenting prose line by line would
                 let any `;' in it (entirely ordinary prose) leak the rest
                 of that line into the script as SAS code.  A literal
                 `*/' inside the prose, which would otherwise close a
                 `/* ... */' block early, is neutralized the same way.

`* %%;' does not match `jsonyter-script-cell-regexp', so a SAS export
does not reopen as cells in `jsonyter-script-mode' -- documented, not a
bug: there is no SAS comment syntax that is simultaneously valid SAS and
a jsonyter cell marker, and a bare `%%' is a macro reference in SAS, so
it cannot be used unquoted either.

A language not in this alist falls back to a notebook buffer's own
`language_info.file_extension' \(Org has no equivalent\), then to a
generic `# %%' / `# ' shape.  A language THIS alist does know never
consults that metadata for its extension: some kernels' own
`file_extension' disagrees with the choice made here on purpose --
IRkernel declares `.r', not the conventional `.R' -- and letting the
metadata win would silently undo that."
  :type '(alist :key-type string
                :value-type (plist :options
                                    ((:extension string)
                                     (:divider string)
                                     (:comment-line string)
                                     (:comment-block (cons string string)))))
  :group 'jsonyter)

(defun jsonyter--script-export-spec (language &optional metadata)
  "The `jsonyter-script-export-languages' entry for LANGUAGE.
Falls back to METADATA's `language_info.file_extension' \(a notebook's
own top-level metadata, see `jsonyter--nb-metadata'\) for a language the
alist does not know, and to a generic `# %%'/`# ' shape after that."
  (or (cdr (assoc-string language jsonyter-script-export-languages t))
      (let ((ext (and metadata
                      (plist-get (plist-get metadata :language_info)
                                 :file_extension))))
        (list :extension (or ext ".txt") :divider "# %%" :comment-line "# "))))

(defun jsonyter--script-export-comment (text spec)
  "Render TEXT -- a markdown or raw cell's source -- as a comment, per SPEC."
  (let ((block (plist-get spec :comment-block)))
    (if block
        ;; Guarding literally against `*/' here, not against the CLOSE
        ;; string in general: that is the one sequence that can close a
        ;; `/* ... */'-style comment early, whatever OPEN and CLOSE
        ;; themselves happen to be spelled as.
        (concat (car block)
                (replace-regexp-in-string "\\*/" "* /" text)
                (cdr block))
      (mapconcat (lambda (line) (concat (plist-get spec :comment-line) line))
                 (split-string text "\n" nil)
                 "\n"))))

(defun jsonyter--cells-to-script (cells spec)
  "Render CELLS -- a list of (:cell_type :source ...) plists, the same
vocabulary `write_notebook' and `export_notebook''s `cells' param take --
as one script string, per SPEC (see `jsonyter-script-export-languages').
Shared by `jsonyter-notebook-export-script' and `jsonyter-org-export-script',
and trivially testable on its own: no buffer, bridge or server involved."
  (mapconcat
   (lambda (cell)
     (let* ((type (plist-get cell :cell_type))
            (source (or (plist-get cell :source) ""))
            (prose-p (member type '("markdown" "raw")))
            (marker (cond ((equal type "markdown") " [markdown]")
                          ((equal type "raw") " [raw]")
                          (t ""))))
       (concat (plist-get spec :divider) marker "\n"
               (if prose-p (jsonyter--script-export-comment source spec) source)
               "\n")))
   cells "\n"))

;;;###autoload
(defun jsonyter-notebook-export-script (file)
  "Export this notebook's cells to FILE as a plain script.

One-way -- see the Commentary above this section.  Needs no Jupyter
server, kernel or bridge: unlike every other `jsonyter-notebook-export-*'
command, this works offline, even against a notebook that has never been
run.

Interactively, defaults FILE to this buffer's own base name with the
language's own extension, from `jsonyter-script-export-languages'."
  (interactive
   (list (let* ((language (or jsonyter--nb-lang "python"))
                (spec (jsonyter--script-export-spec language jsonyter--nb-metadata))
                (default (concat (file-name-sans-extension
                                  (or buffer-file-name "untitled"))
                                 (plist-get spec :extension))))
           (read-file-name "Export script to: " nil default nil
                            (file-name-nondirectory default)))))
  (unless (bound-and-true-p jsonyter-notebook-mode)
    (user-error "jsonyter: not a notebook buffer"))
  (when (and (file-exists-p file) (not (called-interactively-p 'interactive)))
    (user-error "jsonyter: %s already exists" file))
  (when (and (file-exists-p file) (called-interactively-p 'interactive)
             (not (yes-or-no-p (format "%s already exists; overwrite? " file))))
    (user-error "jsonyter: aborted"))
  (let* ((language (or jsonyter--nb-lang "python"))
         (spec (jsonyter--script-export-spec language jsonyter--nb-metadata))
         (cells (jsonyter--nb-collect-cells)))
    (with-temp-file file (insert (jsonyter--cells-to-script cells spec)))
    (message "jsonyter: exported %d cell%s to %s"
             (length cells) (if (= (length cells) 1) "" "s")
             (file-name-nondirectory file))))

;;; Org -> script

(defun jsonyter--org-script-export-cell-from-span (text)
  "One script-export (:cell_type :source [:language]) plist from TEXT.

Like `jsonyter--org-notebook-cell-from-span', but for script export: no
output parsing (a script carries no outputs at all -- see
`jsonyter-org-export-script') and, deliberately, no Markdown conversion.
The prose is going into a comment verbatim either way, so converting it
through `jsonyter--org-markdown-convert' buys nothing and costs a hard
pandoc dependency for nothing -- worse, with no pandoc installed and no
`jsonyter-org-markdown-converter' set, that function inserts a banner
into the content itself, which would land in the exported script as if
it were the user's own prose."
  (let ((trimmed (string-trim text)))
    (if (string-match-p "\\`#\\+begin_src" trimmed)
        (with-temp-buffer
          (delay-mode-hooks (org-mode))
          (insert trimmed)
          (goto-char (point-min))
          (let ((info (org-babel-get-src-block-info 'light)))
            (list :cell_type "code" :language (and info (nth 0 info))
                  :source (string-trim (or (and info (nth 1 info)) "")))))
      (list :cell_type "markdown" :source trimmed))))

(defun jsonyter--org-to-script-cells ()
  "This buffer's cells for script export.
Splits the same way `jsonyter--org-to-notebook-cells' does -- see
`jsonyter--org-notebook-cell-spans' -- so a hand-authored file with no
`:JSONYTER_CELL_ID:' drawers works exactly as well as one that
round-tripped through `jsonyter-org-from-notebook'."
  (mapcar (lambda (span) (jsonyter--org-script-export-cell-from-span (cdr span)))
          (jsonyter--org-notebook-cell-spans)))

;;;###autoload
(defun jsonyter-org-export-script (file)
  "Export this Org buffer's `jy:' blocks to FILE as a plain script.

The prose between blocks becomes commented markdown -- see the
Commentary above this section for the whole feature, and
`jsonyter-script-export-languages' for how a cell's language decides
comment style and divider.  One-way, and needs no Jupyter server, kernel
or bridge at all: like `jsonyter-notebook-export-script', this is a
local text transformation.

The script's language is the first `jy:' code block's own language; a
buffer whose blocks mix languages is not a coherent single script and is
not specially handled.  A buffer with no `jy:' blocks at all exports as
Python.

Interactively, defaults FILE to this buffer's own base name with the
language's own extension."
  (interactive
   (progn
     (unless (derived-mode-p 'org-mode) (user-error "jsonyter: not an Org buffer"))
     (require 'ob-core)
     (let* ((cells (jsonyter--org-to-script-cells))
            (language (or (seq-some (lambda (c) (plist-get c :language)) cells)
                         "python"))
            (spec (jsonyter--script-export-spec language))
            (default (concat (file-name-sans-extension
                              (or buffer-file-name "untitled"))
                             (plist-get spec :extension))))
       (list (read-file-name "Export script to: " nil default nil
                             (file-name-nondirectory default))))))
  (unless (derived-mode-p 'org-mode)
    (user-error "jsonyter: not an Org buffer"))
  (require 'ob-core)
  (let* ((cells (jsonyter--org-to-script-cells))
         (language (or (seq-some (lambda (c) (plist-get c :language)) cells)
                       "python"))
         (spec (jsonyter--script-export-spec language)))
    (when (and (file-exists-p file) (not (called-interactively-p 'interactive)))
      (user-error "jsonyter: %s already exists" file))
    (when (and (file-exists-p file) (called-interactively-p 'interactive)
               (not (yes-or-no-p (format "%s already exists; overwrite? " file))))
      (user-error "jsonyter: aborted"))
    (with-temp-file file (insert (jsonyter--cells-to-script cells spec)))
    (message "jsonyter: exported %d cell%s to %s"
             (length cells) (if (= (length cells) 1) "" "s")
             (file-name-nondirectory file))))

(provide 'jsonyter-export)
;;; jsonyter-export.el ends here
