# Tasks

## 1. Command

- [x] 1.1 Add `jsonyter-split-cell`: `jsonyter--nb-ensure-notebook`, then `jsonyter--nb-cell-at` guard (`user-error "No cell at point"` when nil, matching `jsonyter-notebook-run-cell`'s existing message), then a distinct error when point is past the cell's `jsonyter-source-end`; verify with a test for each of the two error cases leaving the buffer unchanged
- [x] 1.2 Implement the split itself (read source and cell-type, excise the cell, `jsonyter--nb-put-cell` the upper half at the old start, `jsonyter--nb-put-cell` the lower half at the upper cell's `overlay-end`); verify a mid-source split produces two cells with the expected source, type, and point at the lower cell's start
- [x] 1.3 Verify splitting at the exact start and at the exact end of a cell's source each produce one empty cell and one cell with the full original source
- [x] 1.4 Verify splitting a cell that has stored output and an execution count leaves neither resulting cell with output, an execution count, or the original cell's id
- [x] 1.5 Verify splitting works the same way for markdown and raw cells (type preserved, same shape)

## 2. Tests, docs, release

- [x] 2.1 Full ERT suite green apart from the known `kernel-activity-formats-or-falls-back` failure
- [ ] 2.2 Harness scenario driving a real graphical Emacs: place point mid-cell, run `jsonyter-split-cell`, confirm two cells render with the expected prompts/boundaries on screen -- NOT RUN: no `emacs-harness` checkout or graphical display in this session; the ERT suite in 1.1-1.5 covers the same behavior at the buffer-state level
- [x] 2.3 README: document `jsonyter-split-cell` alongside the existing insert-above/below/prune cell-editing commands; verify the text
- [x] 2.4 `;; Version:` bumped once in the release step of the overall run
