# Proposal

## Why

Markdown cells in a notebook routinely hold math (`$x^2$`, `$$\int f$$`,
`\begin{align}...`). In a Jupyter front end it renders; in a jsonyter notebook
buffer it is raw TeX source, so reading a mathematical notebook means decoding
it by eye. jsonyter already carries a managed LaTeX-macros cell and a
`jsonyter-notebook-latex-macros` option, so the notebook already assumes the
reader's math is meant to be *seen*.

## What Changes

- New command `jsonyter-notebook-latex-preview-toggle` (bound to `C-c C-v`)
  shows the math in the markdown cell at point as inline images, or removes the
  images if they are showing; with a prefix argument it acts on every markdown
  cell. Companion commands `jsonyter-notebook-latex-preview` and
  `jsonyter-notebook-latex-preview-clear` do each half.
- Fragments are found in markdown source only: `$...$`, `$$...$$`, `\(...\)`,
  `\[...\]` and `\begin{equation|align|gather|multline|eqnarray|flalign}...`
  (starred forms included), never inside backtick code spans or fenced code
  blocks, and never as the currency in "costs $5 and $6".
- Each fragment is typeset with the user's own `latex` and converted with
  `dvipng` (or `dvisvgm`), then shown by an overlay `display` image on top of
  the fragment's own text. The text is never changed, so saves stay lossless.
- The macros from `jsonyter-notebook-latex-macros` are part of every fragment's
  preamble, so `\R`, `\E` and friends render; the managed macros cell itself is
  skipped.
- Images are cached by content, so re-previewing an unchanged fragment costs
  nothing; editing a fragment removes just its image.
- Missing tools give a plain `user-error` naming what to install, never a
  stack trace; a fragment LaTeX rejects is left as text with a message naming
  the first TeX error.
- Opt-in `jsonyter-notebook-latex-preview-on-open` previews every markdown cell
  when a notebook opens.

Surfaces affected: notebook (.ipynb) buffers only; all kernel languages
equally (it is about markdown cells). No bridge protocol change; the bridge is
not involved. New external requirement, optional and only for this command:
`latex` plus `dvipng` or `dvisvgm` on `exec-path` of the machine running Emacs.

## Capabilities

### New Capabilities
- `notebook-latex-preview`: finding math in markdown cells and showing it
  typeset, in place, without altering the notebook.

### Modified Capabilities

## Impact

- `jsonyter.el`: a new "LaTeX preview" section (about a dozen small private
  functions, three commands, five options), one binding, one line in
  `jsonyter-notebook-open`.
- `test/jsonyter-tests.el`: new tests; a real-TeX test skips without
  `latex`/`dvipng`.
- `README.md`: new section and key table row.
