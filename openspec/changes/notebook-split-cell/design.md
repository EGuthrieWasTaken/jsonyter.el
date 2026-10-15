# Design

## Context

A cell is an overlay spanning source then rendered output, split by the
`jsonyter-source-end` marker (see `jsonyter--nb-cell-source`,
jsonyter.el:3479). `jsonyter--nb-cell-at` (jsonyter.el:3468) finds the cell
overlay covering point — or the position just before it, at end-of-buffer —
but that span covers source *and* output together, so finding a cell is
not the same as point being over its source.

Two existing primitives do the actual surgery and are reused as-is:
`jsonyter--nb-excise-cell` (removes a cell, source and output, no
questions asked) and `jsonyter--nb-put-cell` (jsonyter.el:4382 — inserts a
brand-new cell with given source at a position, id nil, outputs nil,
returning the new overlay with point left at its start). Both already bind
`jsonyter--nb-cell-surgery' for their own extent, so the after-change hook
that tracks output staleness stands down for each; see
`openspec/changes/notebook-cell-integrity/design.md` for that mechanism.
`jsonyter-notebook-insert-latex-macros` (jsonyter.el:4425) already composes
excise-then-put this same way to replace one cell's content wholesale.

## Goals / Non-Goals

**Goals:**
- One command, no prefix argument, matching exactly what was asked:
  `jsonyter-split-cell` splits the cell at point into an upper and lower
  cell.
- Reuse the existing surgery primitives rather than adding new overlay
  manipulation.

**Non-Goals:**
- Preserving the original cell's id on either half (see Decisions).
- A keybinding — this ships `M-x`-only, like `jsonyter-notebook-prune`,
  since that's what was asked for and no key was requested.
- Any special-casing for markdown/raw cells beyond carrying their
  `cell_type` through unchanged; splitting text makes as much sense for
  those as for code.

## Decisions

- **Point must resolve to an offset within the cell's *source*, not just
  land on the cell's overlay.** `jsonyter--nb-cell-at` alone isn't enough
  since its span includes read-only output; the command also checks
  `(<= (point) source-end)`, and errors distinctly when point is in a
  cell's output rather than reporting the same "no cell" message used when
  point is outside every cell — a user who put point in a rendered result
  and asked to split is not making the same mistake as one with point in
  the margin.
- **Splitting at the exact start or end of the source is allowed, not
  special-cased.** It produces one empty half, exactly like Jupyter's own
  split-cell at a boundary. No auto-prune: `jsonyter-notebook-prune`
  already exists as the explicit way to clear an empty cell, and calling
  it implicitly here would surprise a user who, e.g., meant to type into
  that empty half next.
- **Both halves are brand-new cells (no id, no output), not "the original
  cell, shrunk" for the upper half.** Considered keeping the original
  cell's id on the upper half, reusing its overlay directly instead of
  excising it — rejected: nbformat ids are opaque and Jupyter's own split
  doesn't guarantee continuity either, and reusing the overlay would need
  explicitly clearing `jsonyter-exec-count`, `jsonyter-raw-outputs`,
  `jsonyter-outputs-touched` and `jsonyter-file-outputs` by hand to avoid
  one half silently inheriting stale state — `jsonyter--nb-put-cell`
  already guarantees a clean cell for both halves at no extra cost.
- **Implementation is excise-then-put, exactly like
  `jsonyter-notebook-insert-latex-macros`.** Read the cell's full source
  and its start position, excise it, `jsonyter--nb-put-cell` the upper
  half at that position, then `jsonyter--nb-put-cell` the lower half at
  the upper cell's `overlay-end` — which is also where point ends up,
  satisfying "point starts at the lower cell" for free rather than an
  explicit `goto-char` after both calls.

## Risks / Trade-offs

- Splitting discards output even when the user only meant to split without
  touching results → acceptable and expected: nbformat has no notion of
  one output belonging to two cells, and Jupyter's own split-cell does the
  same.
- `jsonyter--nb-put-cell` inserts a newline-terminated block each call,
  temporarily creating a buffer state between the two calls where only the
  upper half exists and the lower source hasn't been inserted yet — no
  hook or redisplay runs in that gap since Emacs is single-threaded and
  both calls happen synchronously inside the same command.
