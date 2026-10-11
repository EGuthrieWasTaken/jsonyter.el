# Proposal

## Why

nbformat has three cell types: code, markdown and raw. A notebook buffer already
loads, shows (with its own "Raw" prompt and face), edits and saves an existing
raw cell, and the bridge writes one correctly (checked against jsonyter 2.1.1).
But nothing in the UI can *make* one: `jsonyter-toggle-cell-type` only flips
between code and markdown, and the insert commands take a prefix argument that
means "markdown or code". A user who needs a raw cell (for example a LaTeX or
reST passthrough for nbconvert) has to edit the JSON by hand.

## What Changes

- `jsonyter-toggle-cell-type` cycles code -> markdown -> raw -> code.
- New command `jsonyter-set-cell-type` sets the cell at point to a type chosen
  with completion (code, markdown or raw).
- `jsonyter-insert-cell-above` / `-below`: `C-u` keeps meaning markdown,
  `C-u C-u` inserts a raw cell; Lisp callers may also pass a type string.
- Changing a cell to markdown or raw drops its output and execution count (as
  markdown already did); the cell's text is re-fontified and its syntax state
  refreshed so a former code cell stops being highlighted as code.

Surfaces affected: notebook (.ipynb) buffers only; all kernel languages. No
bridge protocol change; the bridge already writes raw cells.

## Capabilities

### New Capabilities
- `notebook-cell-types`: how a notebook buffer's cells are created and changed
  between the three nbformat cell types.

### Modified Capabilities

## Impact

- `jsonyter.el`: `jsonyter-toggle-cell-type`, `jsonyter-insert-cell-above`,
  `jsonyter-insert-cell-below`; four new private/public definitions.
- `test/jsonyter-tests.el`: new tests (one bridge-backed save test, skipped
  without the bridge).
- `README.md`: notebook key table and cell-type text.
