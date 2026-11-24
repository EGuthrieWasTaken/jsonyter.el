# Proposal

## Why

Issue 22: RET at the start of an R cell reportedly inserts about a hundred
spaces. The symptom was not reproduced, but the report's setup (a language
server started in every `ess-r-mode` buffer) exposed two real defects:

1. A cell's output is written into the buffer with
   `with-silent-modifications`, which skips `before-change-functions` and
   `after-change-functions`. `lsp-mode` and `eglot` keep the server's copy
   of the buffer up to date from exactly those hooks, so after a cell ran,
   the server's copy was shorter than the buffer by the output's height.
   Every later keystroke was sent at line numbers the server's copy did not
   have, and on-type formatting asked about lines that did not exist.
2. `syntax-ppss` parses from the top of the buffer through every earlier
   cell, so a code cell that ends inside a bracket or in the middle of a
   statement made the next cell's first lines indent as continuation lines.

## What Changes

- Writing or removing a cell's output reports the replacement to the
  change hooks (`before-change-functions` with the old region,
  `after-change-functions` with the new end and old length), while still
  staying out of the undo list and the modified flag. A hook that signals
  is reported and skipped.
- Indentation runs with the buffer narrowed to the code cell's own source,
  as an `:around` advice on the buffer-local `indent-line-function`, so
  each cell is indented as a file of its own.
- README documents how to keep a language server out of notebooks.

Surfaces affected: notebook (.ipynb) buffers; ESS/R and every other
language mode. No bridge protocol change.

## Capabilities

### New Capabilities
- `notebook-change-tracking`: what the buffer's change hooks and indentation
  see of a notebook.

### Modified Capabilities

## Impact

- `jsonyter-notebook.el`: `jsonyter--nb-silent-replace`,
  `jsonyter--nb-show-output-as-text`, `jsonyter--nb-excise-cell`,
  `jsonyter--nb-indent-line-in-cell`, the notebook mode body.
- `test/jsonyter-tests.el`: a mirror-of-the-buffer tracker and indentation
  tests.
- `README.md`: language-server section.
