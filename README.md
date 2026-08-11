# jsonyter.el

Jupyter, natively in Emacs — REPLs, rendered `.ipynb` notebooks, and `# %%`
script cells, all against Python, Julia, R or SAS kernels on a local or
remote server, backed by the
[jsonyter](https://github.com/EGuthrieWasTaken/jsonyter) Python package's
JSON-over-stdio bridge. Streaming output, inline images, kernel-backed
completion and documentation lookup, `input()` support, and — for
notebooks — lossless byte-identical saves that never touch stored outputs
unless you ask.

> **A note on how this was built.** The bulk of jsonyter.el was written by
> Claude Fable 5, an Anthropic AI model, working iteratively with the
> project's maintainer over the course of development — design decisions,
> requirements and review were mine; the code, and much of the
> exploratory verification behind it, were largely the model's.

## Requirements

- Emacs 27.1+ (images need a graphical Emacs built with image support)
- The [jsonyter](https://github.com/EGuthrieWasTaken/jsonyter) Python
  package, 1.0.0 or newer:
  ```bash
  pip install jsonyter
  ```
- A reachable Jupyter server: `pip install jupyter-server ipykernel` and
  `jupyter server --ServerApp.token=SECRET`, local or remote

Missing Python, or the `jsonyter` package, is a clear error rather than a
hang or a silent failure: if the bridge command can't be found at all,
jsonyter.el names it and points at `pip install jsonyter`; if it's found
but exits before answering (e.g. the interpreter it points at doesn't
have the package), the actual Python error — usually `No module named
jsonyter` — is surfaced directly rather than a generic "process died."

## Setup

Pick whichever matches your Emacs package manager. All of these fetch
straight from GitHub, so none of them need jsonyter.el to be listed on
MELPA — though once it is, `:ensure t` alone will also work, no recipe
needed.

**[straight.el](https://github.com/radian-software/straight.el):**

```elisp
(straight-use-package
 '(jsonyter :type git :host github :repo "EGuthrieWasTaken/jsonyter.el"))
```

**[elpaca](https://github.com/progfolio/elpaca):**

```elisp
(use-package jsonyter
  :ensure (:host github :repo "EGuthrieWasTaken/jsonyter.el"))
```

**package.el / use-package, via MELPA (once listed):**

```elisp
(use-package jsonyter
  :ensure t)
```

**Manual:**

```elisp
(add-to-list 'load-path "/path/to/jsonyter.el")
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
the command line, where `ps` would expose it to every local user — which
would otherwise defeat the point of encrypting the file:

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
| `jsonyter-slice-images` | `t` | Slice tall images one line per row so they scroll. |
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

Images taller than one text line are inserted **sliced**, one slice per
line (the technique `doc-view` uses for page images). Emacs scrolls by
whole lines, and an image inserted the ordinary way occupies a single
line however tall it is — so a tall plot is all-or-nothing: scrolling
either steps clean over it or lands mid-image showing only its bottom
edge. Slicing lets ordinary line scrolling walk through a plot like
normal text. Set `jsonyter-slice-images` to nil to opt out, or
`jsonyter-image-max-height` to shrink tall plots to fit instead.

## Kernel state

The mode line reports the kernel's real state, pushed from the bridge's
event subscription rather than polled:

| Indicator | Meaning |
| --- | --- |
| `:idle` | ready |
| `:run` | running your cell |
| `:run[ext]` | busy on behalf of another client attached to the same kernel |
| `:starting` / `:restarting` | coming up |
| `:offline` | the bridge's websocket dropped (it reconnects on the next send) |
| `:dead` | the kernel is gone — `C-c C-r` to restart |

A kernel killed out from under the REPL (say, shut down from a notebook UI)
reports itself as dead in the buffer instead of hanging the next execute.

## Notebooks (.ipynb)

Register the opener and `.ipynb` files render as notebooks instead of raw
JSON:

```elisp
(add-to-list 'auto-mode-alist '("\\.ipynb\\'" . jsonyter-notebook-open))
```

Cell source is ordinary buffer text, edited in the notebook language's own
major mode — `python-mode`, `ess-r-mode`, and so on, per
`jsonyter-notebook-language-modes` — so syntax highlighting, indentation
and completion are the language's own. Cell prompts and all output live in
**overlays, not buffer text**. That is what lets outputs be read-only and
invisible to undo: undo walks your edits and never your results, and no
stray edit can corrupt an output region because there is no output region
in the text to corrupt.

| Key | Action |
| --- | --- |
| `C-RET` | Run the cell at point |
| `S-RET` | Run the cell and advance to the next |
| `C-c C-b` | Run every code cell in order |
| `C-c C-n` / `C-c C-p` | Next / previous cell |
| `C-c C-c` | Interrupt the kernel |
| `C-c C-r` | Restart the kernel |
| `C-c M-o` / `C-c M-O` | Clear this cell's output / all output |
| `C-c C-k` | Start the kernel explicitly |
| `C-c C-i` / `C-c C-a` | Insert a cell below / above (`C-u` for markdown) |
| `C-c C-w` | Delete the cell at point |
| `C-c C-t` | Toggle the cell between code and markdown |
| `C-c <up>` / `C-c <down>` | Move the cell up / down |
| `C-x C-s` | Save cell source |
| `C-c C-s` | Save cell source and this session's new outputs |

`M-x jsonyter-clear` clears every output in the buffer and blanks the
execution counts, leaving the notebook as though nothing had been run —
what you want before running a project through cleanly. It does the
equivalent thing in a REPL or script buffer too.

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
figure out of the file; because running a cell changes no buffer text,
Emacs would otherwise consider the buffer unmodified and return silently,
which is indistinguishable from a save that failed, so this says so
explicitly instead.

`C-c C-s` (`jsonyter-notebook-save-with-outputs`) saves source **and**
this session's new outputs. A cell run, or explicitly cleared (`C-c M-o`
/ `C-c M-O`), since the notebook was opened has its stored output
replaced by what is currently shown; every other cell's stored output —
anything not touched this session — is left exactly as it was. That
means the diff is proportional to what you actually reran, not the whole
file: rerun one cell and only that cell's output changes on disk.

If the file changed on disk since it was opened, either save is refused
rather than clobbering the other change; revert to reload.

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
`C-c C-c` interrupt, `C-c M-O` clear all output.

Output appears inline in overlays, so **the file's text is never
touched** and saving stays completely ordinary. The kernel language comes
from the buffer's major mode via `jsonyter-script-languages`.

## Extending jsonyter.el: `jsonyter-mode`

`jsonyter-mode` is a marker minor mode, on in every jsonyter buffer —
REPL, rendered notebook, or a script with `# %%` cells — regardless of
which. It carries no keymap or behavior of its own; it exists so other
code can ask "is this any kind of jsonyter buffer" with one check,
`(bound-and-true-p jsonyter-mode)`, instead of testing all three
specific modes itself.

`jsonyter-save-buffer` is built on exactly this and is the pattern to
copy: dispatch on a specific mode only where that mode's buffer actually
needs different handling — a notebook needs `jsonyter-notebook-save-buffer`
to avoid a silent no-op when only session output changed — and treat
`jsonyter-mode` as the umbrella everything else hangs off:

```elisp
(defun my/save-buffer ()
  (interactive)
  (if (bound-and-true-p jsonyter-mode)
      (jsonyter-save-buffer)
    (save-buffer)))
```

That's a real, working example: it is what lets a single "save" key bound
elsewhere in a config do the right thing in a jsonyter notebook without
changing behavior anywhere else.

## Kernel quirks this handles

Kernels vary in how faithfully they implement the messaging protocol, and
two behaviours are worth knowing about because they used to break the
REPL outright:

- **`is_complete` is asked about newline-terminated code.** The SAS
  kernel calls anything without a trailing newline "incomplete" —
  including the empty string — so `RET` could never submit SAS at all.
  Terminating the code first fixes SAS and also fixes Python, where
  `def f():\n    return 1` reads as incomplete bare but complete when
  terminated. Genuinely unfinished input still reports incomplete on
  every kernel, so nothing is submitted early. Use `C-j` for a literal
  newline, or `M-RET` to force-send.
- **Short kernel requests carry an explicit timeout.** The bridge
  serializes requests per kernel, so a kernel that never answers a
  message type can block that kernel's worker and queue every later
  execute behind it — the REPL appearing hung with the kernel stuck
  "busy". SAS never answers `history` and answers `inspect` with
  `aborted`, so this is reachable in practice. Current bridges bound the
  introspection calls themselves via `control_timeout` (30s);
  jsonyter.el additionally sends a per-call timeout, which works the
  same on older bridges, keeps the bound at an interactive latency, and
  makes `jsonyter-request-timeout` the one knob that takes effect.
  `C-c C-k` is the manual escape hatch if a prompt still gets stuck.

If `is_complete` fails twice in a row the REPL stops asking and `RET`
simply always sends — one transient blip on a remote server won't cost
you multi-line editing, and a kernel that never answers stops being
asked almost immediately.

SAS is also slow on first contact: its first execute spends ~17s
establishing the SAS subprocess before producing output. That is the
kernel warming up, not a hang — streaming shows "SAS Connection
established" as soon as it arrives.

## Architecture notes

Each REPL buffer owns a single `jsonyter` bridge process. The bridge is
concurrent — REST calls run on a pool and each kernel gets its own worker —
so `C-c C-c` is delivered and acted on over the same pipe while a cell is
still running, with no separate control process. Replies are matched by
request id, since they can arrive out of order. The bridge's stderr goes to
a hidden buffer (` *jsonyter stderr*`) so Python warnings cannot corrupt
the JSON protocol on stdout.

Streaming and the final reply are reconciled by count: the bridge repeats
every streamed output in the final `outputs` list, so jsonyter.el renders
only the tail past what it already drew — which also means an older bridge
that streams nothing renders correctly at the end.
