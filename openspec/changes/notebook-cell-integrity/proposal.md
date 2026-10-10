# Proposal

## Why

Three reports about a rendered notebook buffer share one root: the cell
overlays stop matching the notebook.

1. **Phantom empty cells at the top.** After `revert-buffer` (or any
   re-render of an already-open notebook) the old cell overlays survive
   `erase-buffer` as zero-length overlays at the top of the buffer. A
   3-cell notebook shows 6 cells after one revert, 9 after two: the real cells
   plus an empty duplicate of each, every one drawing its own prompt.
2. **Edits at the bottom vanish.** Text typed (or RET pressed) after the last
   cell's final newline — where `C-n` and `M->` land — is outside every cell's
   overlay, so it is never saved and nothing says so.
3. **Empty cells linger.** Backspacing over an empty cell's newline leaves a
   zero-length cell, and there is no command to clear blank cells out of a
   notebook.

## What Changes

- Re-rendering a notebook first discards the cells it is replacing, so a
  render always yields exactly the notebook's cells.
- After every ordinary edit, the buffer heals itself: zero-length cells are
  dropped, and text left after the last cell is brought into a cell (the last
  cell itself when it shows no output, else a new code cell).
- New command `M-x jsonyter-notebook-prune` deletes every empty cell (blank
  source and no output), reports how many, and never empties the notebook
  entirely.

Surfaces affected: notebook (.ipynb) buffers only; REPL, script cells and
Org/Babel untouched; all kernel languages equally. No bridge protocol change.

## Capabilities

### New Capabilities
- `notebook-cell-integrity`: the guarantee that a notebook buffer's cells always
  cover exactly the text the user sees and edits, plus the command that clears
  empty cells.

### Modified Capabilities

## Impact

- `jsonyter.el`: `jsonyter--nb-render`, `jsonyter--nb-stale-after-change`, four
  new private helpers, one new command.
- `test/jsonyter-tests.el`: new tests.
- `README.md`: notebook section (prune command; bottom-of-buffer behavior).
