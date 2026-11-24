# Spec Delta

## Purpose

Completion, call hints and documentation from the live kernel, wherever
there is code and a kernel.

## ADDED Requirements

### Requirement: Completion from any code surface
`jsonyter-completion-at-point` SHALL complete from the kernel in a REPL's
input, a notebook code cell, a `# %%` script cell and the body of an Org
`jy:` block, sending the code of that cell or block and point's offset in
it.

#### Scenario: Notebook code cell
- **WHEN** point is in a code cell and the kernel is running and idle
- **THEN** the kernel is asked to complete that cell's code at point's offset, and its matches replace the span it names

#### Scenario: Not code
- **WHEN** point is in a markdown or raw cell, in rendered output, on a `# %%` marker line, or on a `jy:` block's header or footer
- **THEN** there is no completion and the kernel is not asked

### Requirement: Completion never starts or waits on a kernel
Completion SHALL return nothing, without starting a kernel or bridge, when
the buffer's kernel is not running, and SHALL return nothing without
asking when it is busy. Outside a REPL it SHALL wait at most
`jsonyter-completion-timeout` seconds, and after a failure SHALL not ask
again for `jsonyter-completion-backoff` seconds.

#### Scenario: Kernel not started
- **WHEN** a notebook's kernel has not been started and completion is requested
- **THEN** it returns nothing and no kernel is started

#### Scenario: Slow kernel
- **WHEN** the kernel does not answer within the timeout
- **THEN** completion returns nothing, and the next request inside the backoff window sends nothing

### Requirement: Arguments first in a call
Right after the `(` or a `,` of a call, argument names (candidates matching
the language's argument regexp) SHALL be displayed before other
candidates, with every candidate still available.

#### Scenario: print(
- **WHEN** the kernel's matches for `print(` are `abs`, `sep=`, `end=` and `set`
- **THEN** they are displayed `sep=`, `end=`, `abs`, `set`, and completing the prefix `se` offers `sep=` and `set`

### Requirement: Documentation from every surface
`jsonyter-inspect` SHALL show the kernel's documentation for the thing at
point in a REPL, a notebook code cell, a script cell and a `jy:` block,
with more detail under a prefix argument, and `C-c C-d` SHALL be bound to
it in the notebook and script maps.

#### Scenario: Notebook
- **WHEN** `jsonyter-inspect` is invoked in a code cell with a running kernel
- **THEN** the kernel is asked with the cell's code and point's offset and the answer is shown in `*jsonyter-doc*`

### Requirement: Help shorthand in a REPL
An input that is only `?NAME` or `??NAME` (and for Python `NAME?` or
`NAME??`) SHALL be answered from the kernel's documentation for NAME
without running it or advancing the execution count, unless
`jsonyter-help-shorthand` disables it. When the kernel has no
documentation or does not answer, the input SHALL be sent unchanged.

#### Scenario: ?len
- **WHEN** `?len` is entered and the kernel documents `len`
- **THEN** the documentation is shown, nothing is executed, and the prompt returns with the same execution count

#### Scenario: Unknown name
- **WHEN** the kernel has no documentation for the name
- **THEN** the input is executed as typed

#### Scenario: Not bare shorthand
- **WHEN** the input is `?rnorm(3)` or spans several lines
- **THEN** it is executed as typed
