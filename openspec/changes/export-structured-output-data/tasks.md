# Tasks

## 1. Converter

- [x] 1.1 Implement `jsonyter--nb-json-for-wire` (recursive plist/list/vector conversion); verify `jsonyter-test-nb-json-for-wire-*` pass

## 2. Wire it in

- [x] 2.1 Make `jsonyter--nb-data-for-wire` convert JSON-mimetype values with the converter and join only string-list values elsewhere; verify `jsonyter-test-nb-data-for-wire-*` pass
- [x] 2.2 Make `jsonyter--nb-output-for-wire` convert `:metadata` with the converter; verify `jsonyter-test-nb-output-for-wire-*` and the end-to-end collect test pass

## 3. Tests, docs, release

- [x] 3.1 Full ERT suite green apart from the known `kernel-activity-formats-or-falls-back` failure
- [x] 3.2 Harness scenarios: none (no on-screen change); verify by this note
- [x] 3.3 One sentence in README "Exporting notebooks" about structured outputs; verify the text
- [x] 3.4 `;; Version:` bumped once in the release step of the overall run
