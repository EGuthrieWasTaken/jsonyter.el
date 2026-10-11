# Spec Delta

## Purpose

Defines how a rendered notebook behaves inside an Emacs configured with the
common editing aids around it: the fill-column indicator, reloads, mode hooks and
help text.

## ADDED Requirements

### Requirement: The fill-column indicator stays on the text under per-cell numbers
While per-cell line numbers are showing, `display-fill-column-indicator-column`
SHALL be moved right by the width of the narrowest number gutter, so that a source
line of exactly `fill-column` characters ends at the indicator as it does under
Emacs's own numbers. A column the user chose SHALL be shifted from and restored to
itself, and turning the numbers off SHALL leave the variable as it was.

#### Scenario: Numbers on
- **WHEN** per-cell numbers start in a notebook whose fill column is 80
- **THEN** the indicator column is 83

#### Scenario: Numbers off
- **WHEN** the numbers are switched off again
- **THEN** the variable is as it was before they started, including not being set locally at all

#### Scenario: A column the user chose
- **WHEN** the buffer's indicator column is 100 and the numbers are switched on, then off
- **THEN** it is 103 while they show and 100 afterwards

#### Scenario: The buffer setting
- **WHEN** `jsonyter-notebook-line-numbers` is `buffer`
- **THEN** the indicator column is untouched

### Requirement: Reloading a notebook leaves one overlay per cell
However often a notebook is reloaded, the buffer SHALL hold one cell overlay per
cell and no cell overlay that covers no text, and one overlay drawing a string per
cell, so that redisplay at the top of the buffer does not grow with the number of
reloads. A reload SHALL also clear such overlays left in a buffer by an older
version.

#### Scenario: Many reloads
- **WHEN** a notebook of twenty-four cells is reverted twenty-five times
- **THEN** it has twenty-four cell overlays, none empty, and twenty-four overlays drawing a string

#### Scenario: A newline at the top after reloads
- **WHEN** a newline is typed at the top of a notebook that has been reverted ten times
- **THEN** the number of overlays drawing a string is unchanged and the first cell's numbers are right

#### Scenario: Overlays left by an older version
- **WHEN** a buffer holds empty cell overlays with prompts and is then reverted
- **THEN** it holds only the notebook's own cells

### Requirement: The notebook mode hook sees a set-up notebook
`jsonyter-notebook-mode-hook` SHALL run after the language major mode and its hooks,
so that a function on it can switch off a minor mode that a global mode turned on
for that language mode, without affecting ordinary buffers of the same language.

#### Scenario: A checker switched off for notebooks only
- **WHEN** a global checker mode enables itself for Python buffers and a function on `jsonyter-notebook-mode-hook` disables it
- **THEN** it is off in an opened notebook and still on in a plain Python buffer

### Requirement: Help text renders as written
The documentation string of every jsonyter function and variable SHALL render
without control characters or unintended command-key references and SHALL describe
what the function does rather than instruct an implementer how to build it.

#### Scenario: Backslashes in a docstring
- **WHEN** a docstring talks about LaTeX's backslash forms
- **THEN** its rendered text contains no control character and no `M-x ...` reference

#### Scenario: Implementation steps
- **WHEN** any docstring is scanned
- **THEN** none has numbered implementation steps or reads "Call `jsonyter-...', then"
