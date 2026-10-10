# Tasks

## 1. Pure helpers

- [ ] 1.1 Implement `jsonyter--nb-next-cell-type`; verify its test passes
- [ ] 1.2 Implement `jsonyter--nb-type-from-prefix`; verify its test passes

## 2. Conversion and commands

- [ ] 2.1 Implement `jsonyter--nb-set-type`; verify the set-type tests pass
- [ ] 2.2 Implement `jsonyter-set-cell-type`; verify its tests pass
- [ ] 2.3 Rewrite `jsonyter-toggle-cell-type` on top of the helpers; verify the cycle test passes
- [ ] 2.4 Update `jsonyter-insert-cell-below` and `-above` to use `jsonyter--nb-type-from-prefix`; verify the insert tests pass

## 3. Tests, docs, release

- [ ] 3.1 Bridge-backed save test for a created raw cell (skipped without the bridge); verify it passes with jsonyter >= 2.0
- [ ] 3.2 Full ERT suite green apart from the known `kernel-activity-formats-or-falls-back` failure
- [ ] 3.3 Harness scenario: Raw prompt after `C-u C-u C-c C-i` -- cannot be run here; recorded in the final report
- [ ] 3.4 README: toggle cycle, set-cell-type, insert prefixes; verify the text
- [ ] 3.5 `;; Version:` bumped once in the release step of the overall run
