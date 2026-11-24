# Spec Delta

## Purpose

What tools that follow a buffer's edits see of a rendered notebook.

## ADDED Requirements

### Requirement: Output writes are visible to change tracking
Writing, replacing or removing a cell's output SHALL run
`before-change-functions` and `after-change-functions` for the replaced
region, so a copy of the buffer kept from those hooks stays equal to the
buffer. The write SHALL NOT enter the undo history or mark the buffer
modified.

#### Scenario: Server copy after a run
- **WHEN** a cell's output is written into a notebook buffer that has an `after-change-functions` tracker
- **THEN** the tracker's copy equals the buffer text

#### Scenario: Output replaced or cleared
- **WHEN** a cell's output is replaced with shorter output, or cleared
- **THEN** the tracker's copy still equals the buffer text

#### Scenario: A tracker fails
- **WHEN** a change hook signals an error during an output write
- **THEN** the output is still written and the error is reported, not raised

### Requirement: A cell is indented on its own
The first lines of a code cell SHALL be indented as if the cell were a
file of its own, whatever earlier cells end with.

#### Scenario: Earlier cell inside a bracket
- **WHEN** a code cell ends inside an unclosed bracket and the next cell is indented
- **THEN** the next cell's lines get no continuation indentation from it

#### Scenario: Bracket in the same cell
- **WHEN** a cell opens a bracket and the following line is indented
- **THEN** it is indented as a continuation
