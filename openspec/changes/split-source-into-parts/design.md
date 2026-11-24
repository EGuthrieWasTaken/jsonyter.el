# Design

- **Cut along the existing headings, not along a new architecture.** The
  sections were already ordered so that each uses only earlier ones (macros
  in particular must be defined before use). Keeping that order means a
  linear `require` chain is always valid, and the split cannot change
  behavior. A later cleanup can untangle the few backward references
  (`repl` -> `notebook`, `transfer` -> `export`, ...); they are the
  `declare-function` lines at the top of each part.
- **`jsonyter.el` keeps the version.** Release tooling, `package.el` and
  `jsonyter-version` all expect `Version:` in the main file. The version
  macro locates `jsonyter.el` beside whichever part is being compiled, so a
  byte-compiled install still bakes in the right number.
- **Explicit `:group`.** `defcustom` finds its group from the `defgroup` in
  the same file; a part without one would leave its options out of
  `M-x customize-group RET jsonyter`. A test enforces it.
