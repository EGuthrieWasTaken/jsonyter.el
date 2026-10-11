# Design

## Context

A notebook buffer's cells are overlays (`make-overlay`, front/rear-advance nil,
`evaporate` nil) that tile the buffer back to back; each carries a
`jsonyter-source-end` marker splitting source from read-only output. Cell
surgery (`jsonyter--nb-insert-cell`, `--excise-cell`, `--swap-cells`, output
rewrites) binds `jsonyter--nb-cell-surgery` so the after-change hook stands
down. Reproduced headlessly: `revert-buffer` stacks one zero-length overlay per
old cell at `point-min`; typing at `point-max` lands outside every overlay
(rear-advance nil); backspacing an empty cell's newline leaves a zero-length
cell. 150 random seeds of interior edits (RET, typing, insert, delete, toggle)
found no other invariant violation.

## Goals / Non-Goals

**Goals:**
- Invariant after every ordinary edit: no zero-length cell, no text outside
  the cells.
- Render is idempotent with respect to existing overlays.

**Non-Goals:**
- Undo of a deleted cell (the surgery already keeps its own history out of the
  undo list).
- Redisplay behavior (line numbers, hangs) -- tracked in other changes.

## Decisions

- **Heal in the existing after-change hook, not in `post-command-hook`.** It is
  already the single place that runs after every edit and already honors the
  surgery flag. A heal pass is cheap: one pass over the cell overlays and one
  comparison against `point-max`.
- **Adopt, don't forbid, text after the last cell.** Making the trailing region
  read-only would make `M->` then typing an error; adopting matches what the
  user plainly meant. Into the last cell when it shows no output (its source
  simply grows); into a new code cell when it has output, because source and
  output of one cell cannot be separated by user text.
- **Always end adopted text with a newline** so the "a cell owns its trailing
  newline" invariant keeps holding; the newline is inserted after point.
- **Prune treats "empty" as blank source and no output.** An empty-source cell
  that shows output is not empty. Prune goes through the existing
  `jsonyter--nb-excise-cell`, so it reuses the undo-trimming already there.
- **Small helpers, each independently testable:** `--nb-forget-cells`,
  `--nb-drop-empty-cells`, `--nb-adopt-stray-text`, `--nb-empty-cell-p`.

## Risks / Trade-offs

- Dropping a zero-length cell inside an edit hook could surprise code that
  holds its overlay → such code runs under the surgery flag, which skips the
  heal.
- A heal bug would run on every keystroke → the pass is bound to a handful of
  list operations and covered by the fuzz-style tests below.
