# Spec Delta

## Purpose

Word-wise motion and editing in a rendered notebook behave the same in
every kind of cell and in output.

## ADDED Requirements

### Requirement: Word motion stops inside non-code spans
`forward-word` and `backward-word` SHALL stop at word boundaries inside
markdown cells, raw cells and rendered output, as they do in a code cell.
They SHALL NOT pass through a span's words to a later cell or to the
start or end of the buffer.

#### Scenario: Markdown cell
- **WHEN** point is at the start of a word in a markdown cell and `forward-word` is invoked
- **THEN** point moves to the end of that word

#### Scenario: Last cell
- **WHEN** the last cell is markdown and point is at the start of one of its words
- **THEN** `forward-word` stops at the end of that word, not at the end of the buffer

#### Scenario: Killing a word
- **WHEN** `kill-word` is invoked in a markdown cell
- **THEN** only that word is deleted, and no code cell is changed

### Requirement: Non-code text still cannot open syntax
Letters and digits in a non-code span SHALL be word constituents; every
other non-whitespace character SHALL remain punctuation, so no span can
open or close a string, comment or pair.

#### Scenario: Quote in prose
- **WHEN** a markdown cell contains an unbalanced quote or bracket
- **THEN** the syntax state of the code cells after it is unaffected
