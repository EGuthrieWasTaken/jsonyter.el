# Tasks

## 1. Fragment finding (pure)

- [ ] 1.1 `jsonyter--latex-mask-code`; verify its tests
- [ ] 1.2 `jsonyter--latex-find-envs`, `-find-display-dollars`, `-find-brackets`; verify their tests
- [ ] 1.3 `jsonyter--latex-find-inline-dollars`; verify its tests (currency, escapes, paragraph breaks)
- [ ] 1.4 `jsonyter--latex-fragments` combining them; verify the combined tests

## 2. Typesetting

- [ ] 2.1 `jsonyter--latex-document`, `jsonyter--latex-converter`, `jsonyter--latex-cache-file`, `jsonyter--latex-fg`; verify their tests
- [ ] 2.2 `jsonyter--latex-render` (latex + converter via `call-process`, cached, error line on failure); verify with stubbed processes, and with real TeX when present

## 3. Showing it

- [ ] 3.1 `jsonyter--latex-image`, `jsonyter--nb-latex-clear`, `jsonyter--nb-latex-overlay-modified`; verify their tests
- [ ] 3.2 `jsonyter--nb-latex-preview-cell`; verify overlay, failure and cache tests
- [ ] 3.3 Commands `jsonyter-notebook-latex-preview`, `-clear`, `-toggle`, key `C-c C-v`, and the on-open option; verify command tests

## 4. Tests, docs, release

- [ ] 4.1 Real-TeX end-to-end test (skipped without latex+dvipng); verify here
- [ ] 4.2 Graphical check under Xvfb: screenshot of a previewed cell; recorded in the final report
- [ ] 4.3 Full ERT suite green apart from the known `kernel-activity-formats-or-falls-back` failure
- [ ] 4.4 Harness scenario for the preview -- cannot be run here; recorded in the final report
- [ ] 4.5 README section and key table row; verify the text
- [ ] 4.6 `;; Version:` bumped once in the release step of the overall run
