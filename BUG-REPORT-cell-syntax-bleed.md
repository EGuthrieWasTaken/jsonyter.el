# Bug report: one cell's punctuation re-colours the rest of the notebook

**Status:** fixed
**Date:** 2026-09-18
**Affects:** `jsonyter.el` 2.4.0 (this repo)
**Verified against:** GNU Emacs 29.3 (`-Q --batch`)
**Severity:** visual, but unbounded in reach — a single character can change
the colour of every cell below it, to the end of the buffer
**Tests added:** `test/jsonyter-tests.el`, section "Font lock: a cell's syntax
must stop at the cell" (3 tests, all originally `:expected-result :failed`;
the marker is now removed from all 3 — see §7)

---

## 0. Summary

A notebook buffer holds three kinds of text — code-cell source, non-code
(markdown/raw) cell source, and rendered output — under **one** major mode and
therefore one syntax table.

`jsonyter--nb-fontify-region` and `jsonyter--nb-unfontify-region` confine which
regions font-lock is allowed to *paint*. Nothing confines what the parser is
allowed to *read*. `font-lock-default-fontify-region` resolves string and
comment state through `syntax-ppss`, which parses from `point-min` straight
through every intervening character — prose and rendered output included.

So one unbalanced string, comment or math delimiter anywhere in the buffer
changes the fontification of everything after it. Which characters do it
depends on the mode `jsonyter-notebook-language-modes` picked:

| notebook language | mode | characters that re-colour what follows | verified here |
| --- | --- | --- | --- |
| python | `python-mode` | `'` `"` `"""` (run to the next match, possibly the end of the buffer); `#` (to end of line) | yes |
| (a `latex-mode` or `octave-mode` mapping) | `latex-mode`, `octave-mode` | `%` to end of line; `$` … `$` math spans | yes |
| r | `ess-r-mode` | `'` `"` `` ` ``; `%...%` operator pairs | no — ESS not installed in this environment |
| sas | `SAS-mode` | `'` `"`; `%` macro prefix; `$` informat prefix | no — `SAS-mode` not installed in this environment |

The last two rows are stated from those modes' syntax tables, not from a run;
confirm them before relying on them. The mechanism does not depend on which
row you are in.

Three distinct manifestations, all reproduced below.

---

## 1. Manifestation A — prose in a markdown cell re-colours the code below it

### 1.1 Reproduction

A two-cell Python notebook:

```json
{"cells": [
  {"cell_type": "markdown", "id": "aaa", "metadata": {},
   "source": "Here's the 50% discount.\n"},
  {"cell_type": "code", "id": "bbb", "execution_count": null,
   "metadata": {}, "outputs": [], "source": "import os\n"}],
 "metadata": {"kernelspec": {"language": "python", "name": "python3",
                             "display_name": "Python 3"}},
 "nbformat": 4, "nbformat_minor": 5}
```

Open it, `M-x font-lock-ensure`, then read the `face` property across the
buffer:

```
nil                     "Here"
font-lock-string-face   "'s the 50% discount.\nimport os\n"
```

The apostrophe in *Here's* — ordinary English, in a cell that contains no code
— opens a Python string. It never closes, so `import os` in the following
**code** cell is string-faced, and so is every cell after that, to the end of
the notebook.

Nothing about this is specific to the apostrophe. A markdown cell containing
`"` behaves the same; one containing `"""` doc-faces the rest of the buffer;
one containing a stray `#` comments out the remainder of its line.

### 1.2 Test added

`jsonyter-test-markdown-prose-does-not-bleed-into-next-cell`

---

## 2. Manifestation B — a cell's *output* re-colours the next cell

This is the worse one, because output is not something the user typed and not
something they can fix by editing.

### 2.1 Reproduction

One code cell whose stored output is `it can't be found`, then another code
cell:

```
font-lock-builtin-face        "print"
nil                           "(msg)\n"
jsonyter-output-border-face   "output ────────────────────────────────────…\n"
nil                           "it can't be found\n"
jsonyter-output-border-face   "──────────────────────────────────────────────\n"
font-lock-string-face         "import os\n"        <-- the next cell's SOURCE
```

The output block itself keeps its own faces — `jsonyter--nb-fontify-region` is
doing its job, and `jsonyter-test-font-lock-leaves-output-alone` correctly
passes. But `syntax-ppss` read the apostrophe in `can't` on its way past, so
the parser believes a string is open when it reaches the next cell's source.

The class of output that triggers this is not exotic: a printed sentence with
an apostrophe, a `repr` containing a single quote, a traceback quoting a
filename, a `print("she said \"hi\"")`. Re-running one cell can silently
re-colour every cell below it.

Note what this means for a fix: suppressing *painting* is not enough, because
painting was never the problem. The parser has to be prevented from seeing
these characters at all.

### 2.2 Test added

`jsonyter-test-rendered-output-does-not-bleed-into-next-cell`

---

## 3. Manifestation C — prose is coloured as code

Even with nothing unbalanced, a markdown cell's text is fontified with the
kernel language's keywords and operators, because there is only one major mode
in the buffer:

```
nil                       "Costs $5 "
font-lock-keyword-face    "and"
nil                       " 50"
font-lock-operator-face   "%"
nil                       " of it.\n"
```

`and` is English; `%` is a percent sign. Both are coloured as Python. With a
`latex-mode` or `octave-mode` mapping the same sentence comes out with `%` and
everything after it in `font-lock-comment-face` and `$…$` spans in `tex-math`
— which is the literal `%` and `$` symptom from the report.

This one is a design decision as much as a defect: markdown cells arguably
want *markdown* highlighting rather than none. Highlighting them as the kernel
language is the one answer that is clearly wrong, which is what the test
asserts; a fix is free to satisfy it either way.

### 3.1 Test added

`jsonyter-test-markdown-cell-source-is-not-fontified-as-code`

---

## 4. Root cause

```
jsonyter.el:4049   (setq-local font-lock-fontify-region-function
                               #'jsonyter--nb-fontify-region)
jsonyter.el:4051   (setq-local font-lock-unfontify-region-function
                               #'jsonyter--nb-unfontify-region)
```

Both are built on `jsonyter--nb-map-source-runs` (`jsonyter.el:3178`), which
walks the buffer skipping the rendered-output spans and calls
`font-lock-default-fontify-region` on each run of source in between. That is a
correct and complete solution to the problem it was written for — output text
keeping the renderer's own colours — and its docstring says so:

> A cell's output is buffer text, so the notebook language's own font-lock
> would otherwise read a traceback or a printed string as code: it strips the
> `face` properties the renderer put there … Only the source between the
> outputs is handed on.

What it cannot do is stop `font-lock-default-fontify-region` from calling
`syntax-ppss` on the run it *is* given, and `syntax-ppss` parses forward from
`point-min` (or from the last cached parse point), through the skipped spans,
because they are ordinary buffer text carrying ordinary syntax classes. The
`face` property is per-character and can be withheld; the syntax class is a
property of the buffer's syntax table and is not.

There is no `syntax-propertize-function` set in `jsonyter-notebook-mode`, and
no `syntax-table` text property applied to output text or to non-code cell
source.

---

## 5. Fix direction

Not prescriptive, but the shape of the fix follows from §4: the buffer's
*syntactic* view has to be partitioned the same way its *visual* view already
is.

1. **Install a `syntax-propertize-function`** in `jsonyter-notebook-mode` that
   runs over the region and, for every rendered-output span
   (`jsonyter--nb-output-spans` already computes them) and every non-code
   cell's source, puts a `syntax-table` text property of punctuation class
   `(1)` — or whitespace `(0)` — on each character that would otherwise open or
   close a string, comment or paired delimiter. Neutralizing only the
   delimiters is cheaper than blanketing every character, but blanketing is
   simpler and output spans are rewritten wholesale anyway.

   `parse-sexp-lookup-properties` must be non-nil for these to take effect;
   most programming modes set it, but do not rely on it — set it buffer-locally.

2. **Invalidate correctly.** `jsonyter--nb-show-output-as-text` rewrites an
   output region under `with-silent-modifications`, which does *not* run
   `syntax-ppss-flush-cache`. Any fix has to flush the cache from the start of
   the rewritten region, or a cell re-run will leave stale parse state behind.

3. **Decide about non-code cells** (§3). Either give markdown/raw cells inert
   syntax and no font-lock at all — which falls out of step 1 for free — or
   fontify them with a markdown mode via `font-lock-default-fontify-region`
   bound to different keywords. The first is much cheaper and already fixes
   manifestation A.

4. Whatever the approach, **the cell prompt lines and output rules are buffer
   text too** (`jsonyter--nb-outputs-string`) and should get the same treatment;
   they happen to contain only box-drawing characters today, but that is not a
   guarantee.

**Fixed**, following this shape closely:

1. `jsonyter--nb-syntax-propertize`, a `syntax-propertize-function` installed
   in `jsonyter-notebook-mode`, blankets every character of each
   `jsonyter--nb-non-code-spans` span (output spans plus non-code cells'
   source, merged) with punctuation syntax. `parse-sexp-lookup-properties`
   is set buffer-locally in `jsonyter-notebook-mode`, not assumed from the
   language mode.
2. `jsonyter--nb-show-output-as-text` now calls `(syntax-ppss-flush-cache
   src-end)` after rewriting an output region.
3. Took the cheaper option: `jsonyter--nb-map-source-runs` (shared by
   `jsonyter--nb-fontify-region`/`jsonyter--nb-unfontify-region`) now skips
   `jsonyter--nb-non-code-spans` rather than only output spans, so a
   markdown/raw cell's source gets neither the kernel language's syntax nor
   its font-lock painting — manifestations A and C both close this way.
4. The cell prompt is an overlay `before-string`
   (`jsonyter--nb-refresh-prompt`), not buffer text, so `syntax-ppss` never
   sees it and it needs no propertizing. The output block's own border
   text (`jsonyter--nb-outputs-string`) *is* buffer text, but it already
   falls inside the output span `jsonyter--nb-output-spans` reports, so it
   was covered without further change.

---

## 6. Why the tests missed it

`jsonyter-test-font-lock-leaves-output-alone` is the only font-lock test, and
it exercises exactly the case that works. Its fixture output is:

```elisp
;; Output that reads exactly like Python source, so any
;; fontification of it would be unmistakable.
(jsonyter--nb-set-output cell (propertize "import os\n" 'face 'jsonyter-stderr-face) nil t)
```

`import os` is *balanced* Python. It is well chosen for testing that output
keeps its own faces, and it cannot fail the way this report describes, because
it contains no delimiter that opens anything.

No test in the suite fontifies a notebook containing a markdown cell, and no
test checks the face of a cell that comes *after* another cell's output. The
three tests added here do both.

---

## 7. Running the new tests

```sh
emacs -Q --batch -L . -l test/jsonyter-tests.el -f ert-run-tests-batch-and-exit
```

All three are marked `:expected-result :failed`, so the suite stays green while
the defect is open:

```
Ran 473 tests, 472 results as expected, 0 unexpected, 1 skipped
11 expected failures
```

(The other eight expected failures are from `BUG-REPORT-export-images.md`.)

**When the defect is fixed these become *unexpected* passes and the batch
runner exits non-zero.** That is the signal to delete the
`:expected-result :failed` marker, not the test.

Two gaps these tests do not close:

- They run in batch, where there is no real frame. The harness profile
  (`harness/profile/scenarios/visual.el`) is where a real-frame assertion
  belongs, and it has no font-lock scenario at all.
- They cover `python-mode` only, because that is the one mapping in
  `jsonyter-notebook-language-modes` whose mode ships with Emacs. If the
  reporter is seeing `%` and `$` specifically, their kernel language and their
  `jsonyter-notebook-language-modes` value are worth capturing — in the default
  Python mapping those two characters are inert, and the reproduction above
  needed `'`, `"` or `"""` to show the bleed. The mechanism is the same either
  way.
