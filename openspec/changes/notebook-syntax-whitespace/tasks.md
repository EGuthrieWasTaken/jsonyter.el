# Tasks

## 1. Fix

- [x] 1.1 Reproduce the endless loop with ESS in an R notebook and find where it goes round; verify it never returns on 2.5.1 for RET and TAB at a cell's first line and anywhere in a markdown cell
- [x] 1.2 Give whitespace and comment-end characters their language entries in the inert syntax table; verify the same commands return in about 2 ms

## 2. Tests

- [x] 2.1 Whitespace syntax in prose and output
- [x] 2.2 A replica of the backward walk from the first line of a code cell after prose, after output, and inside a markdown cell
- [x] 2.3 RET under real ESS, skipped where it is not installed; verify all three fail on 2.5.1 and pass now
- [x] 2.4 Full ERT suite green apart from the known `kernel-activity-formats-or-falls-back` failure

## 3. Docs and release

- [x] 3.1 README version pins
- [x] 3.2 `;; Version:` bumped to 2.5.2 (never used before)
- [x] 3.3 The 2.5.1 change's diagnosis corrected
