# Proposal

## Why

Issue 23. Kernel-backed TAB completion existed only in the REPL; notebooks,
`# %%` script cells and Org `jy:` blocks left completion to the language's
own, and `C-c C-d` documentation lookup was missing from notebooks and
scripts. Inside a call such as `rnorm(` the kernel's argument names arrive
mixed into hundreds of global names. And `?rnorm` in a REPL did nothing:
IPython answers `?name` with a payload the bridge does not forward.

## What Changes

- New part `jsonyter-complete.el`. `jsonyter-completion-at-point` works from
  a REPL, a notebook code cell, a `# %%` cell and a `jy:` block, through a
  per-surface context function (code, point's offset, session). It never
  starts a kernel, returns nil while the kernel is busy, and outside the
  REPL waits at most `jsonyter-completion-timeout` and then backs off for
  `jsonyter-completion-backoff` seconds.
- `jsonyter-completion-position` (`first` or `last`) decides whether kernel
  completion goes before or after the language's own; either way it steps
  aside (`:exclusive no`) when it has nothing to offer.
- Inside a call, right after `(` or `,`, argument names come first
  (`jsonyter-completion-arguments-first`, `jsonyter-completion-argument-regexps`),
  and candidates are annotated with the kernel's types and signatures.
- Optional Eldoc signatures (`jsonyter-eldoc`).
- `jsonyter-inspect` is the one documentation command, bound to `C-c C-d`
  in notebooks and scripts too; `jsonyter-repl-inspect` and
  `jsonyter-org-inspect` become thin wrappers. A prefix argument asks for
  more detail.
- `?name` / `??name` (and Python's `name?` / `name??`) in a REPL are
  answered from `inspect` without running anything or advancing the
  execution count; when the kernel has nothing, the input is sent as typed
  (`jsonyter-help-shorthand`).

Surfaces affected: REPL, notebook, script cells, Org/Babel (`jy:` blocks);
all kernel languages (Python verified against a real IPython kernel; R, as
the issue notes, could not be tested here and every R-specific behavior
degrades to the unchanged behavior). No bridge protocol change; the
bridge's existing `complete` and `inspect` (with `detail_level`) are used.

## Capabilities

### New Capabilities
- `kernel-assist`: completion, call hints and help from the live kernel.

### Modified Capabilities

## Impact

- New `jsonyter-complete.el`; context functions and mode wiring in
  `jsonyter-repl.el`, `-notebook.el`, `-script.el`, `-org.el`.
- `test/jsonyter-tests.el`: new tests with a fake kernel.
- `README.md`: completion section, options, keys.
