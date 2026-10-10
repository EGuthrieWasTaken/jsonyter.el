# Spec Delta

## Purpose

Defines how cells of the three nbformat types (code, markdown, raw) are created
in and converted within a rendered notebook buffer.

## ADDED Requirements

### Requirement: Toggling cycles through all three cell types
`jsonyter-toggle-cell-type` SHALL change the cell at point to the next type in
the cycle code, markdown, raw, back to code.

#### Scenario: Three toggles
- **WHEN** the toggle command is run three times on a code cell
- **THEN** the cell is markdown, then raw, then code again

### Requirement: A cell's type can be set directly
`jsonyter-set-cell-type` SHALL set the cell at point to the requested type,
reading the type with completion over code, markdown and raw when called
interactively. It SHALL signal a `user-error` outside a notebook buffer, when
there is no cell at point, and for any other type name.

#### Scenario: Set to raw
- **WHEN** the command is called with type `raw` on the second cell
- **THEN** that cell is raw, shows the Raw prompt, and the other cells keep their types

#### Scenario: Unknown type
- **WHEN** the command is called with the type `bogus`
- **THEN** a user-error is signalled and the cell is unchanged

### Requirement: Changing type drops output and refreshes the cell
Changing a cell's type SHALL clear its execution count and, when the new type is
not code, remove its rendered output; the cell's source SHALL be unchanged.

#### Scenario: Code cell with output becomes raw
- **WHEN** a code cell showing output is changed to raw
- **THEN** the output is no longer in the buffer and the source is as before

### Requirement: Insert commands can create any cell type
`jsonyter-insert-cell-above` and `jsonyter-insert-cell-below` SHALL insert a code
cell by default, a markdown cell with a single `C-u`, and a raw cell with a double
`C-u`; a Lisp caller MAY instead pass "code", "markdown" or "raw", and any other
non-nil, non-string argument SHALL mean markdown as it always has.

#### Scenario: Double prefix inserts raw
- **WHEN** insert-below runs with the prefix argument `C-u C-u`
- **THEN** a new raw cell follows the cell at point

#### Scenario: Single prefix still inserts markdown
- **WHEN** insert-above runs with the prefix argument `C-u`
- **THEN** a new markdown cell precedes the cell at point

### Requirement: Raw cells are saved as raw
A notebook containing a raw cell created or converted in the buffer SHALL be
saved with that cell's type `raw` and its source intact.

#### Scenario: Create and save
- **WHEN** a raw cell is inserted, typed into, and the notebook saved
- **THEN** the file's cell list contains a `raw` cell with that source
