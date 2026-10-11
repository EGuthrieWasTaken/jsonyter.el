# Tasks

## 1. Fix

- [x] 1.1 Shift `display-fill-column-indicator-column` while per-cell numbers show and restore it afterwards; verify the indicator tests and a live-frame screenshot
- [x] 1.2 Rewrite the stub-style docstrings and the one `defconst` docstring; verify with the docstring guard and a rendering scan of every jsonyter docstring

## 2. Tests

- [x] 2.1 The user-setup macro, an analysis-shaped notebook generator and the reload, top-of-notebook, stale-overlay, mode-hook and indicator tests; verify they pass and that removing both overlay defences (2.4.1's behaviour) fails three of them
- [x] 2.2 The docstring-rendering guard
- [x] 2.3 A harness scenario for reloads; verify in the batch tier and in a live frame
- [x] 2.4 Full ERT suite green apart from the known `kernel-activity-formats-or-falls-back` failure

## 3. Docs and release

- [x] 3.1 README: the indicator note in "Line numbers", the version pins, the scenario count
- [x] 3.2 `;; Version:` bumped to 2.5.1 (never used before)
