# Design

## Context

Org's own latex-preview machinery detects fragments with `org-element`, which is
meaningless in a notebook buffer (a Python major mode). The package already
renders into overlays with `display` images for outputs and has the managed
macros cell and `jsonyter-notebook-latex-macros`. Measured here: `latex` plus
`dvipng` render a display equation in about 0.16 s; `dvisvgm` is similar.

## Goals / Non-Goals

**Goals:**
- Preview math in markdown cells with the user's TeX, reliably, in place.
- Everything testable with no TeX installed (pure helpers; process calls
  stubbed), plus one real-TeX test that skips without it.

**Non-Goals:**
- Not previewing `text/latex` cell *outputs*, nor code-cell comments.
- Not async rendering: one fragment is ~0.16 s, previews are explicit, and a
  whole-notebook preview says how many it is rendering.
- Not Org's `org-latex-preview` (different fragment model, version drift from
  Org 9.4 to 9.7, needs an Org buffer).

## Decisions

- **Own small pipeline over reusing Org.** One `latex` run and one converter run
  per fragment in a temp directory; both are plain `call-process` calls, easy to
  stub. Alternative: `org-create-formula-image` from a temp Org buffer -- rejected
  for the version drift and the dependency on `org-latex-*` defcustoms that the
  user tuned for Org export, not for notebook math.
- **Fragment finding in layers.** `mask-code` blanks code spans and fences with
  same-length spaces so offsets still line up; one small finder per syntax
  (environments, `$$`, brackets, inline `$`) each returning offsets, each pass's
  matches blanked before the next so a `$$..$$` is never re-read as two inline
  dollars; `fragments` merges and sorts. Alternative: one giant regexp --
  rejected, unreadable and untestable.
- **Inline `$` rules** follow Pandoc/Jupyter: opening `$` not preceded by `\`,
  next character not whitespace; closing `$` not preceded by whitespace or `\`,
  not followed by a digit; never across a blank line.
- **Cache key = SHA-1 of document + converter + dpi + colour**; the file name is
  the key, so a cache hit is a `file-exists-p`.
- **Overlays carry `display`; text untouched.** Same technique as every other
  rendering here, so saves stay lossless. `modification-hooks` deletes the one
  overlay edited; `evaporate t` removes it if its text is deleted.
- **Image creation behind one helper** (`jsonyter--latex-image`) so batch tests
  without image support can stand in a string.

## Risks / Trade-offs

- A heavy notebook previews in seconds, blocking Emacs → per-cell by default;
  the whole-notebook form messages its progress and honours `C-g`.
- The inline-`$` heuristic can misjudge exotic text → it errs toward *not*
  previewing (currency, escaped dollars), and the source is always visible
  underneath on edit.
- A TeX distribution without `amsmath` fails every fragment → the first error
  line is shown, and `jsonyter-latex-preview-preamble` is customizable.
