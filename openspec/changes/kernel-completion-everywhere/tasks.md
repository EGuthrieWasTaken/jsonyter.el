# Tasks

## 1. Completion and help

- [x] 1.1 `jsonyter-complete.el`: context protocol, `jsonyter-completion-at-point`, options
- [x] 1.2 Context functions and mode wiring for REPL, notebook, script and Org
- [x] 1.3 Call scanning and argument-first ordering; type annotations
- [x] 1.4 `jsonyter-inspect` and the REPL/Org wrappers; `C-c C-d` in notebook and script maps
- [x] 1.5 Eldoc signatures behind `jsonyter-eldoc`
- [x] 1.6 `?name` help shorthand in the REPL

## 2. Tests, docs, release

- [x] 2.1 Tests: each surface completes and refuses where it should; never starts a kernel; busy; timeout and backoff; arguments first; types; position option; call scanning; inspect from every surface; Eldoc; shorthand parsing, answer, fallback, restriction
- [x] 2.2 Run against a real IPython kernel by hand: REPL `?len`, `print(` ordering; notebook completion of a live variable, none before the kernel starts, none in markdown; Eldoc; `C-c C-d`
- [ ] 2.3 Harness scenario for the graphical Emacs -- NOT RUN: no `emacs-harness` checkout in this session; the existing `repl-completes-at-point-from-the-kernel` scenario still holds (the candidate list is still a plain list there)
- [x] 2.4 README: completion section, options, keys
- [x] 2.5 `;; Version:` bumped once for the whole run
