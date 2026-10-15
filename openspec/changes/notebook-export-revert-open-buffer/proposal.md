# Proposal

## Why

`M-x jsonyter-notebook-export` writes a fresh render to `TO-PATH` on every
call — verified directly: editing a cell's source, or re-running a cell to
produce different output, between two export calls produces two different
requests to the bridge, every time. But if a buffer in this Emacs session is
already visiting that export's destination file (export once to
`analysis.html`, open `analysis.html` to check it, edit the notebook, export
to `analysis.html` again), nothing tells that buffer to re-read the file
Emacs just overwrote. It keeps showing what it last read, which looks
exactly like "the export returned the same result" even though the file on
disk is correct.

## What Changes

- After a successful export, any live buffer visiting the path(s) the
  bridge actually wrote — the bundle's own resource files included, not
  just `TO-PATH` — is reverted so it displays what was just written.
- A buffer with unsaved changes of its own is never silently clobbered:
  reverting goes through the usual `revert-buffer` confirmation for a
  modified buffer, same as reverting it by hand would.
- No buffer is visiting the path → no behavior change; this never creates a
  new buffer or otherwise changes what `jsonyter-notebook-export` returns or
  messages.

Surfaces affected: notebook (.ipynb) export only (`jsonyter-notebook-export`
and its format-specific wrappers); REPL, script cells and Org/Babel
untouched; all kernel languages equally. No bridge protocol change, no
change to the minimum jsonyter bridge version.

## Capabilities

### New Capabilities
- `notebook-export`: what `jsonyter-notebook-export` does in Emacs once the
  bridge has written the file, so the editor's own view of a just-exported
  file is never stale.

### Modified Capabilities

## Impact

- `jsonyter.el`: `jsonyter-notebook-export`'s `on-success` handler; one new
  private helper to find and revert live buffers for a set of written paths.
- `test/jsonyter-tests.el`: new tests.
- `README.md`: one sentence in "Exporting notebooks".
