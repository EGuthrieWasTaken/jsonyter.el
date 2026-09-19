# jsonyter.el

Jupyter, natively in Emacs — REPLs, rendered `.ipynb` notebooks, `# %%`
script cells, and `#+begin_src` blocks in Org files, all against Python,
Julia, R or SAS kernels on a local or remote server, backed by the
[jsonyter](https://github.com/EGuthrieWasTaken/jsonyter) Python package's
JSON-over-stdio bridge. Streaming output, inline images, kernel-backed
completion and documentation lookup, `input()` support, and — for
notebooks — lossless byte-identical saves that never touch stored outputs
unless you ask.

Since 2.0, a single buffer can drive **several kernels at once** — a
table of sessions keyed by `(language, name)` — which is what makes one
Org file with Python, R and SAS blocks work. Since 2.1, a `jy:` block
also runs through standard Org Babel: `C-c C-c`, export and
`org-babel-tangle` all work on it, on the same kernel `C-RET` uses. Since
2.3, a notebook or Org buffer's `jy:` cells export to HTML/PDF/Markdown/...
through the bridge (`jsonyter-notebook-export`), or to a plain
`.py`/`.R`/`.jl`/`.sas` script with no server involved at all
(`jsonyter-notebook-export-script`, `jsonyter-org-export-script`).

> **A note on how this was built.** The bulk of jsonyter.el was written by
> Claude Fable 5, an Anthropic AI model, working iteratively with the
> project's maintainer over the course of development — design decisions,
> requirements and review were mine; the code, and much of the
> exploratory verification behind it, were largely the model's.

## Requirements

- Emacs 27.1+ (images need a graphical Emacs built with image support)
- Org 9.4+ (bundled with Emacs 27.1+); only loaded when `jsonyter-org-mode` is used, or Org Babel itself is
- The [jsonyter](https://github.com/EGuthrieWasTaken/jsonyter) Python
  package, 2.0.0 or newer — plain `pip install` always grabs the latest
  release, which is what this project's own CI tests against:
  ```bash
  pip install jsonyter
  ```
- A reachable Jupyter server: `pip install jupyter-server ipykernel` and
  `jupyter server --ServerApp.token=SECRET`, local or remote

## Setup

### Install from a release (recommended)

Each release is a Git tag `vX.Y.Z`. Pinning to one keeps an upstream
change from breaking your setup between updates.

**Manual:** grab the single file at the tag and put it on your
`load-path`:

```bash
curl -O https://raw.githubusercontent.com/EGuthrieWasTaken/jsonyter.el/v2.4.1/jsonyter.el
```

```elisp
(add-to-list 'load-path "/path/to/jsonyter")  ; the directory holding jsonyter.el
(require 'jsonyter)  ; or autoload the jsonyter-start-* commands
```

**`package-vc-install`** (built into Emacs 29+, no third-party manager):

```elisp
(package-vc-install
 '(jsonyter :url "https://github.com/EGuthrieWasTaken/jsonyter.el" :rev "v2.4.1"))
```

**[elpaca](https://github.com/progfolio/elpaca):** pin the recipe to the
tag with `:ref`:

```elisp
(use-package jsonyter
  :ensure (:host github :repo "EGuthrieWasTaken/jsonyter.el" :ref "v2.4.1"))
```

**[straight.el](https://github.com/radian-software/straight.el):** install
the recipe below, then lock it to the checked-out revision with
`M-x straight-freeze-versions`, which records it in your lockfile:

```elisp
(straight-use-package
 '(jsonyter :type git :host github :repo "EGuthrieWasTaken/jsonyter.el"))
```

**package.el, once on MELPA:** the package will build from release tags on
[MELPA Stable](https://stable.melpa.org):

```elisp
(use-package jsonyter
  :ensure t
  :pin melpa-stable)
```

### Bleeding edge (from the repo)

Cloning the repository — or tracking it through a package manager without
pinning a tag — installs whatever is on `main`. That is where unreleased
work lands: it may be unstable, may change from commit to commit, and may
break in ways a release won't. Use it only if you want the newest
features or are helping test them.

**straight.el:**

```elisp
(straight-use-package
 '(jsonyter :type git :host github :repo "EGuthrieWasTaken/jsonyter.el"))
```

**elpaca:**

```elisp
(use-package jsonyter
  :ensure (:host github :repo "EGuthrieWasTaken/jsonyter.el"))
```

**Manual:**

```elisp
(add-to-list 'load-path "/path/to/jsonyter.el")  ; your clone
(require 'jsonyter)  ; or autoload the jsonyter-start-* commands
```

Whichever you use, if the `jsonyter` console script isn't on Emacs's
`exec-path` — a `pip install --user` puts it somewhere `pip` doesn't add
to `PATH` on every system — point `jsonyter-command` at the module
instead of the script:

```elisp
(setq jsonyter-command '("python3" "-m" "jsonyter"))
```

## Configuration

The default server is `http://localhost:8888`. For a remote and/or
token-authenticated server, set (e.g. in your `init.el`/`config.el`):

```elisp
(setq jsonyter-server-url "https://jupyter.example.com:8888")

;; Recommended: token in a file. A .gpg file is decrypted transparently by
;; EasyPG, so the token is never stored in plain text.
(setq jsonyter-server-token-file "~/.authinfo.d/jupyter-token.gpg")

;; Or any function returning the token, e.g. via auth-source
(setq jsonyter-server-token
      (lambda ()
        (auth-source-pick-first-password :host "jupyter.example.com")))

;; Or a literal string (discouraged — plain text in your config)
(setq jsonyter-server-token "SECRET")
```

To create the encrypted token file:

```bash
echo -n 'SECRET' | gpg --encrypt --recipient you@example.com -o ~/.authinfo.d/jupyter-token.gpg
```

If neither variable is set, the bridge falls back to a `JUPYTER_TOKEN`
environment variable that Emacs inherited, so an unauthenticated local
server needs no configuration at all.

### How the token reaches the bridge

`jsonyter-token-transport` controls this. The default keeps the secret off
the command line, where `ps` would expose it to every local user:

| Value | Mechanism |
| --- | --- |
| `env` (default) | `JUPYTER_TOKEN` in the subprocess environment |
| `stdin` | `--token-file -`, token written as the bridge's first stdin line |
| `file` | `--token-file PATH`; Python reads it, so the token never enters Emacs. Plaintext files only — it cannot decrypt `.gpg` |
| `argv` | `--token SECRET`. **Insecure**, for old bridges only |

### Other options

| Variable | Default | Purpose |
| --- | --- | --- |
| `jsonyter-kernel-names` | `nil` | Pin a language to an exact kernelspec name, e.g. `'(("python" . "python3"))`. Otherwise the spec is auto-detected from the server by language. |
| `jsonyter-stream-output` | `t` | Render output as the kernel produces it. |
| `jsonyter-subscribe-events` | `t` | Subscribe to kernel state events for the mode-line indicator. |
| `jsonyter-use-is-complete` | `t` | Ask the kernel whether input is complete before sending on RET. |
| `jsonyter-exec-timeout` | `nil` | Kernel-silence timeout passed to the bridge; `nil` waits indefinitely (right for SAS's slow startup). |
| `jsonyter-image-max-width` | `800` | Max pixel width for inline images (a REPL; in a notebook or script cell `jsonyter-notebook-output-width` also applies). |
| `jsonyter-image-max-height` | `nil` | Max pixel height for inline images. |
| `jsonyter-notebook-output-width` | `80` | Columns wide the rules framing a notebook/script cell's output are drawn, and the column ceiling an image in that output is scaled to line up with them. |
| `jsonyter-slice-images` | `t` | Slice tall images one line per row so they scroll (REPL and notebook buffers). |
| `jsonyter-suppress-line-spacing` | `t` | Drop `line-spacing` in REPL and notebook buffers, where its leading would band a sliced image. |
| `jsonyter-render-html` | `t` | Render `text/html` output with shr. |
| `jsonyter-insecure-tls` | `nil` | Skip TLS verification (self-signed remote servers). |
| `jsonyter-shutdown-on-kill` | `t` | Shut the kernel down when the REPL buffer is killed. |
| `jsonyter-upload-chunk-size` | `8 MiB` | Raw bytes per upload chunk. The request body is ~4/3 of this, and a proxy such as Cloudflare caps it at 100 MB, so values above ~74 MB fail with a 413 — [see below](#transferring-files). |
| `jsonyter-remote-root` | `nil` | The server's `root_dir` as an absolute path (or an alist keyed by server URL), for the case where the working-directory probe cannot place a kernel that runs outside `root_dir`. |
| `jsonyter-download-directory` | `nil` | Default local destination for `jsonyter-download-file`; `nil` means the invoking buffer's directory. |
| `jsonyter-remote-confirm-delete` | `t` | Whether `jsonyter-remote-dired` asks before deleting marked entries. |

## Usage

Start a REPL with one of:

- `M-x jsonyter-start-python`
- `M-x jsonyter-start-julia`
- `M-x jsonyter-start-R`
- `M-x jsonyter-start-SAS`
- `M-x jsonyter-start` — prompts for any language the server has a kernel for

Keys in the REPL buffer:

| Key | Action |
| --- | --- |
| `RET` | Send input; if the kernel reports it incomplete (`is_complete`), continue on an indented new line instead |
| `M-RET` / `C-RET` | Force-send even if incomplete |
| `C-j` | Literal newline |
| `TAB` | Kernel-backed `completion-at-point` |
| `M-p` / `M-n` | Input history |
| `C-c C-c` | Interrupt the kernel |
| `C-c C-r` | Restart the kernel, same id, all state lost (`jsonyter-restart`, aka `jsonyter-kernel-restart`) |
| `C-c C-q` | Shut the kernel down |
| `C-c C-l` | Reconnect to this buffer's kernel after a dropped connection |
| `C-c C-j` | Attach this buffer to any kernel running on the server |
| `C-c M-h` | Show the kernel's most recent commands |
| `C-c C-d` | Documentation for the thing at point (`inspect`) |
| `C-c C-k` | Unstick a REPL stuck at "kernel is busy" — Emacs-side only, the kernel keeps running (`jsonyter-unstick`) |
| `C-c M-o` | Clear output above the prompt |

`C-c C-r` and `C-c C-k` are easy to conflate: `C-c C-r` replaces the
kernel process outright — same id, but every variable is gone — while
`C-c C-k` touches nothing on the kernel side at all, only Emacs's own
"a request is in flight" bookkeeping, for the case where that bookkeeping
itself got stuck. Reach for `C-c C-k` first if the kernel might still be
genuinely working; interrupt it with `C-c C-c` if it is not.

Code that calls `input()` prompts in the minibuffer (passwords use
`read-passwd`).

## Output

Output streams in as the kernel produces it, so a long-running cell shows
its `print` output live rather than in one dump at the end. Each output is
rendered with the richest representation Emacs can display: `image/png` and
`image/jpeg` mimebundles are base64-decoded and inserted as inline images
(scaled to `jsonyter-image-max-width`), `image/svg+xml` renders when Emacs
has SVG support, `text/html` renders through shr, and everything else falls
back to ANSI-colorized `text/plain`. Tracebacks and streams render their
ANSI escape codes; stderr is shown in an error face.

`clear_output` is honored, including `wait=True`, so progress bars and
animations redraw in place instead of accumulating frames.

Insertion never steals point: a window scrolls with new output only if it
was already at the end, so you can read back through the buffer while a
cell is still running.

In notebook and `# %%` script buffers, each output block is **framed**
above and below by a labelled rule `jsonyter-notebook-output-width`
columns wide (80 by default), so where a cell's code ends and its
results begin stays clear however long the output runs — and an image in
that output is scaled to fit the same width, so a wide figure lines up
with the frame rather than running past it. A cell with no output has no
frame at all. Edit a cell's source after it has run and its frame
changes face and reads `output (stale)`, flagging results that may no
longer match the code in front of you; re-running the cell clears it,
and so does undoing back to the source that produced the output. The
check is a hash of that one cell's source per edit, so it costs nothing
even on cells with very large outputs.

Images taller than one text line are inserted **sliced**, one slice per
line, so ordinary line scrolling walks through a tall plot like normal
text instead of stepping over it in a single jump. This works in REPL
buffers and in notebooks, whose cell output is buffer text of its own.
It cannot in a `# %%` script buffer: that buffer's text is exactly the
file you save, so its output has to live in an overlay string, and an
overlay string is one buffer position however many lines it draws —
there is nothing there for scrolling to stop at. Script cells show tall
images whole, and Emacs scrolls those by pixel. Set
`jsonyter-slice-images` to nil to opt out everywhere, or
`jsonyter-image-max-height` to shrink tall plots to fit instead.

Slices tile only where each buffer line is exactly as tall as the slice
on it, so a buffer showing them goes without `line-spacing`. Emacs draws
that leading below a line holding an image slice just as readily as
below a line of text, which turns a plot into strips of picture
separated by bars of background — and nothing the text carries can
prevent it, because the leading comes from the buffer rather than from
the text. So `jsonyter-suppress-line-spacing` sets `line-spacing` to 0
in REPL and notebook buffers, and only in those: the value is
buffer-local, and every other buffer keeps the leading you configured.
Set it to nil to keep yours here too, and images are inserted whole
rather than banded, at the cost of scrolling through them a line at a
time.

The other thing that can sit on a slice's row is a glyph drawn with the
buffer's own font — `display-line-numbers-mode` puts one on every row —
and a row holding both is as tall as the font's ascent plus whatever
the slice hangs below the baseline. Slices are therefore anchored with
`:ascent center`, which for a slice exactly one line tall puts its
baseline where the font's is, so line numbers cost the row nothing and
the picture tiles either way.

### Faces

Everything jsonyter draws is themable rather than hardcoded — customize
any of these:

| Face | What it colors |
| --- | --- |
| `jsonyter-prompt-face` | REPL input prompts |
| `jsonyter-output-prompt-face` | `Out[n]:` result prompts |
| `jsonyter-stderr-face` | stderr stream output |
| `jsonyter-note-face` | jsonyter's own informational notes |
| `jsonyter-code-cell-face` | the boundary label of a code cell |
| `jsonyter-markdown-cell-face` | the boundary label of a markdown cell |
| `jsonyter-raw-cell-face` | the boundary label of a raw cell |
| `jsonyter-notebook-rule-face` | the rule drawn beside a cell boundary |
| `jsonyter-output-border-face` | the frame around an output block |
| `jsonyter-output-border-stale-face` | that frame when the cell's source has been edited since the output was produced |

```elisp
(custom-set-faces
 '(jsonyter-markdown-cell-face ((t :inherit font-lock-comment-face :slant italic)))
 '(jsonyter-output-border-stale-face ((t :foreground "orange3"))))
```

## Kernel state

The mode line reports the kernel's real state, pushed from the bridge's
event subscription rather than polled:

| Indicator | Meaning |
| --- | --- |
| `:idle` | ready |
| `:run` | running your cell |
| `:run[ext]` | busy on behalf of another client attached to the same kernel |
| `:starting` / `:restarting` | coming up |
| `:offline` | the bridge's websocket dropped — `C-c C-l` to reconnect |
| `:dead` | the kernel is gone — `C-c C-r` to restart |

A kernel killed out from under the REPL (say, shut down from a notebook UI)
reports itself as dead in the buffer instead of hanging the next execute.

Each tag also carries the kernel's short id, e.g. `:idle[3f8a9c21]` — the
first 8 characters, enough to tell kernels apart, and useful for noticing
that a session silently started a *new* kernel instead of reusing the
one you expected. Set `jsonyter-mode-line-show-kernel-id` to `nil` to
turn it off on a narrow frame; the full id is always available from
`jsonyter-current-kernel-id` regardless.

## Reconnecting after a dropped connection

Against a remote server, a laptop that sleeps or loses its network leaves
the bridge's websocket to the kernel half-open: the socket still reports
itself connected, so nothing reconnects on its own, and the buffer waits
on a reply that can never arrive. `C-c C-l` (`jsonyter-kernel-reconnect`)
is the way out — it closes the dead socket and opens a fresh one to the
same kernel.

The kernel itself is unaffected — it keeps running on the server with all
of its state — so reconnecting costs nothing but output that was in
flight. This is not `C-c C-r`, which restarts the kernel and discards
that state.

`C-c C-j` (`jsonyter-kernel-connect`) is the same operation aimed
anywhere: it lists the kernels the server is running — most recently
active first, with this buffer's own marked `*` — and attaches the buffer
to the one you pick. Both work in any jsonyter buffer: a REPL, a rendered
notebook, a script with `jsonyter-script-mode` on, or the session at
point in a `jsonyter-org-mode` buffer. Two uses beyond recovery:

- Point a script's `# %%` cells at the kernel a notebook already has
  warm, so both see the same variables.
- Adopt a kernel started by JupyterLab or another editor.

A buffer shuts down only the kernel it started itself, whether or not
that is the one it is attached to when it is killed. A kernel you attach
to is never shut down for you, whatever `jsonyter-shutdown-on-kill` says.

A REPL gets a fresh prompt on reconnect, since anything still outstanding
is abandoned. Its number can lag what the kernel is really counting —
the kernel kept working while you were away — and resyncs on the next
execution.

### Seeing what a kernel has run

`C-c M-h` (`jsonyter-kernel-history`) lists a kernel's most recent
commands in a help buffer — how to recover what a REPL ran when you have
lost the transcript, or to work out what a kernel is being used for
before adopting it. It defaults to `jsonyter-kernel-history-count`
commands and this buffer's own kernel; a numeric prefix sets the count
(`C-u 100 C-c M-h`), and a bare `C-u` prompts for both, which is how to
read the history of a kernel you are not attached to.

How far back this reaches, and whose commands come back, is up to the
kernel. IPython's history is one SQLite database per profile, shared by
every kernel using it, so a tail can include commands run by a
*different* kernel — a brand-new kernel that has executed nothing still
answers with the last things its neighbours ran. Entries are grouped and
labelled by session for that reason. Not every kernel implements history
at all (SAS never answers), so this can time out where a REPL against the
same kernel works fine.

## Notebooks (.ipynb)

Register the opener and `.ipynb` files render as notebooks instead of raw
JSON:

```elisp
(add-to-list 'auto-mode-alist '("\\.ipynb\\'" . jsonyter-notebook-open))
```

`M-x jsonyter-notebook-new` writes a fresh nbformat 4.5 notebook — one
empty code cell, a kernelspec for the language you name — and opens it
rendered. No kernel starts and the server is not contacted until the
first run.

Cell source is ordinary buffer text, edited in the notebook language's own
major mode — `python-mode`, `ess-r-mode`, and so on, per
`jsonyter-notebook-language-modes` — so syntax highlighting, indentation
and completion are the language's own. Cell prompts and cell boundaries
live in **overlays**; a cell's **output is buffer text**, written in
after its source, which is what lets point move through it — and so lets
a plot taller than the window be scrolled through a line at a time
rather than jumped over.

Output being text does not make it part of the document. It is
`read-only`, so no stray edit can corrupt it (selecting and copying it
are unaffected); it is written without touching the undo history or the
buffer's modified flag, so undo still walks your edits and never your
results; the language's own font-lock is kept off it, so a traceback is
never recoloured as code; and saving reads only the source side of each
cell, so what reaches the `.ipynb` file is the code you typed and
nothing else.

Every cell opens with a boundary line naming its type — `code` (with the
notebook's kernel language), `Markdown` or `Raw` — so where one cell ends
and the next begins, and what kind of cell you are looking at, is visible
at a glance even where cells sit back to back. Boundaries follow inserts,
deletes, moves and type toggles on their own; there is nothing to
refresh.

| Key | Action |
| --- | --- |
| `C-RET` | Run the cell at point |
| `S-RET` | Run the cell and advance to the next |
| `C-c C-b` | Run every code cell in order |
| `C-c C-n` / `C-c C-p` | Next / previous cell |
| `C-c C-c` | Interrupt the kernel |
| `C-c C-r` | Restart the kernel, same id, all state lost (`jsonyter-restart`, aka `jsonyter-kernel-restart`) |
| `C-c C-l` | Reconnect to this buffer's kernel after a dropped connection |
| `C-c C-j` | Attach this buffer to any kernel running on the server |
| `C-c M-h` | Show the kernel's most recent commands |
| `C-c M-o` / `C-c M-O` | Clear this cell's output / all output |
| `C-c C-k` | Start the kernel explicitly |
| `C-c C-i` / `C-c C-a` | Insert a cell below / above (`C-u` for markdown) |
| `C-c C-w` | Delete the cell at point |
| `C-c C-t` | Toggle the cell between code and markdown |
| `C-c <up>` / `C-c <down>` | Move the cell up / down |
| `C-x C-s` | Save cell source |
| `C-c C-s` | Save cell source and this session's new outputs |
| `C-c C-x` | Export to HTML, PDF, ... (`jsonyter-notebook-export`) |

The cell-editing commands are autoloaded under stable public names, so you
can bind them in your own keymap instead of relying on the defaults above:

| Command | Default key |
| --- | --- |
| `jsonyter-insert-cell-below` | `C-c C-i` |
| `jsonyter-insert-cell-above` | `C-c C-a` |
| `jsonyter-delete-cell` | `C-c C-w` |
| `jsonyter-toggle-cell-type` | `C-c C-t` |
| `jsonyter-move-cell-up` | `C-c <up>` |
| `jsonyter-move-cell-down` | `C-c <down>` |

Both insert commands take a prefix argument to insert a markdown cell. All
six require a notebook buffer and signal an error elsewhere, so they are
safe to bind globally:

```elisp
(use-package jsonyter
  :bind (("C-c n i" . jsonyter-insert-cell-below)
         ("C-c n a" . jsonyter-insert-cell-above)
         ("C-c n w" . jsonyter-delete-cell)))
```

These were named `jsonyter-notebook-insert-cell-below` and so on through
1.0.0. The old names still work as obsolete aliases.

`M-x jsonyter-clear` clears every output in the buffer and blanks the
execution counts, leaving the notebook as though nothing had been run. It
does the equivalent thing in a REPL or script buffer too.

### LaTeX macros

Set `jsonyter-notebook-latex-macros` to a list of `\newcommand` lines and
`M-x jsonyter-notebook-insert-latex-macros` puts them in a markdown cell
at the top of the notebook — inside `$$…$$`, behind a sentinel HTML
comment so re-running it replaces that cell rather than adding another.
MathJax, in Jupyter and in `nbconvert`, reads the `\newcommand`s and
applies them to every later cell's math. `jsonyter-notebook-new` seeds
the cell automatically when the option is set.

```elisp
(setq jsonyter-notebook-latex-macros
      '("\\newcommand{\\R}{\\mathbb{R}}"
        "\\newcommand{\\abs}[1]{\\left|#1\\right|}"))
```

Outputs stored in the file are rendered when it opens, including figures.
Running a cell **replaces** its output rather than appending, and results
are session-only — they are never written back to the file.

The kernel comes from the notebook's own `kernelspec` metadata and starts
lazily on the first execution, so opening a notebook to read it costs
nothing.

### Saving

`C-x C-s` writes cell source back through the jsonyter Python package's
`write_notebook`, which merges it onto the file's own cells by id. Stored
outputs, cell metadata, attachments and Jupyter's exact JSON formatting
are preserved, so an unedited save is **byte-identical** and a one-line
edit is a one-line diff rather than a whole-file rewrite.

`C-x C-s` (`jsonyter-notebook-save-buffer`) saves **source only** — cell
text, order and type. Execution results are session-only by default, so
re-running a cell to produce a new figure and then `C-x C-s` leaves that
figure out of the file. Running a cell changes no buffer text, so Emacs
would otherwise consider the buffer unmodified and return silently; this
says what it did instead.

`C-c C-s` (`jsonyter-notebook-save-with-outputs`) saves source **and**
this session's new outputs. A cell run, or explicitly cleared (`C-c M-o`
/ `C-c M-O`), since the notebook was opened has its stored output
replaced by what is currently shown; every other cell's stored output —
anything not touched this session — is left exactly as it was. That
means the diff is proportional to what you actually reran, not the whole
file: rerun one cell and only that cell's output changes on disk.

If the file changed on disk since it was opened, either save is refused
rather than clobbering the other change; revert to reload.

> **Note for notebooks saved before 1.2.0.** Through 1.1.0, inserting a
> cell prepended a blank line to the following cell's source, and saving
> wrote that blank line to the file. 1.2.0 fixes the insert path, but it
> cannot retroactively clean cells already saved that way: a notebook
> that picked up stray leading blank lines keeps them until you delete
> them by hand. They are harmless for plain Python, but they shift the
> line numbers a kernel reports in a traceback, and they break anything
> that has to be a cell's first line — `%%cell` magics, `#!` lines, and
> some non-Python kernels.

Saving is a local filesystem operation and does not need a kernel or a
reachable Jupyter server — a notebook opened purely to read can still be
edited and saved offline.

## Transferring files

Code and notebook source move through the bridge in both directions;
data files did not, until now. `jsonyter-upload-file` and
`jsonyter-download-file` copy a single file either way, asynchronously,
with a progress indicator; `jsonyter-remote-dired` browses the server's
filesystem with the usual file-management verbs; and, once you opt in
with `jsonyter-dired-setup`, `C-c C-u` in a local `dired` buffer sends
the marked files (or the file at point) to the server.

The chunking, hashing and file I/O all happen in the jsonyter Python
package — Emacs never holds a multi-hundred-megabyte string, only the
progress counters cross the pipe.

### Contents paths are not kernel paths

**A remote path here is a Contents-API path**: POSIX-style, relative to
the server's `root_dir`, with no leading slash — `data/trials.csv`, not
`/home/jovyan/work/data/trials.csv`. The kernel's working directory is a
different coordinate system, and the two are never silently
interchanged. Every prompt says `Remote (contents) path:` so there is no
doubt which one it wants.

To make an "upload here" default sensible, the first transfer command in
a session runs a one-off probe (`kernel_contents_dir`) that maps the
kernel's cwd to a Contents-API path. When the kernel runs outside
`root_dir` the probe returns nothing rather than a guess, and there is
simply no default until you set `jsonyter-remote-root`. The mapping is
dropped on a kernel restart, since a restarted kernel may have moved.

### `jsonyter-remote-dired`

A `tabulated-list` buffer, one per session, over `list_contents`.
Directories sort first and carry a trailing `/`; a non-writable entry is
shown dimmed rather than left to fail at the point of use.

| Key | Action |
| --- | --- |
| `RET` | Descend into a directory; on a file, download it |
| `^` | Up one directory |
| `g` | Refresh |
| `U` | Upload a local file into this directory |
| `D` | Download the file at point |
| `R` | Rename / move (`rename_contents`) |
| `C` | Copy on the server (`copy_contents`) — the server picks the name (`-Copy1`, …) and the report shows the name it chose |
| `+` | Create a directory (`make_directory`) |
| `d` / `u` / `x` | Mark for deletion / unmark / delete the marked entries (confirmed per `jsonyter-remote-confirm-delete`) |
| `q` | Bury the buffer |

### Progress, errors, and resuming

A running transfer shows `Uploading trials.csv… 24.0 MB / 184.3 MB
(13%)` in the echo area and a `:up 13%` / `:down 13%` tag in the mode
line of the REPL the session belongs to, so a transfer started from a
`dired` buffer is still visible from where it runs. On completion:

```
trials.csv → data/trials.csv (184.3 MB, sha256 verified, 41s)
```

`sha256 verified` becomes `size verified only` against a server older
than jupyter_server 2.11, and `unverified` when the integrity check
itself times out.

Errors name the recovery. An existing destination says to pass a prefix
argument to overwrite; a file that changed on the server offers
`jsonyter-download-file` first and shows both digests abbreviated. When
a proxy — not the Jupyter server — rejects the request body with a 413,
the message names **`jsonyter-upload-chunk-size`** and its current
value: that is the knob to lower behind a gateway with a body-size
limit. After any failure, `jsonyter-resume-upload` /
`jsonyter-resume-download` re-issue the last transfer from where it
stopped.

## Syncing directories

`jsonyter-upload-file`, `jsonyter-download-file` and `jsonyter-remote-dired`
cover the deliberate, one-file-at-a-time case; `jsonyter-sync` covers the
standing relationship instead — **a local directory and a remote one
that are supposed to hold the same thing.** One command makes them
agree, moving only what actually differs and never silently discarding
an edit.

This is **on-demand, not continuous**: there is no watching, no daemon,
no polling loop. Every sync is a discrete command with a beginning and
an end; run `jsonyter-sync` again whenever you want the two sides to
converge again.

The idea worth holding on to: **a baseline is what makes a bidirectional
sync safe.** Comparing local and remote alone can only say "these
differ" — it takes a record of what the two last agreed on to say *who*
changed, which is what tells a routine one-sided update apart from a
genuine conflict, and a deletion apart from a file that was never
created. The bridge keeps this baseline (one small JSON file per pair,
under `$XDG_STATE_HOME/jsonyter/sync/` by default) and it is disposable
by design: `jsonyter-sync-reset-baseline` discards it, and the next sync
just starts fresh, as a first sync would.

### Pairs

A *pair* is a local directory and a remote (Contents-API) directory kept
in agreement:

```elisp
(setq jsonyter-sync-pairs
      '(("~/project/data" . "work/data")
        (:local "~/project/results" :remote "work/results"
         :server "https://jupyter.example.org"
         :conflict newest :delete push :ignore ("*.log"))))
```

The short `(LOCAL . REMOTE)` form covers the common case; the plist form
pins a pair to one server and overrides the conflict/delete policy and
ignore patterns for that pair alone. `:server` defaults to nil (any
server); `:local` is expanded with `expand-file-name`; `:remote` is a
Contents-API path — POSIX, relative to the server's `root_dir`, no
leading slash, under the same rule as everywhere else transfer touches
(see [Contents paths are not kernel
paths](#contents-paths-are-not-kernel-paths)).

You rarely need to write `jsonyter-sync-pairs` by hand: with no pair
configured for the directory you're in, `jsonyter-sync` offers to create
one on the spot, seeded from the current directory and the same
kernel-cwd probe transfer commands use — normally two confirmations and
no typing. `jsonyter-sync-add-pair` does the same thing as a standalone
command, and `jsonyter-sync-forget-pair` removes one again, optionally
deleting its baseline.

Which pair a command means is resolved in order: the pair whose
`:local` is the current directory or one of its parents (the most
specific match wins); otherwise the one pair left after filtering by
server; otherwise a choice among the ones that remain.

### Commands

| Command | What it does |
| --- | --- |
| `jsonyter-sync` (`C-c C-y`) | Reconcile the current pair: plan, review if warranted, apply |
| `jsonyter-sync-status` | Plan only — the read-only "what would change?" verb |
| `jsonyter-sync-push` | Reconcile with **local** winning every conflict |
| `jsonyter-sync-pull` | Reconcile with **remote** winning every conflict |
| `jsonyter-sync-abort` | Stop a running sync after the current file |
| `jsonyter-sync-add-pair` | Define a pair interactively |
| `jsonyter-sync-forget-pair` | Drop a pair, optionally deleting its baseline |
| `jsonyter-sync-reset-baseline` | Discard a pair's baseline; the next sync starts fresh |

`jsonyter-sync-push`/`-pull` are **not** "upload the tree" / "download
the tree": unchanged files are still skipped, ignore patterns still
apply, and nothing is deleted unless the delete policy says so — only a
genuine conflict is forced to one side.

In `jsonyter-remote-dired`, `S` runs `jsonyter-sync` and `%` runs
`jsonyter-sync-status`, against whichever pair covers the directory
being browsed.

### Policies

```elisp
(setq jsonyter-sync-conflict-policy 'ask)     ; ask | newest | local | remote | skip
(setq jsonyter-sync-delete-policy 'none)      ; none | push | pull | both
(setq jsonyter-sync-review 'when-destructive) ; always | when-destructive | never
```

**Conflicts default to `ask`**, not `newest`, even though the bridge's
own non-interactive `sync()` defaults to `newest` — a script can't
answer a question, but Emacs can, and putting the decision in front of
whoever knows which edit they meant to keep is the whole point of a
front end. `newest` (clock-skew corrected, and it refuses to guess when
the two timestamps are too close to call) is one keystroke away in the
plan buffer.

**Deletion propagation is off by default**, matching the bridge: a file
missing on one side is left alone and reported, never silently removed
from the other. Turn it on, per pair or globally, once you trust it —
and note the bulk-deletion guard, `jsonyter-sync-max-deletes` (default
25): it refuses a plan that would delete an implausible number of
files, the signature of an unmounted volume or a wrong directory rather
than of real intent.

**The review buffer** (`jsonyter-sync-review`) shows itself when a plan
would delete something, resolve a conflict by overwriting a side, or
move more than `jsonyter-sync-review-threshold` files (10 by default); a
prefix argument to any sync command forces it open regardless, and a
purely additive small sync just runs.

### The plan buffer

A `tabulated-list` buffer, `*jsonyter-sync: <local> <-> <remote>*`,
shown before anything moves whenever review is warranted:

```
  ~/project/data <-> work/data on https://jupyter.example.org   8 to
  transfer (184.3 MB up, 4.1 KB down) · 1 conflict · 110 unchanged

     File                        Size      Local      Remote     Note
  >  trials.csv                  184.3 MB  14:22      09-07      new
  <  out/fig.png                   4.1 KB  --         15:58      new
  !  notes.md                      2.1 KB  15:40      16:10      both changed
```

| Key | Action |
| --- | --- |
| `RET` | Describe the entry: both hashes, both mtimes, the baseline |
| `>` / `<` | Override: local wins / remote wins |
| `d` | Override to delete a copy (asks which, on a two-sided conflict) |
| `k` | Override to skip |
| `n` / `N` | Resolve a conflict by newest / by whichever side is *not* newest |
| `u` / `U` | Clear the override at point / clear all overrides |
| `g` | Re-plan — the trees may have moved since |
| `T` | Toggle whether unchanged (`=`) rows are shown |
| `D` | Diff this entry's two versions (`ediff-files` by default) |
| `x` | **Apply the plan.** The only key here that writes anything |
| `q` | Quit without doing anything |

Overrides are sent to the bridge as data alongside the unmodified plan,
never as an edited plan — the bridge stays the authority on what a plan
means.

### Progress and reporting

A running sync shows its progress in the echo area and a `:sync I/N` tag
in the mode line of the session it belongs to, the same way a transfer's
`:up NN%` does. On completion:

```
jsonyter: synced ~/project/data <-> work/data — 3 up (184.3 MB), 5 down
(4.1 KB), 1 converged, sha256 verified, 32s
```

An unresolved conflict or a failed file is named explicitly, with its
recovery (`jsonyter-sync-status` to resolve it, or a re-run to pick up a
file that changed mid-sync); the full per-file detail is kept in
`*jsonyter-sync-log*`.

## Script cells (`# %%`)

`jsonyter-script-mode` gives an ordinary `.py`/`.R`/`.jl`/`.sas` script the
same execute-and-see-results-inline experience, with cells delimited by
`# %%` markers (the Jupytext/VS Code/Spyder convention, and its comment
variants, per `jsonyter-script-cell-regexp`).

```elisp
(add-hook 'python-mode-hook #'jsonyter-script-mode-maybe)
```

`jsonyter-script-mode-maybe` enables the mode only in buffers that
actually contain cell markers. Keys mirror the notebook: `C-RET` run,
`S-RET` run and advance, `C-c C-n`/`C-c C-p` to move between cells,
`C-c C-c` interrupt, `C-c M-O` clear all output, `C-c C-l`/`C-c C-j`
reconnect or attach to a kernel.

Output appears inline in overlays, so **the file's text is never
touched** and saving stays completely ordinary. That is also the one
thing script cells give up against notebooks: an overlay string cannot
be scrolled into, so a tall image is shown whole here rather than sliced
across lines. The kernel language comes from the buffer's major mode via
`jsonyter-script-languages`.

## Org-mode source blocks

`jsonyter-org-mode` runs `#+begin_src` blocks against Jupyter kernels
from inside an Org file, with output rendered beneath the block and,
when you want it, committed to a `#+RESULTS:` drawer.

```elisp
(add-hook 'org-mode-hook #'jsonyter-org-mode-maybe)
```

`jsonyter-org-mode-maybe` turns the mode on only in files that opt in, so
Org files that don't mention jsonyter are unaffected. `org` itself is
loaded lazily the first time the mode is enabled.

Running blocks survives a major-mode restart — `M-x org-mode-restart`
(which is also what `C-c C-c` on a `#+PROPERTY:` line runs, to make it
take effect), `revert-buffer` and `normal-mode` all re-run `org-mode`,
which would otherwise wipe the buffer's kernel session table and orphan
any kernel already running. It does not: the session table, callback
table and bridge process are marked `permanent-local` and survive the
restart intact, so a block right after one still reuses the same kernel
with all of its state, and the kernel is not leaked on the server. With
`jsonyter-org-mode-maybe` on `org-mode-hook` as above, `jsonyter-org-mode`
itself also turns back on automatically; even without that hook, running
a block still works — it bootstraps the same way the `org-babel` back
door (`C-c C-c`) always has.

### Opting in: `:session jy:`

A block routes to jsonyter when its `:session` header argument starts
with `jy:`. Anything else — a bare `:session`, a plain name, or no
`:session` — is left entirely to Org, so enabling the mode changes the
behaviour of no existing file.

```org
#+begin_src python :session jy:main
import numpy as np
np.random.default_rng(0).normal(size=5).mean()
#+end_src
```

| Form | Meaning |
| --- | --- |
| `:session jy:NAME` | Named session. Started on first use, reused after. |
| `:session jy:` | The default session for this block's language in this buffer. |
| `:session jy:@KERNEL-ID` | Attach to a kernel already running on the server, by id. Never shut down on your behalf. |

Sessions are keyed **(language, name)**, so `jy:main` in a Python block
and `jy:main` in an R block are two different kernels. A variable one
block defines is visible to every later block in the same session.

File-wide or subtree-wide opt-in uses Org's ordinary property mechanism:

```org
#+PROPERTY: header-args:python :session jy:main
#+PROPERTY: header-args:R      :session jy:main
```

A `:kernel` header arg pins the kernelspec for one block, overriding
`jsonyter-kernel-names`:

```org
#+begin_src R :session jy:main :kernel ir
```

### Keys

Every binding that shadows an Org command is **conditional**: inside a
`jy:` block it runs the jsonyter action; anywhere else it falls through
to what Org would otherwise do. `org-edit-special` (`C-c '`) is
unaffected.

| Key | Action |
| --- | --- |
| `C-RET` | Run the block at point (`jsonyter-org-run-block`, aka `jsonyter-org-run-cell`) |
| `S-RET` | Run the block and move to the next (aka `jsonyter-org-run-cell-and-advance`) |
| `C-c C-v C-b` | Run every `jy:` block in the buffer, in order |
| `C-c C-n` / `C-c C-p` | Next / previous `jy:` block (from anywhere) |
| `C-c C-c` | Interrupt the session at point |
| `C-c C-r` | Restart the session at point, same id, all state lost |
| `C-c C-l` / `C-c C-j` | Reconnect / attach this session to a kernel |
| `C-c M-h` | Kernel history for the session at point |
| `C-c C-d` | Documentation for the thing at point (`inspect`) |
| `C-c M-o` / `C-c M-O` | Clear this block's output / all overlay output |
| `C-c C-s` | Commit this block's output to `#+RESULTS:` |
| `C-c C-M-s` | Commit every shown output in the buffer |

### Results: overlay first, commit on demand

Running a block touches no buffer text — output is an overlay, exactly
as in a `# %%` script. Exploratory runs stay out of `git diff`.

`C-c C-s` writes the shown output into a `#+RESULTS:` drawer beneath the
block; `C-c C-M-s` does it for every block that has output, leaving
untouched blocks exactly as they were. Multiple outputs (a stream, a
figure, a value) go in a `:results:` … `:end:` drawer:

```org
#+RESULTS[8f3a1c2]:
:results:
: fitting…
: R² = 0.87, n = 240
[[file:.jsonyter/plot-8f3a1c2e0b4d.png]]
:end:
```

The `[8f3a1c2]` is Org's own `#+RESULTS[<hash>]:` slot, stamped with the
block's source hash. Reopen the file a month later and jsonyter frames
every result whose block has since been edited in
`jsonyter-output-border-stale-face` — **before any kernel starts**.
This is the one slot Org's `:cache yes` also uses; the two are mutually
exclusive per block. Set `jsonyter-org-stamp-results` to nil to turn the
stamping off.

### Images

Committed figures are written to `jsonyter-org-image-directory` (default
`./.jsonyter/`, relative to the Org file) as content-addressed
`plot-<hash>.png` files and linked with `[[file:…]]`. Re-committing a
block deletes the files its previous result referenced, but only inside
that managed directory. `jsonyter-org-clean-images` removes files no
result still links. With the default directory, add `.jsonyter/` to
`.gitignore`; set it to `./images/` to version figures alongside the
document.

Image bytes arrive over the websocket, so figures work identically
against a remote server.

### The org-babel backend: `C-c C-c`, export, tangle

`jsonyter-org-mode` is one way in — `C-RET` against an overlay. The
other is standard Org Babel: `org-babel-execute:python` (and `:R`,
`:julia`, `:SAS`) run a `jy:` block through the very same session, so
`C-c C-c`, `C-c C-e` export and `org-babel-tangle` all work on it too. A
variable a `C-RET` run defines is visible to a `C-c C-c` run in the same
session and back again — the two are front doors onto one kernel, not
two competing mechanisms. A block with no `jy:` session is untouched: it
runs through whatever `org-babel-execute:LANG` Org itself defines
(`ob-python`, `ob-R`, `ob-julia`), exactly as if jsonyter did not exist.
This works whether or not `jsonyter-org-mode` is turned on — export in
particular often runs without it ever having been enabled.

SAS is the one language Org ships no backend for at all; a `jy:` SAS
block gets kernel-backed Babel execution for the first time, and a
non-`jy:` SAS block gets Org's own "no org-babel-execute function"
error, same as before jsonyter existed.

`:results` works as documented: `output` / `value` selects stream text
or the kernel's own execute-result value; `html` / `latex` unwrap the
matching mimetype into an export block; `file` writes an image to
`jsonyter-org-image-directory` and links it, the same as a committed
cell (see Images, above). An error's traceback, ANSI stripped, is
returned as the result regardless of `:results`.

By default, `org-babel-tangle` prefixes each `jy:` block's tangled text
with a `# %%` marker (set `jsonyter-org-tangle-cell-markers` to nil to
turn that off), so a file tangled out of one or more `jy:` blocks opens
ready for `jsonyter-script-mode`.

### Async: `:async yes`

The cell layer (`C-RET`) is always async and ignores this header
entirely — `:async` only ever affects the Babel path (`C-c C-c`), so it
does nothing useful in a `#+PROPERTY:` line that exists only to set up
`C-RET` sessions and can simply be dropped there. Add `:async yes` and
`C-c C-c` returns immediately with a placeholder result; when the kernel
answers, jsonyter finds the placeholder by its opaque token and replaces
it in place. A second `C-c C-c` on a session already busy is refused,
not queued or made to interrupt the first. Exporting always runs
synchronously regardless of `:async`, since `ox` collects the whole
buffer in one pass and has nowhere for an async result to land; the wait
is bounded by `jsonyter-exec-timeout`.

**Do not load `ob-async` in a buffer that uses jsonyter's `:async yes`.**
`ob-async` claims the same header argument for itself and implements it
by running each block in a *separate Emacs subprocess*; if it is loaded,
its advice on `org-babel-execute-src-block` intercepts before jsonyter's
own dispatch ever runs. Every block then gets a fresh Emacs, a fresh
session table, and its own kernel — symptoms identical to a kernel
started fresh per cell, for a reason that has nothing to do with
jsonyter's session handling. jsonyter implements its own async path
precisely so `ob-async` is unnecessary for `jy:` blocks; if other blocks
in the same Org install still need it, keep `:async` off any `jy:`
block's header args.

### `:var`

Org table and scalar `:var` bindings are marshalled into a short prelude
prepended to the block, one statement per binding:

| Language | Scalars | Table |
| --- | --- | --- |
| Python | literals | list of lists, or a `pandas.DataFrame` with `:colnames yes` |
| R | literals | `matrix`, or `data.frame` with `:colnames yes` |
| Julia | literals | `Matrix`; `DataFrame` only with `jsonyter-org-var-julia-dataframe` also set, since DataFrames.jl is not assumed to be loaded |
| SAS | `%let` | `DATALINES`, for an all-numeric table only — a character field containing whitespace signals a clear error rather than risk silently corrupting it |

A binding over `jsonyter-org-var-size-limit` characters (default
100,000) signals a clear error instead of sending a huge execute
payload; read the data from the kernel's filesystem instead.

### `.ipynb` ↔ `.org` conversion

`jsonyter-org-from-notebook` writes a `.ipynb` file out as `.org`: each
code cell becomes a `jy:` block, each stored output a committed
`#+RESULTS:` drawer (images included), and the kernelspec a buffer-wide
`#+PROPERTY:` line, so the file runs as-is. `jsonyter-org-to-notebook` is
the reverse; every cell keeps its nbformat id in a `:PROPERTIES:` drawer,
so writing back merges onto the original file by id rather than
regenerating it wholesale — an unedited round trip reproduces the
original file, and a one-block edit becomes a one-cell diff, the same
guarantee `jsonyter-notebook-save-with-outputs` already gives a notebook
buffer.

Markdown ↔ Org is the one lossy step: jsonyter shells out to `pandoc`
when it is on `exec-path`, and otherwise inserts the text unchanged with
a note saying so. Set `jsonyter-org-markdown-converter` to use something
else.

## Exporting notebooks

`jsonyter-notebook-export` renders a notebook to HTML, PDF, LaTeX,
Markdown, slides or any other format the server's `nbconvert` install
offers, through the bridge's `export_notebook`/`list_export_formats`
verbs (jsonyter **>= 2.0.0**). Bound to `C-c C-x` in a notebook buffer:

```elisp
(jsonyter-notebook-export "html" "~/reports/analysis.html")
```

Interactively, `C-c C-x` (or `M-x jsonyter-notebook-export`) prompts for
the format via `completing-read` over what the server actually
advertises — never a hardcoded list, so a third-party exporter the
server registers shows up automatically — and for the destination file.
Six formats worth a name of their own also get a dedicated command:
`jsonyter-notebook-export-html`, `-markdown`, `-pdf`, `-latex`,
`-webpdf`, `-slides`. `M-x jsonyter-notebook-export-formats` shows what
the current server offers, without exporting anything — the first thing
to check before waiting on a render that is only going to fail.

The export always reflects the buffer as it stands right now — unsaved
edits and this session's outputs included, plus every cell's outputs
already stored on disk for one nothing has been re-run — not merely what
was last saved to a file. It runs on the bridge's REST pool rather than
a kernel, so it is safe to start while a cell is executing, and
asynchronously: a PDF or `webpdf` render can take minutes
(`jsonyter-export-timeout`, default 120s, matching the bridge's own),
and the mode line shows a plain `:export` tag while one is in flight.

**`html` and `markdown` work essentially everywhere; `pdf` and `webpdf`
frequently do not**, because both need extra software installed **on the
Jupyter server itself** — a distinction worth knowing before filing a bug
against the wrong repository:

| Format | Needs on the Jupyter server |
| --- | --- |
| `pdf` / `latex` | pandoc + a LaTeX engine (e.g. `xelatex`) |
| `webpdf` | playwright + chromium; in a root container, also `c.WebPDFExporter.disable_sandbox = True` |

A failed export's message includes the bridge's own `hint` when it has
one — `pdf` failing with a bare "Pandoc wasn't found" is the single most
likely first-run failure, and the hint names exactly what to install,
where. `M-x jsonyter-notebook-export-formats` catches a missing exporter
up front instead.

From `jsonyter-remote-dired` (`E` on a `.ipynb` entry), the same command
exports a notebook that only exists on the server, via its real
Contents-API path rather than a local buffer's cells.

Document export from an Org buffer is not built as a separate stack:
`jsonyter-org-to-notebook` plus `jsonyter-notebook-export` already
compose into that two-step path, and Org's own `ox` covers HTML/PDF/...
export natively besides.

## Exporting to a script

`jsonyter-notebook-export-script` (from a rendered notebook buffer) and
`jsonyter-org-export-script` (from an Org buffer's `jy:` blocks) write a
plain `.py`/`.R`/`.jl`/`.sas` script with `# %%` cell dividers — the
Jupytext/VS Code/Spyder "percent" format — for people who don't use
notebooks or Org:

```python
# %% [markdown]
# # Analysis
#
# Some **bold** prose, wrapped in a comment verbatim.

# %%
import numpy as np
np.random.default_rng(0).normal(size=5).mean()
```

Both are a **local text transformation**: unlike every other
`jsonyter-notebook-export-*` command, this needs no Jupyter server,
kernel or bridge at all, and works against a notebook or Org file that
has never been run. Markdown/raw prose is wrapped verbatim, never
converted or reformatted — it is there to be *read*, not re-parsed, and
this keeps the transformation lossless and pandoc-free.

Direction is one-way — notebook/Org → script — by design, not by
limitation. For Python, R and Julia the `# %%` marker is exactly what
`jsonyter-script-cell-regexp` matches, so the result reopens in
`jsonyter-script-mode` with the same cell boundaries at zero extra cost —
a free bonus, not a requirement, and nothing here is designed around
preserving it.

**SAS is one-way only, and that's deliberate.** SAS's own comment forms
(`* text;`, `/* text */`) have no safe form of `# %%`: a bare `%%` is a
macro reference in SAS, so `* %%;` is what gets written instead, and it
does not match `jsonyter-script-cell-regexp`. Markdown in a SAS export is
also wrapped differently — in a single `/* ... */` block, not commented
line by line — because `* text;` is terminated by the *first* semicolon,
and prose containing one (entirely ordinary) would otherwise leak into
the script as SAS code.

Customize `jsonyter-script-export-languages` to add a language jsonyter
does not ship support for, or to change the extension/divider/comment
style of one it does.

## Extending jsonyter.el: `jsonyter-mode`

`jsonyter-mode` is a marker minor mode, on in every jsonyter buffer —
REPL, rendered notebook, a `# %%` script, or a `jsonyter-org-mode` Org
file — regardless of which. It carries no keymap or behavior of its own;
it exists so other code can ask "is this any kind of jsonyter buffer"
with one check, `(bound-and-true-p jsonyter-mode)`, instead of testing
each specific mode itself.

`jsonyter-save-buffer` is built on this and is the pattern to copy:
dispatch on a specific mode only where that mode's buffer actually needs
different handling — a notebook needs `jsonyter-notebook-save-buffer` to
avoid a silent no-op when only session output changed — and treat
`jsonyter-mode` as the umbrella everything else hangs off:

```elisp
(defun my/save-buffer ()
  (interactive)
  (if (bound-and-true-p jsonyter-mode)
      (jsonyter-save-buffer)
    (save-buffer)))
```

This lets a single "save" key bound elsewhere in a config do the right
thing in a jsonyter notebook without changing behavior anywhere else.

## Kernel quirks this handles

Kernels vary in how faithfully they implement the messaging protocol.
Two behaviours are worth knowing about:

- **`is_complete` is asked about newline-terminated code.** The SAS
  kernel calls anything without a trailing newline "incomplete",
  including the empty string. Terminating the code first handles that,
  and also handles Python, where `def f():\n    return 1` reads as
  incomplete bare but complete when terminated. Genuinely unfinished
  input still reports incomplete on every kernel, so nothing is
  submitted early. Use `C-j` for a literal newline, or `M-RET` to
  force-send.
- **Short kernel requests carry an explicit timeout.** The bridge
  serializes requests per kernel, so a kernel that never answers a
  message type can block that kernel's worker and queue every later
  execute behind it — the REPL appearing hung with the kernel stuck
  "busy". SAS never answers `history` and answers `inspect` with
  `aborted`, so this is reachable in practice. jsonyter.el bounds these
  calls with `jsonyter-request-timeout` so one unanswered request cannot
  wedge the queue. `C-c C-k` is the manual escape hatch if a prompt
  still gets stuck.

If `is_complete` fails twice in a row the REPL stops asking and `RET`
always sends.

SAS is also slow on first contact: its first execute spends ~17s
establishing the SAS subprocess before producing output. That is the
kernel warming up, not a hang — streaming shows "SAS Connection
established" as soon as it arrives.

## Architecture notes

Each jsonyter buffer owns a single `jsonyter` bridge process and a table
of **sessions** keyed `(language, name)`. A REPL, notebook or script
buffer holds one entry — one kernel by nature — and its commands read it
as "the current session"; a `jsonyter-org-mode` buffer holds one entry
per `jy:` session in the file. The bridge is concurrent — REST calls run
on a pool and each kernel gets its own worker — so one bridge serves
every session at once, `C-c C-c` is delivered over the same pipe while a
cell is still running, and a `dead` event from one kernel is routed to
its own session without disturbing the others. Replies are matched by
request id, since they can arrive out of order. The bridge's stderr goes
to a hidden buffer (` *jsonyter stderr*`) so Python warnings cannot
corrupt the JSON protocol on stdout.

The buffer-local scalars `jsonyter--kernel-id`, `jsonyter--busy` and the
rest were replaced by that table in 2.0. Config that read them should
use `jsonyter-current-kernel-id`, `jsonyter-current-session` and
`jsonyter-current-kernel-busy-p` instead; the old names remain as
obsolete aliases for one release.

Streaming and the final reply are reconciled by count: the bridge repeats
every streamed output in the final `outputs` list, so jsonyter.el renders
only the tail past what it already drew.

## Tests

Two suites, covering different halves of the package.

```bash
# the headless one: logic, parsing, cell bookkeeping, save round trips
emacs -Q --batch -L . -l test/jsonyter-tests.el -f ert-run-tests-batch-and-exit
```

That runs 116 tests under `emacs -Q --batch`, where there is no frame, no
X server and no redisplay — so it structurally cannot see whether a
base64 PNG in a mimebundle actually decodes, whether a tall figure
becomes drawable rows or one blob, or whether `C-RET` is bound to what
you think it is.

[`harness/`](harness/) is the other half: 51 scenarios that run in a
**real graphical Emacs on an X server in a container**, driven through
the actual command loop, using
[emacs-harness](https://github.com/EGuthrieWasTaken/emacs-harness).
Almost all of them run against a scripted stand-in for the `jsonyter`
Python bridge, which is what makes a dead kernel, a half-open
connection, a request that is never answered, or a backend chattering on
stderr something a test can ask for by name.

```bash
git clone https://github.com/EGuthrieWasTaken/emacs-harness ../emacs-harness
harness/run.sh --build      # the real thing, in the container
harness/run-batch.sh        # the same scenarios headlessly, as a fast loop
```

Both run on every pull request (`.github/workflows/harness.yml`). See
[`harness/README.md`](harness/README.md) for what is covered, how to
drive a live session by hand, and how to add a scenario.
