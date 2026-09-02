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
`org-babel-tangle` all work on it, on the same kernel `C-RET` uses.

> **A note on how this was built.** The bulk of jsonyter.el was written by
> Claude Fable 5, an Anthropic AI model, working iteratively with the
> project's maintainer over the course of development — design decisions,
> requirements and review were mine; the code, and much of the
> exploratory verification behind it, were largely the model's.

## Requirements

- Emacs 27.1+ (images need a graphical Emacs built with image support)
- Org 9.4+ (bundled with Emacs 27.1+); only loaded when `jsonyter-org-mode` is used, or Org Babel itself is
- The [jsonyter](https://github.com/EGuthrieWasTaken/jsonyter) Python
  package, 1.0.0 or newer:
  ```bash
  pip install jsonyter
  ```
- A reachable Jupyter server: `pip install jupyter-server ipykernel` and
  `jupyter server --ServerApp.token=SECRET`, local or remote

## Setup

### Install from a release (recommended)

**Current stable release: `v1.3.0`.** The `v2.x` tags are published as
GitHub *pre-releases* — the 2.x line isn't fully operational yet — so pin
to `v1.3.0` unless you're specifically helping test 2.x.

Each release is a Git tag `vX.Y.Z`. Pinning to one keeps an upstream
change from breaking your setup between updates.

**Manual:** grab the single file at the tag and put it on your
`load-path`:

```bash
curl -O https://raw.githubusercontent.com/EGuthrieWasTaken/jsonyter.el/v1.3.0/jsonyter.el
```

```elisp
(add-to-list 'load-path "/path/to/jsonyter")  ; the directory holding jsonyter.el
(require 'jsonyter)  ; or autoload the jsonyter-start-* commands
```

Releases from `v2.x` onward also attach `jsonyter.el` directly on the
[Releases page](https://github.com/EGuthrieWasTaken/jsonyter.el/releases).

**`package-vc-install`** (built into Emacs 29+, no third-party manager):

```elisp
(package-vc-install
 '(jsonyter :url "https://github.com/EGuthrieWasTaken/jsonyter.el" :rev "v1.3.0"))
```

**[elpaca](https://github.com/progfolio/elpaca):** pin the recipe to the
tag with `:ref`:

```elisp
(use-package jsonyter
  :ensure (:host github :repo "EGuthrieWasTaken/jsonyter.el" :ref "v1.3.0"))
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
| `jsonyter-image-max-width` | `800` | Max pixel width for inline images. |
| `jsonyter-image-max-height` | `nil` | Max pixel height for inline images. |
| `jsonyter-slice-images` | `t` | Slice tall images one line per row so they scroll (REPL and notebook buffers). |
| `jsonyter-suppress-line-spacing` | `t` | Drop `line-spacing` in REPL and notebook buffers, where its leading would band a sliced image. |
| `jsonyter-render-html` | `t` | Render `text/html` output with shr. |
| `jsonyter-insecure-tls` | `nil` | Skip TLS verification (self-signed remote servers). |
| `jsonyter-shutdown-on-kill` | `t` | Shut the kernel down when the REPL buffer is killed. |

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
| `C-c C-r` | Restart the kernel |
| `C-c C-q` | Shut the kernel down |
| `C-c C-l` | Reconnect to this buffer's kernel after a dropped connection |
| `C-c C-j` | Attach this buffer to any kernel running on the server |
| `C-c M-h` | Show the kernel's most recent commands |
| `C-c C-d` | Documentation for the thing at point (`inspect`) |
| `C-c C-k` | Reset a REPL stuck at "kernel is busy" |
| `C-c M-o` | Clear output above the prompt |

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
above and below by a labelled rule, so where a cell's code ends and its
results begin stays clear however long the output runs. A cell with no
output has no frame at all. Edit a cell's source after it has run and its
frame changes face and reads `output (stale)`, flagging results that may
no longer match the code in front of you; re-running the cell clears it,
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
| `C-c C-r` | Restart the kernel |
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
| `C-RET` | Run the block at point |
| `S-RET` | Run the block and move to the next |
| `C-c C-v C-b` | Run every `jy:` block in the buffer, in order |
| `C-c C-n` / `C-c C-p` | Next / previous `jy:` block (from anywhere) |
| `C-c C-c` | Interrupt the session at point |
| `C-c C-r` | Restart the session at point |
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

The cell layer (`C-RET`) is always async — this only affects the Babel
path. Add `:async yes` and `C-c C-c` returns immediately with a
placeholder result; when the kernel answers, jsonyter finds the
placeholder by its opaque token and replaces it in place. A second
`C-c C-c` on a session already busy is refused, not queued or made to
interrupt the first. Exporting always runs synchronously regardless of
`:async`, since `ox` collects the whole buffer in one pass and has
nowhere for an async result to land; the wait is bounded by
`jsonyter-exec-timeout`.

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

That runs 91 tests under `emacs -Q --batch`, where there is no frame, no
X server and no redisplay — so it structurally cannot see whether a
base64 PNG in a mimebundle actually decodes, whether a tall figure
becomes drawable rows or one blob, or whether `C-RET` is bound to what
you think it is.

[`harness/`](harness/) is the other half: 45 scenarios that run in a
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
