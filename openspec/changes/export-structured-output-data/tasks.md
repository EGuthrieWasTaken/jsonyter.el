# Tasks

## 1. Converter

- [ ] 1.1 Implement `jsonyter--nb-json-for-wire` (recursive plist/list/vector conversion); verify `jsonyter-test-nb-json-for-wire-*` pass

## 2. Wire it in

- [ ] 2.1 Make `jsonyter--nb-data-for-wire` convert JSON-mimetype values with the converter and join only string-list values elsewhere; verify `jsonyter-test-nb-data-for-wire-*` pass
- [ ] 2.2 Make `jsonyter--nb-output-for-wire` convert `:metadata` with the converter; verify `jsonyter-test-nb-output-for-wire-*` and the end-to-end collect test pass

## 3. Tests, docs, release

- [ ] 3.1 Full ERT suite green apart from the known `kernel-activity-formats-or-falls-back` failure
- [ ] 3.2 Harness scenarios: none (no on-screen change); verify by this note
- [ ] 3.3 One sentence in README "Exporting notebooks" about structured outputs; verify the text
- [ ] 3.4 `;; Version:` bumped once in the release step of the overall run
