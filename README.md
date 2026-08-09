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
  serializes requests per kernel and waits forever by default, so a
  kernel that never answers a message type would block that kernel's
  worker permanently and queue every later execute behind it — the REPL
  appearing hung with the kernel stuck "busy". SAS never answers
  `history` and answers `inspect` with `aborted`, so this was reachable
  in practice. `is_complete`/`complete`/`inspect` now bound the wait on
  the bridge side and recover on their own. `C-c C-k` is the manual
  escape hatch if a prompt still gets stuck.

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
