# Design

## Context

A notebook buffer is one buffer of three kinds of text: cell source, rendered
output (real, read-only text after the source) and, as overlay strings, the
prompts. Each cell is an overlay tiling the buffer; `jsonyter-source-end` splits
its source from its output. Emacs's `display-line-numbers` numbers logical lines,
so everything above follows from what the buffer holds. Source lines are exactly
the lines between a cell overlay's start and its `jsonyter-source-end`.

Three Emacs facts the design rests on, each checked in Emacs 29.3 (batch, or an
Xvfb frame) rather than assumed:

1. The first screen row of a logical line is where its `line-prefix` goes. For a
   cell's first source line that row is the prompt's blank spacer row.
2. `wrap-prefix` is applied only to rows produced by genuinely wrapping a line,
   not to the rows an overlay string creates with its own newlines. So a
   `wrap-prefix` on the first line indents its wrapped continuation rows without
   indenting the prompt label or doubling a number.
3. `jit-lock-register` switches `jit-lock-mode` on by itself and calls the
   function for each chunk about to be displayed; `jit-lock-refontify` re-runs
   only the flushed range. A `line-prefix` text property is copied into the kill
   ring (it is not in `yank-excluded-properties`).

## Goals / Non-Goals

**Goals:**
- A line number names a line of a cell's source, counted within the cell, on the
  row that shows that line.
- Correct after any edit, without work proportional to the notebook's size on
  each keystroke.
- No effect on what is saved, undone, copied or considered modified.
- The old behavior stays available.

**Non-Goals:**
- No emulation of `relative` or `visual` numbering, of the current-line number
  highlight, or of `display-line-numbers-width` / `-widen`.
- No change to script, Org or REPL buffers, whose line numbers are real.
- No change to how cells, prompts or outputs are rendered beyond a number at the
  end of the prompt string.

## Decisions

- **Numbers are `line-prefix` text properties set by a `jit-lock` function, with
  the first line's number carried by the prompt string.** Lines 2..n get
  `line-prefix` (the number) and `wrap-prefix` (blanks of the same width); line 1
  gets `wrap-prefix` only, and its number is the tail of the cell's prompt
  `before-string`, which is displayed on line 1's own text row. Prefixes take no
  buffer columns, so `current-column`, `move-to-column` and indentation behave as
  before, and the cursor sits after the number.
  Alternatives considered:
  - *Keep Emacs's numbers and move each prompt to the end of the previous line
    (an `after-string` on an empty overlay).* Rejected: typing at the end of the
    line before a cell would put the prompt ahead of the typed character unless
    the overlay is rear-advancing, in which case it grows over whatever is typed
    (verified in batch). It also needs a special case for the first cell and
    reopens the overlay bookkeeping `notebook-cell-integrity` just settled.
  - *One overlay with a margin or `before-string` per line.* Rejected: creates and
    reaps an overlay per line, needs window-margin management (margin form), or
    shifts text and confuses the cursor (inline form).
  - *Eagerly set properties on every line.* Rejected: work proportional to
    notebook size on open and on every renumbering; `jit-lock` does it for the
    visible lines only.
- **Gutter width is per cell**: digits of the cell's line count, at least two,
  followed by one space. The width is a function of the cell alone so a cell moves
  between positions or notebooks without renumbering other cells.
- **Edit tracking compares line counts.** The after-change hook already visits
  the cells containing the change (to re-judge staleness). For each it recounts
  lines in the source and compares with the count stored on the overlay. If the
  count is unchanged, `jit-lock`'s own handling of the edited lines is enough. If
  it changed, the cell's lines from the edited line to the end of its source are
  flushed with `jit-lock-refontify` (lazy: only what is on screen is recomputed).
  If the digit count changed too, the cell's prompt is redrawn and the whole
  source is flushed, since every line's prefix width changed.
- **Surgery paths use the same update.** The tracker stands down during cell
  surgery, so the places that change a cell's source under surgery
  (`jsonyter--nb-adopt-stray-text`, and `jsonyter--nb-make-cell` through its
  prompt refresh) call the update themselves. Cell moves carry the text and its
  properties together and redraw both prompts, which recount.
- **Intent is read from `display-line-numbers-mode`.** Per-cell numbers are shown
  only while that minor mode's variable is non-nil and the buffer's
  `display-line-numbers` is `t` (absolute). A buffer-local function on
  `display-line-numbers-mode-hook` re-syncs whenever the mode is toggled by hand
  or by `global-display-line-numbers-mode`: it runs after the mode has set
  `display-line-numbers`, so setting it back to nil there takes effect. The option
  is read on each sync, so customizing it and toggling the mode applies it to an
  open notebook.
- **Copy filter.** A buffer-local `:filter-return` on
  `filter-buffer-substring-function` strips `line-prefix` and `wrap-prefix` from
  killed or copied text, so pasting source elsewhere does not carry numbers along.
  This works on Emacs 27.1, unlike `kill-transform-function`.
- **Teardown.** Turning `jsonyter-notebook-mode` off removes the hook, the filter
  and the jit-lock function, strips the properties from source text, redraws the
  prompts without the tail and re-enables Emacs's own numbering if the user's
  mode is on.

## Risks / Trade-offs

- While active, jsonyter owns `line-prefix` and `wrap-prefix` on source text. A
  package that sets them on the same text (for instance `adaptive-wrap-prefix-mode`
  on prose) will fight it. Documented; the `buffer` setting is the escape hatch.
- Per-cell numbers replace absolute numbering the user may have been relying on
  to jump with `goto-line`. `M-g g` still works on buffer lines but no longer
  matches what is displayed. Users who want that choose `buffer`.
- Setting `display-line-numbers` directly with `setq-local` (not through the
  mode) after a notebook is open is not tracked; the mode hook is the contract.
- A cell with thousands of lines pays an O(cell) line count per keystroke. The
  staleness tracker already hashes the whole cell source per keystroke, so this
  does not change the order of the cost.

## Open Questions

None; decisions taken: markdown and raw cells are numbered like code cells (the
buffer shows all three as editable text), and `relative`/`visual` types are left
to Emacs.
