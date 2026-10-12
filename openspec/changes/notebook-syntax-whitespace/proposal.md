# Proposal

## Why

The reporter's "inserting a newline hangs Emacs until `C-g`" was still happening
on 2.5.1 after a restart of the Emacs daemon. A CPU profile and a `debug-on-quit`
backtrace from their session both end in the same place, and neither mentions
jsonyter's overlays (one sample in about ten thousand; redisplay ten):

```
ess-skip-blanks-backward(t)      <- the quit landed here
ess-climb-token() ess-token-before() ess-ahead-continuation-p()
ess-calculate-indent--block-relatively() ess-calculate-indent() ess-r-indent-line()
indent-according-to-mode() electric-indent-post-self-insert-function()
newline() ess-roxy-newline()
```

So the 2.5.1 conclusion that the hang was the 2.4.1 reload bug was wrong for this
reporter: that bug is real and was measured, but it is not what they were hitting.

The hang is an endless loop, reproduced here with ESS 24.1.1 in an R notebook of
120 cells, and it is jsonyter's doing. Since 2.4.1 the syntax-propertize function
covers every character of a markdown or raw cell and of every rendered output with
punctuation syntax, newlines included, so that an apostrophe in prose cannot open
a string that swallows the rest of the notebook. ESS's `ess-skip-blanks-backward`
walks up a line at a time until point leaves the start of a line, and finds where
the line above ends with `forward-comment -1`, which moves only over whitespace
and comment ends. With the newline punctuation it cannot move, point comes back
to the start of the line it began on, and the loop never ends. Measured on 2.5.1:

| Command | Where | Result |
|---|---|---|
| RET | first line of a code cell, or its start | never returns (stopped after 40 s) |
| RET | in a markdown cell: its start, the end of its first line, the end of its last line | never returns |
| TAB | first line of a code cell | never returns |
| RET | middle or last line of a code cell | 1 ms |

Any code cell that follows another cell has prose or output above its first line,
so its first line is affected; so are the lines of a markdown cell.

## What Changes

- Text that is not kernel-language code still cannot open or close anything, but
  its whitespace keeps the language's own syntax: a character that the buffer's
  syntax table gives the whitespace or comment-end class (the space, the tab, the
  newline) keeps that entry.
- Tests: the syntax of whitespace in prose and output, a replica of the backward
  walk, and, where ESS is installed, RET on a cell's first line and in a markdown
  cell.
- The 2.5.1 change's claim that the reload bug confirmed the cause is corrected.
- `;; Version:` 2.5.2.

Surfaces affected: notebook (.ipynb) buffers only, every kernel language. Verified
with ESS only; other modes that find the end of the previous line with
`forward-comment` were not available to try. No bridge protocol change.

Not changed: the language's indentation rules still apply inside a markdown cell
(RET there runs the R or Python indenter on prose). That is a separate question
from the hang.

## Capabilities

### New Capabilities
- `notebook-syntax`: how the text of a notebook that is not code reads to the
  kernel language's syntax and indentation code.

### Modified Capabilities

## Impact

- `jsonyter.el`: `jsonyter--nb-syntax-propertize` uses a syntax table built by a
  new `jsonyter--nb-inert-syntax-table` in place of the constant
  `jsonyter--nb-inert-syntax`; version.
- `test/jsonyter-tests.el`: three tests and a replica of the backward walk.
- `README.md`: the version pins.
