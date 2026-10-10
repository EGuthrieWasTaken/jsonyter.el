# Tasks

## 1. Implementation

- [ ] 1.1 Add `jsonyter--sync-ensure-local-dir (DIR)` next to `jsonyter-sync-add-pair`; verify the local-directory ERT tests pass
- [ ] 1.2 Add `jsonyter--sync-ensure-remote-dir (BUFFER REMOTE)` (mkdir -p over `list_contents`/`make_directory`, refusing a file); verify the remote-directory ERT tests pass
- [ ] 1.3 Add optional `CREATE-DIRS` to `jsonyter-sync-add-pair` and pass `t` from its `interactive` form; verify the opt-in and interactive ERT tests pass

## 2. Tests

- [ ] 2.1 Append the spec's ERT tests to `test/jsonyter-tests.el` and make `jsonyter-test-sync-add-pair-interactive-form` hermetic; verify the full suite is green apart from the known `kernel-activity-formats-or-falls-back` failure
- [ ] 2.2 Harness scenarios: none (nothing new appears on screen; the change is a prompt-time side effect); verify by this note

## 3. Docs and release

- [ ] 3.1 Document directory creation in the README sync-pairs section and verify the text matches the behavior
- [ ] 3.2 Bump `;; Version:` once for the whole release (done in the release step of the overall run) and verify `version-check.yml` logic against the tag list
