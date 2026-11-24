# Proposal

## Why

Issue 21: in a rendered notebook, `forward-word` and `backward-word` do not
move word by word inside a markdown cell, raw cell or rendered output
block. They run through the whole span to the next code cell, or to the
start or end of the document, and `kill-word` there deletes the rest of the
cell and the first word of the code cell below it.

The cause is `jsonyter--nb-inert-syntax-table`, put on every non-code span
so prose and output cannot open a string, comment or pair for `syntax-ppss`:
it made every character except whitespace punctuation, letters and digits
included, so the span has no word boundary for word motion to stop at.

## What Changes

- The inert syntax table keeps letters and digits as word constituents:
  the ASCII word characters of the buffer's own syntax table, and every
  other character the standard syntax table calls a word constituent
  (accented letters, CJK).
- Everything else stays punctuation, and whitespace and comment-end keep
  the language's own entries, as before.

Surfaces affected: notebook (.ipynb) buffers, all kernel languages. Script
cells and Org keep text in the document's own syntax and are unaffected. No
bridge protocol change.

## Capabilities

### New Capabilities
- `notebook-text-motion`: how word-wise motion and editing behave across a
  notebook's cell kinds.

### Modified Capabilities

## Impact

- `jsonyter-notebook.el`: `jsonyter--nb-inert-syntax-table`.
- `test/jsonyter-tests.el`: the syntax-contract test now allows word
  syntax for letters and digits; new word-motion tests.
- `README.md`: a sentence in the notebook section.
