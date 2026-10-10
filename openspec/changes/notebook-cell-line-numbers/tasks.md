# Tasks

## 1. Numbers

- [ ] 1.1 Add the `jsonyter-notebook-line-numbers` defcustom and pure helpers (`jsonyter--nb-line-count`, `jsonyter--nb-number-digits`, `jsonyter--nb-number-string`); verify their tests
- [ ] 1.2 Give `jsonyter--nb-prompt` an optional gutter argument and have `jsonyter--nb-refresh-prompt` compute and store the cell's line count and digits; verify the prompt tests, including that the prompt is unchanged when numbering is off
- [ ] 1.3 Add `jsonyter--nb-number-lines`, which eagerly sets `line-prefix` and `wrap-prefix` on source lines, and call it from `jsonyter--nb-make-cell`; verify the numbering, restart, first-line, output-row and wrap tests
- [ ] 1.4 Add the edit tracker, call it from `jsonyter--nb-stale-after-change` and from the surgery paths that change a cell's line count; verify the newline, deletion, 99/100 crossing, bottom-of-notebook, final-before-fontification, stale-first-line, paste, undo and cell-operation tests

## 2. Emacs's own numbers

- [ ] 2.1 Add the sync function on `display-line-numbers-mode-hook` (intent, type, option) and the apply/clear helpers; verify the suppression, off/on, relative and `buffer` tests
- [ ] 2.2 Wire setup and teardown into `jsonyter-notebook-mode` and add the copy filter; verify the mode-off, kill-ring, undo, modified and font-lock-off tests

## 3. Tests and checks

- [ ] 3.1 Headless ERT tests for every scenario of the spec; verify the full suite is green apart from the known `kernel-activity-formats-or-falls-back` failure
- [ ] 3.2 Graphical check under Xvfb: screenshots of a notebook with outputs, a wrapped first line, RET at the top and bottom of a cell and a 100-line cell, against the `buffer` setting, and a frame-by-frame comparison of incremental against forced redisplay for ten edits (with a control run under the `buffer` setting); recorded in the final report
- [ ] 3.3 Harness scenario for the on-screen rows (`harness/profile/scenarios/notebook.el`)

## 4. Docs and release

- [ ] 4.1 README: a "Line numbers" section and the option; verify the text matches the behavior
- [ ] 4.2 `;; Version:` is already bumped to 2.5.0 on this unmerged branch, so no further bump is made; if 2.5.0 ships separately first, bump again and update the README pins
