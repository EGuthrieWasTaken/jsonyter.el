# Proposal

## Why

Splitting a cell in two — writing a second piece of logic or a new
paragraph under what's already there, or breaking up a cell that grew too
big — currently means select-and-cut-and-paste across a fresh
`jsonyter-insert-cell-below`. Jupyter's own notebook UI treats this as one
command; jsonyter.el has no equivalent.

## What Changes

- New command `jsonyter-split-cell`: splits the cell at point into
  two cells of the same type, at point, replacing the one cell with an
  upper cell (everything before point) and a lower cell (everything from
  point onward).
- Refuses with a clear error unless point is inside a cell's source text:
  no cell at point, or point sitting in a cell's (read-only) rendered
  output, both refuse rather than guessing a split point.
- Both new cells start with no id and no output — splitting discards
  whatever output the original cell had, since neither half's source
  produced it.

Surfaces affected: notebook (.ipynb) editing only; REPL, script cells and
Org/Babel untouched; all kernel languages and all three cell types (code,
markdown, raw) equally. No bridge protocol change, no change to the
minimum jsonyter bridge version.

## Capabilities

### New Capabilities
- `notebook-cell-editing`: the buffer-local commands that restructure a
  notebook's cells by hand (today: insert above/below, prune; this change
  adds split).

### Modified Capabilities

## Impact

- `jsonyter.el`: new command `jsonyter-split-cell`, built on the
  existing `jsonyter--nb-excise-cell` / `jsonyter--nb-put-cell` surgery
  primitives; no changes to those primitives themselves.
- `test/jsonyter-tests.el`: new tests.
- `README.md`: notebook cell-editing section.
