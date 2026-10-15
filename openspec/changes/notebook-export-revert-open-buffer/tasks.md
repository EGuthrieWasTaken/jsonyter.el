# Tasks

## 1. Revert helper

- [x] 1.1 Add `jsonyter--revert-if-visiting` (path -> finds a buffer visiting it via `find-buffer-visiting`, no-op if none; reverts with `noconfirm` t when the buffer is unmodified, nil when modified; a revert error is caught and ignored so it never propagates) and a unit test for each of: no buffer visiting, unmodified buffer reverted silently, modified buffer goes through confirmation, revert error swallowed

## 2. Wire it into export

- [x] 2.1 Call `jsonyter--revert-if-visiting` from `jsonyter-notebook-export`'s `on-success` for the result's `:path` and for every `:resources` entry's `:path`; verify a new test exporting to a path with an already-open, unmodified buffer shows the buffer reverted after export
- [x] 2.2 Verify a modified buffer visiting the written path is prompted rather than silently reverted (stub `yes-or-no-p`/the revert confirmation and assert it was asked)
- [x] 2.3 Verify a bundled export (`:resources` present) reverts a buffer visiting one of the resource paths, not just `:path`
- [x] 2.4 Verify nothing is reverted and the existing success message is unchanged when no buffer visits any written path (regression guard on `jsonyter-test-notebook-export-reports-path-and-size`)

## 3. Tests, docs, release

- [x] 3.1 Full ERT suite green apart from the known `kernel-activity-formats-or-falls-back` failure
- [x] 3.2 Harness scenario: none needed — a buffer silently refreshing has no on-screen interaction to drive beyond what ERT already covers via `revert-buffer`; record this as the harness task's verification
- [x] 3.3 README: one sentence in "Exporting notebooks" noting an already-open buffer on the exported path is refreshed; verify the text
- [x] 3.4 `;; Version:` bumped once in the release step of the overall run
