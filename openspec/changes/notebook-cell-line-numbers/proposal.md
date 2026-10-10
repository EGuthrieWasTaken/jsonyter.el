# Proposal

## Why

With `display-line-numbers-mode` on, a notebook buffer's line numbers read as
inconsistent, because Emacs numbers the *rows of a rendered view*, not the lines
of anything the user is editing:

- A cell's prompt is an overlay `before-string` that contains newlines (a blank
  spacer row, then the label). Emacs puts the number of a logical line on the
  first screen row of that line, so the number for a cell's first source line
  lands on the blank row *above* the label while the line's own text row has none.
  Every later line of the cell is numbered normally, so each cell starts one row
  out of step.
- A cell's output is real buffer text, so its frame rules, text rows and each row
  of a sliced image are numbered too. A tall plot burns twenty numbers.
- The numbers count rows of the view and so match neither the cell nor the
  `.ipynb` file, and they shift by the length of every output above.

Jupyter's own editors number a cell's lines from 1 within the cell. That is the
meaningful number here: it names a line of the code the user is working on.

## What Changes

- New user option `jsonyter-notebook-line-numbers`: `cell` (default) or `buffer`.
- With `cell`, in a notebook buffer where the user has line numbers on, Emacs's
  own numbers are replaced by per-cell numbers: every source line of every cell
  is numbered from 1 within its cell, on the row that shows its text; prompts,
  output and image rows carry none. Wrapped lines stay aligned under their text.
- With `buffer`, nothing changes from today: Emacs's own numbering is left alone.
- Per-cell numbers are display-only: they never enter a cell's source, a saved
  file, the undo history, the modified flag or the kill ring.
- Behavior change for users with line numbers on: notebooks now show per-cell
  numbers unless `buffer` is chosen. Users with line numbers off, or with
  `relative` or `visual` numbering (which are not emulated), see no difference.

Surfaces affected: notebook (.ipynb) buffers only; all kernel languages. REPL,
`# %%` script and Org buffers are untouched. No bridge protocol change; minimum
bridge version unchanged.

Not addressed: the reported "inserting newlines hangs Emacs" symptom, which could
not be reproduced and needs a backtrace from an affected setup.

## Capabilities

### New Capabilities
- `notebook-line-numbers`: how line numbers are shown beside a notebook cell's
  source.

### Modified Capabilities

## Impact

- `jsonyter.el`: one defcustom, a small "per-cell line numbers" section (a
  `jit-lock` function, an edit tracker, a sync function on
  `display-line-numbers-mode-hook`, a copy filter), an optional gutter argument
  on `jsonyter--nb-prompt`, and hooks from `jsonyter--nb-refresh-prompt`,
  `jsonyter--nb-stale-after-change` and `jsonyter-notebook-mode`.
- `test/jsonyter-tests.el`: new headless tests.
- `harness/`: a graphical scenario for what appears on screen.
- `README.md`: a "Line numbers" section and the option.
