# Tasks

## 1. Re-render is idempotent

- [x] 1.1 Add `jsonyter--nb-forget-cells` and call it first in `jsonyter--nb-render`; verify `jsonyter-test-nb-render-*` and the revert test pass

## 2. Self-healing edits

- [x] 2.1 Add `jsonyter--nb-drop-empty-cells`; verify its test passes
- [x] 2.2 Add `jsonyter--nb-adopt-stray-text`; verify the adoption tests pass
- [x] 2.3 Call both from `jsonyter--nb-stale-after-change` (outside surgery); verify the end-of-buffer and backspace tests pass

## 3. Prune

- [x] 3.1 Add `jsonyter--nb-empty-cell-p` and `jsonyter-notebook-prune`; verify the prune tests pass

## 4. Tests, docs, release

- [x] 4.1 Full ERT suite green apart from the known `kernel-activity-formats-or-falls-back` failure
- [ ] 4.2 Harness scenario for the end-of-buffer typing and prune (visible on screen) -- cannot be run here; recorded in the final report (NOT RUN: no graphical harness in the unattended session)
- [x] 4.3 README: prune command and end-of-buffer behavior; verify the text
- [x] 4.4 `;; Version:` bumped once in the release step of the overall run
