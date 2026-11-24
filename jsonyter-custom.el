;;; jsonyter-custom.el --- User options and faces -*- lexical-binding: t; -*-

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

;; User options and faces.  One part of jsonyter.el, which loads
;; every part; see jsonyter.el for the overview and the entry points.

;;; Code:
(require 'cl-lib)
(require 'subr-x)

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

(defcustom jsonyter-export-timeout 120
  "Default seconds `export_notebook' is allowed before giving up.
Matches the bridge's own built-in default: a PDF or webpdf render is
seconds-to-minutes, not the interactive latency the other timeouts
bound.  Sent as the request's own `timeout' param -- deliberately *not*
a bridge command-line flag: `--export-timeout' only exists on jsonyter
>= 2.0.0, and passing it unconditionally at startup would refuse to
launch any older bridge outright, breaking every command, not only
export.  `jsonyter-notebook-export' and `jsonyter-remote-dired-export'
both accept their own one-off TIMEOUT to override this per call."
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

(defcustom jsonyter-notebook-output-width 80
  "Column width of the frame around a notebook (or script) cell's output.

The rules above and below the output block are drawn this many columns
wide, and an image in that output is scaled so it is no wider than this
many columns either — so a wide figure lines up with the frame rather
than running past it.  A REPL keeps `jsonyter-image-max-width' instead.

The image cap is a ceiling: a smaller `jsonyter-image-max-width', or a
`jsonyter-image-max-height' that bites first, still wins."
  :type 'integer)

(defcustom jsonyter-notebook-line-numbers 'cell
  "How a notebook shows line numbers when `display-line-numbers-mode' is on.

`cell' numbers every line of every cell's source from 1 within its own
cell, on the row that shows the line, and turns Emacs's own numbers off
in the buffer.  Emacs numbers the rows of the rendered view instead: the
number of a cell's first line lands on the blank row above its prompt,
and the rows of every output and image are counted too.

`buffer' leaves Emacs's own numbering alone.

Per-cell numbers replace absolute numbering only; `relative' and
`visual' numbering are left to Emacs.  The option is read whenever line
numbers are switched on, so after changing it, toggle
`display-line-numbers-mode' off and on in an open notebook to apply it."
  :type '(choice (const :tag "Per cell" cell)
                 (const :tag "Emacs's own (rows of the buffer)" buffer)))

(defcustom jsonyter-notebook-latex-macros nil
  "LaTeX macro definitions to seed a notebook's math with.

A list of strings, each one line — typically a \\newcommand or
\\DeclareMathOperator.  `jsonyter-notebook-new' adds them to a new
notebook, and \\[jsonyter-notebook-insert-latex-macros] adds or
refreshes them in the notebook at point: they go in a markdown cell at
the top, marked so it is updated rather than duplicated, where MathJax
\(in Jupyter and nbconvert) reads the \\newcommands and makes them
available to every later cell's math.  nil means add nothing.

Example:

  (setq jsonyter-notebook-latex-macros
        \\='(\"\\\\newcommand{\\\\R}{\\\\mathbb{R}}\"
          \"\\\\newcommand{\\\\abs}[1]{\\\\left|#1\\\\right|}\"))"
  :type '(repeat string))

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

(defcustom jsonyter-upload-chunk-size (* 8 1024 1024)
  "Raw bytes per chunk of an upload, passed through to the bridge.
8 MiB by default.  The request body is roughly 4/3 of this once base64
encoded, and a gateway such as Cloudflare caps the body at 100 MB by
default, so values above ~74 MB fail with a proxy 413.  Raise it only
where the deployment allows a larger body; lower it (and then
\\[jsonyter-resume-upload]) when a proxy rejects the current size."
  :type 'integer)

(defcustom jsonyter-remote-root nil
  "The server's `root_dir' as an absolute path, or an alist keyed by server URL.
Only consulted when the sentinel probe cannot resolve the kernel's
working directory to a Contents-API path — the manual override for a
kernel running outside `root_dir'.  nil means \"probe only\": with no
probe result and no override, transfer commands simply have no default
remote directory."
  :type '(choice (const :tag "Probe only" nil)
                 (directory :tag "Single absolute root")
                 (alist :key-type (string :tag "Server URL")
                        :value-type (directory :tag "Absolute root"))))

(defcustom jsonyter-download-directory nil
  "Default local destination for `jsonyter-download-file'.
nil means the `default-directory' of the buffer the command was invoked
from."
  :type '(choice (const :tag "Invoking buffer's directory" nil) directory))

(defcustom jsonyter-remote-confirm-delete t
  "Whether `jsonyter-remote-dired' asks before deleting marked entries.
Set to nil once you trust yourself with `x'; the mark step (`d') still
stands between you and a deletion either way."
  :type 'boolean)

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

(provide 'jsonyter-custom)
;;; jsonyter-custom.el ends here
