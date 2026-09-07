# Feature request: file transfer — Emacs side

**Status:** proposed
**Date:** 2026-09-07
**Depends on:** `FEATURE-REQUEST-file-transfer.md` in the `jsonyter` Python
repo, which defines the protocol this document consumes. **Implement that
first.** Nothing here works until the bridge answers `upload`, `download`,
`list_contents` and friends.

This document covers only what happens inside Emacs: the commands, the remote
browser, and how progress and errors reach the user. The rationale for the
transport design, the Cloudflare constraints, and the path-semantics analysis
all live in the Python-side document and are not repeated.

---

## 1. What the user gets

- `M-x jsonyter-upload-file` / `M-x jsonyter-download-file` — one file, either
  direction, asynchronous, with a progress indicator.
- `M-x jsonyter-remote-dired` — a browsable listing of the server's filesystem
  with the usual file-management verbs.
- Marked files in a local `dired` buffer can be sent to the server in one
  command.

## 2. The one idea to keep hold of

**Remote paths are Contents API paths.** They are POSIX-style, relative to the
server's `root_dir`, and have no leading slash. They are *not* kernel-side
absolute paths, and the two must never be silently interchanged.

Every prompt says so:

```
Remote (contents) path:
```

The bridge's `kernel_contents_dir` answers "where is this kernel, expressed as
a contents path?" so commands can *default* sensibly — but a default is all it
is. When the probe returns `contents_dir: null` the default is simply absent;
do not fall back to a guess.

## 3. Configuration

```elisp
(defcustom jsonyter-upload-chunk-size (* 8 1024 1024) ...)
```
Raw bytes per chunk, passed through to the bridge. Document the ceiling in the
docstring: the request body is roughly 4/3 of this, and Cloudflare's default
cap is 100 MB, so values above ~74 MB will fail with a proxy 413.

```elisp
(defcustom jsonyter-remote-root nil ...)
```
The server's `root_dir` as an absolute path, or an alist keyed by server URL.
Only consulted when the sentinel probe cannot resolve the kernel's cwd — the
manual override for kernels running outside `root_dir`. `nil` means "probe
only".

```elisp
(defcustom jsonyter-download-directory nil ...)
```
Default local destination. `nil` means `default-directory` of the buffer the
command was invoked from.

```elisp
(defcustom jsonyter-remote-confirm-delete t ...)
```

Follow the existing docstring style in `jsonyter.el`: state what the value
means, then when you would change it.

## 4. Session state

Extend the session struct with:

- `contents-dir` — the kernel's cwd as a contents path, or `nil`.
- `contents-dir-probed` — whether the probe has run (so a `nil` result is not
  retried on every command).
- `remote-directory` — the current directory in the browser, sticky per
  session, seeded from `contents-dir` and otherwise `""`.

Reset all three in `jsonyter--after-kernel-reset`: a restarted kernel may have
a different working directory, and a stale mapping is worse than none.

Probe lazily — on the first transfer command or the first `jsonyter-remote-dired`,
not at REPL start. It costs an `execute`, and most sessions never transfer a
file.

## 5. Commands

### `jsonyter-upload-file (local-path remote-path &optional overwrite)`

Interactively: `read-file-name` for the local side, then a remote path read
with completion (§7), defaulting to the session's `remote-directory` plus the
local basename. `C-u` sets `overwrite`.

In a `dired` buffer, default the local side to the file at point.

### `jsonyter-download-file (remote-path local-path &optional overwrite)`

The mirror. Default the local side to `jsonyter-download-directory` plus the
remote basename.

### `jsonyter-dired-upload-marked`

Bound in `dired-mode-map` (behind a `jsonyter-dired-setup` the user opts into,
rather than an unconditional global binding). Uploads
`dired-get-marked-files` into a remote directory read once, sequentially —
**not** concurrently. The bridge serialises REST work across four workers, and
saturating them with uploads would stall unrelated calls.

### `jsonyter-resume-upload` / `jsonyter-resume-download`

Re-issue the last failed transfer with `resume: t`. Keep the last failure's
parameters in a buffer-local variable; if there is none, say so rather than
prompting from scratch.

## 6. Asynchrony and progress

Transfers use `jsonyter--send` (never `jsonyter--request-sync`): a large upload
can run for minutes and must not block Emacs.

Add a `:progress` handler to the `jsonyter--send` handlers plist and one branch
to `jsonyter--dispatch` for the `progress` key, alongside the existing
`output`, `input_request` and `event` branches.

Render with a `progress-reporter`, plus a mode-line indicator in the REPL
buffer, since a transfer started from a `dired` buffer should still be visible
from the session it belongs to. Reuse `jsonyter--mode-line-string`'s existing
status-tag machinery rather than adding a parallel mechanism.

Show bytes and percentage, not chunk counts — chunk numbers are an
implementation detail of the transport:

```
Uploading trials.csv… 24.0 MB / 184.3 MB (13%)
```

On completion, one message naming both ends and the verification level:

```
trials.csv → data/trials.csv (184.3 MB, sha256 verified, 41s)
```

When the bridge reports `"verified": "size"`, say `size verified only` — the
user should know which guarantee they got without having to ask.

## 7. Remote path completion

A `completing-read` whose collection is filled from `list_contents` on the
current directory, re-fetched when the input ends in `/`. Directories complete
with a trailing slash so descending is a single `TAB`.

This is deliberately not a full `completion-table-dynamic` over the whole
tree — one listing per directory, on demand. Anything cleverer means a lot of
round trips against a server that may be on the far side of a slow link.

## 8. `jsonyter-remote-dired`

A `tabulated-list-mode` buffer named `*jsonyter-remote: <server>*`, one per
session, showing `list_contents` output.

Columns: name (directories suffixed `/` and faced distinctly), size
(human-readable), modified. The listing already carries `writable`, so render
a non-writable entry in a dimmed face — better than discovering it at the
point of failure.

| Key | Action |
| --- | --- |
| `RET` | Descend into a directory; on a file, download it |
| `^` | Up one directory |
| `g` | Refresh |
| `U` | Upload a local file here |
| `D` | Download the file at point |
| `R` | Rename / move (`rename_contents`) |
| `C` | Copy on the server (`copy_contents`) |
| `+` | Create a directory (`make_directory`) |
| `d` / `x` | Mark for deletion / execute, confirming per `jsonyter-remote-confirm-delete` |
| `q` | Bury |

Two details worth getting right:

- `copy_contents` lets the **server** pick the destination name — it appends
  `-Copy1` and so on. Read the name back from the returned model and report it;
  do not display the name the user typed.
- Sorting is `tabulated-list-mode`'s own, but seed it with directories first,
  then name — the order people expect from `dired`.

## 9. Errors

The bridge sends structured errors (`path`, `expected_hash`, `actual_hash`,
`reason`). Extend `jsonyter--error-message` to render them, and let `reason`
drive the offered recovery:

- `exists` → offer `C-u` to overwrite.
- `stale` → offer to download the server's copy first; show both digests
  abbreviated to 4 hex characters, not in full.
- A proxy error (the bridge marks these; a 413 or 524 carrying `cf-ray` is not
  the Jupyter server talking) → name `jsonyter-upload-chunk-size` and its
  current value. This is the same shape as the existing 401/403 special case:
  a bare "Request Entity Too Large" tells the user nothing about which knob
  fixes it.

Always report the byte offset a failed transfer reached, and mention
`jsonyter-resume-upload` when resuming is possible.

## 10. Documentation

Add a `## Transferring files` section to `README.md`, after the notebook
section. It needs: the contents-path-vs-kernel-path distinction stated once
and plainly, the keymap table from §8, and a short note that
`jsonyter-upload-chunk-size` is the knob to reach for behind a proxy with a
body-size limit.

Add the new methods to the method table around line 398.

## 11. Tests

Extend `test/jsonyter-tests.el` with a stubbed bridge:

- `jsonyter--dispatch` routes a `progress` line to the `:progress` handler and
  does not mistake it for a `result`.
- The progress reporter reaches 100% and is cleaned up when a transfer errors
  partway, not only on success.
- Remote path completion appends `/` to directories and re-fetches on descent.
- `remote-dired` renders a non-writable entry dimmed, and reports the
  server-chosen name after a copy rather than the requested one.
- `jsonyter--error-message` renders each `reason` with its recovery hint, and
  the proxy-error branch names the chunk-size variable.
- Session state resets `contents-dir` on kernel restart.

The `harness/` profile drives a real graphical Emacs; add scenarios there for
the interactive paths — a full upload with visible progress, and a conflict
that surfaces the overwrite prompt — since those are exactly the paths a batch
test cannot see.
