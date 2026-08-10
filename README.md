# jsonyter.el

Interactive Jupyter REPL buffers for Emacs, backed by the
[jsonyter](../jsonyter) Python package's JSON-over-stdio bridge. Each REPL
buffer talks to a kernel on a local or remote Jupyter server, with live
streaming output, inline image rendering, kernel-backed completion,
documentation lookup, and `input()` support — no notebook files involved.

## Requirements

- Emacs 27.1+ (images need a graphical Emacs built with image support)
- The `jsonyter` Python package, version 0.2 or newer (`pip install -e .` in
  the jsonyter repo), plus a reachable Jupyter server
  (`jupyter server --ServerApp.token=SECRET`)

Against an older 0.1 bridge the REPL still works; you lose live streaming
and the kernel-state indicator, and interrupt is not serviced while a cell
is running.

Newer bridges add a `control_timeout` that bounds the introspection calls
and a thread-safe `connect()`. jsonyter.el does not require either — it
sends its own per-call timeouts, and its startup is sequenced so that no
two connection-opening requests are ever in flight at once — but both are
worth having, particularly if you drive the same bridge from other code.

## Setup

```elisp
(add-to-list 'load-path "/path/to/jsonyter.el")
(require 'jsonyter)  ; or autoload the jsonyter-start-* commands
```

If the `jsonyter` entry-point script is not on Emacs's `exec-path`, point
`jsonyter-command` at the module instead:

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

Execution results are still not persisted — only source, cell order, and
cell types. If the file changed on disk since it was opened, the save is
refused rather than clobbering the other change; revert to reload.

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
