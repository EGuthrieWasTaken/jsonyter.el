# Spec Delta

## Purpose

Defines how the parts of a notebook that are not code (other cells' source and
rendered output) read to the kernel language's syntax and indentation code.

## ADDED Requirements

### Requirement: Whitespace in text that is not code stays whitespace
The syntax of the text of a markdown or raw cell and of rendered output SHALL make
every character other than whitespace punctuation, so that none of it can open or
close a string, comment or pair. A character that the buffer's syntax table gives
the whitespace or comment-end class SHALL keep that entry there.

#### Scenario: Prose and output
- **WHEN** a notebook has a markdown cell and a code cell with output
- **THEN** each space, tab and newline in them has the same syntax class as in the buffer's syntax table, and every other non-digit character is punctuation

#### Scenario: Punctuation cannot open a string
- **WHEN** a markdown cell contains an apostrophe and the next cell is code
- **THEN** the code cell is not fontified as a string

### Requirement: A backward walk from the top of a cell finishes
Walking up the buffer one line at a time from the first line of a code cell, from
the first line of a cell that follows output, or from a new line inside a markdown
cell, in the manner of ESS's indentation, SHALL reach the top of the buffer or a
line with text in a bounded number of steps, and RET and TAB at those places SHALL
return.

#### Scenario: First line of a code cell after prose
- **WHEN** the walk starts at the first line of a code cell that follows a markdown cell
- **THEN** it stops within a few steps

#### Scenario: First line after output
- **WHEN** the walk starts at the first line of a cell that follows another cell's output
- **THEN** it stops within a few steps

#### Scenario: Inside a markdown cell
- **WHEN** the walk starts at the end of a markdown cell's last line
- **THEN** it stops within a few steps

#### Scenario: RET under ESS
- **WHEN** RET is pressed at the start of a code cell, at the end of its first line, and at the end of a markdown cell in an R notebook with ESS
- **THEN** each returns and ESS's code-end search is called a handful of times
