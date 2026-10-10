# Spec Delta

## Purpose

Guarantees that a rendered notebook buffer's cells always cover exactly the
text the user sees and edits, so that nothing typed is silently dropped on save
and no phantom cells appear, and provides a command to clear empty cells.

## ADDED Requirements

### Requirement: Re-rendering yields exactly the notebook's cells
Rendering a notebook into a buffer that already shows cells SHALL discard the
previous cells first, so the buffer holds one cell per cell of the notebook and
no others.

#### Scenario: Revert keeps the cell count
- **WHEN** a 3-cell notebook is open and the buffer is reverted, once or repeatedly
- **THEN** the buffer has exactly 3 cells, none of them empty, in the original order

### Requirement: Text after the last cell is adopted
When text exists after the last cell, the notebook SHALL bring it into a cell
before the next save: into the last cell when that cell shows no output,
otherwise into a new code cell. The text SHALL be saved.

#### Scenario: Typing at the end of the buffer
- **WHEN** the user moves to the very end of the buffer, after the last cell's final newline, and types `y = 2`
- **THEN** the typed text is part of the last cell's source and is written on save

#### Scenario: Last cell has output
- **WHEN** the last cell shows output and the user types `y = 2` at the very end of the buffer
- **THEN** a new code cell whose source is `y = 2` follows it, and the existing cell and its output are unchanged

#### Scenario: Pressing RET at the end of the buffer
- **WHEN** the user presses RET at the very end of the buffer
- **THEN** no text is left outside the cells

### Requirement: Zero-length cells are dropped after an edit
After an ordinary edit, a cell that covers no text SHALL be removed.

#### Scenario: Backspacing over an empty cell
- **WHEN** an empty cell's only newline is deleted by backspacing from the start of the next cell
- **THEN** the empty cell no longer exists, and the other cells are unchanged

### Requirement: jsonyter-notebook-prune removes empty cells
`jsonyter-notebook-prune` SHALL delete every cell whose source is blank and that
shows no output, and any zero-length cell, SHALL return and report how many it
removed, and SHALL leave the buffer modified when it removed any. It SHALL never
remove the notebook's last remaining cell.

#### Scenario: Mixed notebook
- **WHEN** a notebook has cells with sources `a = 1`, empty, whitespace only, `b = 2`, and an empty-source cell that shows output, and prune runs
- **THEN** the cells with sources `a = 1`, `b = 2` and the one with output remain, 2 are reported removed, and the buffer is modified

#### Scenario: Nothing to prune
- **WHEN** no cell is empty and prune runs
- **THEN** nothing is removed, the buffer is not marked modified, and the message says so

#### Scenario: Every cell is empty
- **WHEN** all cells are empty and prune runs
- **THEN** exactly one empty cell remains
