# Spec Delta

## Purpose

Defines the buffer-local commands that let a user restructure a rendered
notebook's cells by hand — inserting, pruning, and (with this change)
splitting — independently of running any kernel.

## ADDED Requirements

### Requirement: Splitting a cell requires point to be in a cell's source
`jsonyter-split-cell` SHALL operate only when point is within some cell's
source text. It SHALL refuse with an error, making no change to the
buffer, both when point is not inside any cell and when point is inside a
cell's own rendered output rather than its source.

#### Scenario: No cell at point
- **WHEN** `jsonyter-split-cell` is invoked with point outside every cell
- **THEN** it signals an error and the buffer is unchanged

#### Scenario: Point in a cell's output
- **WHEN** point is within a cell's rendered output (after its source) and `jsonyter-split-cell` is invoked
- **THEN** it signals an error and the buffer is unchanged

### Requirement: Splitting a cell produces two same-type cells at point
With point inside a cell's source, `jsonyter-split-cell` SHALL replace that
one cell with two cells of the same `cell_type`: an upper cell holding the
source before point and a lower cell holding the source from point to the
original cell's end. Point SHALL end at the start of the lower cell's
source.

#### Scenario: Splitting a code cell mid-source
- **WHEN** a code cell has source "a\nb\nc" and point is immediately before "b", and `jsonyter-split-cell` is invoked
- **THEN** the buffer has two code cells in place of it: the first with source "a\n" and the second with source "b\nc"; point is at the start of the second

#### Scenario: Splitting at the very start or end
- **WHEN** point is at the very start or the very end of a cell's source, and `jsonyter-split-cell` is invoked
- **THEN** the split still succeeds, producing one empty cell and one cell holding the whole original source

#### Scenario: Cell type is preserved
- **WHEN** a markdown or raw cell is split
- **THEN** both resulting cells have that same `cell_type`

### Requirement: A split cell's two halves start with no id and no output
Both cells produced by a split SHALL have no cell id and no output,
regardless of whether the original cell had either.

#### Scenario: Splitting an executed cell
- **WHEN** a code cell that has stored output and an execution count is split
- **THEN** neither resulting cell carries that output, that execution count, or the original cell's id
