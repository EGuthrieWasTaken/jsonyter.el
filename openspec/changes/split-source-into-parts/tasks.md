# Tasks

## 1. Split

- [x] 1.1 Cut `jsonyter.el` along its section boundaries into the thirteen parts; byte-compile every part with no new warnings
- [x] 1.2 `require` and `declare-function` lines per part; each part loads in a fresh Emacs by itself
- [x] 1.3 `:group 'jsonyter` on every option, face and minor mode outside `jsonyter-custom.el`
- [x] 1.4 `jsonyter-version` reads the header of the sibling `jsonyter.el`

## 2. Tests, docs, CI

- [x] 2.1 Version tests follow the new files (compiled copy bakes the version in; autoload cookies in `jsonyter-core.el`)
- [x] 2.2 Tests: `jsonyter.el` requires every part on disk; each part loads on its own; every option is in the `jsonyter` group
- [x] 2.3 CI: version check watches `jsonyter-*.el`; release attaches every part; coverage instruments `jsonyter*.el`; README install instructions and the manual-install pin check
- [x] 2.4 README "Source layout" section; OpenSpec config describes the layout
- [x] 2.5 `;; Version:` bumped once for the whole run
