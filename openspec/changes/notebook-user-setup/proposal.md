# Proposal

## Why

A real daily-driver configuration (company at a 0.1 s idle delay, yasnippet,
flycheck, line numbers and the fill-column indicator on `prog-mode-hook`, a
function-valued server token) was run against the shipped 2.5.0 and the 2.4.1
before it. It confirmed the cause of the reported "inserting a newline hangs
Emacs" and turned up two more things:

- **The hang is the 2.4.1 reload bug.** Every `revert-buffer` (an auto-revert
  after a sync does it too) left each cell behind as an empty overlay at the top
  of the buffer, still drawing its prompt. Redisplay after a newline typed at the
  top of a 120-cell notebook then took 0.24 s after 4 reloads and 9.5 s after 20
  (17.5 s with that configuration's packages loaded); mid-notebook edits stayed at
  about 2 ms, which is why it hung "often" and not always. 2.5.0 is flat (4 ms
  after 20 reloads). No test exercised a notebook under real hooks, so only the
  overlay-count unit tests stood between a regression and that user.
- **The fill-column indicator is misplaced under per-cell numbers.** The numbers
  are a `line-prefix`, inside the text area, and the indicator counts columns from
  that area's left edge, so it was drawn three columns before the point where
  source text reaches the fill column: a line of exactly 80 characters crossed it.
  Emacs's own numbers sit outside the text area, so nothing was wrong before 2.5.0.
- **Thirty docstrings read as instructions to an implementer** ("Call `x', then
  ...", numbered steps), and two rendered wrongly: `substitute-command-keys`
  turned a literal backslash-bracket into a command-key reference, so help for the
  LaTeX finders showed `M-x ...` where it meant TeX.

## What Changes

- While per-cell numbers show, `display-fill-column-indicator-column` is moved
  right by the narrowest gutter's width and restored when they go.
- Tests drawn from the configuration: a reduced copy of its buffer hooks as a
  macro, notebooks shaped like a real analysis (many cells, stream, table and
  figure outputs), reload and top-of-notebook tests, a revert that clears overlays
  an older version left, the indicator, and a guard that every jsonyter docstring
  renders as written. One new harness scenario covers reloads in a real Emacs.
- Docstrings rewritten to say what a function does, not how it is built.
- `;; Version:` 2.5.1.

Surfaces affected: notebook (.ipynb) buffers only; all kernel languages. No bridge
protocol change; minimum bridge version unchanged.

## Capabilities

### New Capabilities
- `notebook-user-setup`: how a notebook behaves inside a configured Emacs: its
  fill-column indicator, reloads, mode hook and help text.

### Modified Capabilities

## Impact

- `jsonyter.el`: the indicator shift and restore, two small helpers called from
  numbering's activate and deactivate; docstrings; version.
- `test/jsonyter-tests.el`: the user-setup macro and seven tests.
- `harness/`: one scenario.
- `README.md`: the indicator, the version pins, the scenario count.
