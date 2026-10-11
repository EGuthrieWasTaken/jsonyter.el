# Design

## Context

A cell's type lives on its overlay (`jsonyter-cell-type`); the prompt label and
face derive from it (`jsonyter--nb-prompt` already handles "raw"), and
non-code cells' source is already treated as prose for fontification and syntax
(`jsonyter--nb-prose-spans` is "not code"). `jsonyter-toggle-cell-type` flips two
types inline; `jsonyter--nb-insert-cell` already takes any type string. The
insert commands' `P` argument is a boolean for markdown today.

## Goals / Non-Goals

**Goals:**
- Every cell type is creatable and convertible from the UI with no breakage of
  existing key habits (`C-u` = markdown).

**Non-Goals:**
- No raw-format metadata editing (`metadata.format`); an existing value is
  preserved untouched by the bridge.
- No new key binding: `M-x jsonyter-set-cell-type`, plus the existing toggle
  and insert keys.

## Decisions

- **One conversion helper `jsonyter--nb-set-type`** shared by the toggle and the
  new command, so output dropping and refreshing live in one place.
- **Prefix mapping in a pure helper `jsonyter--nb-type-from-prefix`** so the
  rules (nil code, `(16)` raw, strings pass through, anything else markdown)
  are unit-testable without a keymap.
- **Cycle order code -> markdown -> raw -> code** keeps the old first step
  (code -> markdown) and the old second step (markdown -> code) only changes
  to go through raw; the README says so.
- **Refresh after conversion.** The old toggle left a former code cell
  highlighted as code; the helper flushes the syntax cache and font-lock for
  the cell's span.

## Risks / Trade-offs

- A user used to the two-state toggle needs an extra press from markdown →
  documented, and `jsonyter-set-cell-type` is the direct route.
- Converting a code cell with output to raw loses the output with no undo →
  same as converting to markdown today.
