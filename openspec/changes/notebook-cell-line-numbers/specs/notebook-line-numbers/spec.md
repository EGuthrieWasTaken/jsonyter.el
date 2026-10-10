# Spec Delta

## Purpose

Defines how line numbers are shown beside the source of a notebook cell, so that a
number names a line of the cell the user is editing rather than a row of the
rendered view.

## ADDED Requirements

### Requirement: Source lines are numbered within their own cell
When `jsonyter-notebook-line-numbers` is `cell` and the user has absolute line
numbers on in a notebook buffer, every line of every cell's source SHALL show its
position within its own cell, counting from 1, restarting at 1 in each cell, for
code, markdown and raw cells alike.

#### Scenario: Numbers restart in every cell
- **WHEN** a notebook has a three-line cell followed by a two-line cell
- **THEN** the first cell's lines are numbered 1, 2, 3 and the second cell's lines 1, 2

#### Scenario: Every cell type is numbered
- **WHEN** a notebook has a markdown cell and a raw cell
- **THEN** their source lines are numbered from 1 like a code cell's

#### Scenario: A cell with empty source
- **WHEN** a cell has no source text
- **THEN** its single empty line is numbered 1

### Requirement: Numbers sit on the row that shows the line
A number SHALL be displayed on the screen row that shows its line's own text; the
number of a cell's first line SHALL NOT be displayed on the blank spacer row or
the label row of that cell's prompt. Prompt rows, the spacer row above a prompt,
output text rows, output frame rules and image rows SHALL carry no number.

#### Scenario: First line of a cell
- **WHEN** a cell's prompt is shown above its first source line
- **THEN** the number 1 is on the same row as that line's text and no number is on the prompt's rows

#### Scenario: Cell with output
- **WHEN** a cell shows a text output and a sliced image
- **THEN** no output row, frame rule or image slice row has a number

### Requirement: Wrapped lines stay aligned under their text
A source line too long for the window SHALL continue on rows that begin in the
same column as the line's text, leaving the number column blank on those rows,
for the first line of a cell as for any other line.

#### Scenario: Long first line
- **WHEN** a cell's first line wraps onto a second row
- **THEN** the continuation row starts under the text of the first row, not under the number, and the prompt rows above are not indented

#### Scenario: Long later line
- **WHEN** a cell's third line wraps
- **THEN** its continuation row starts under the text of its first row

### Requirement: Numbers in a cell share one column
Within one cell the numbers SHALL be right-aligned in a column wide enough for
the cell's largest number and at least two digits wide, followed by one space,
and every source line of the cell, the first included, SHALL start its text in
the same column.

#### Scenario: Small cell
- **WHEN** a cell has nine lines
- **THEN** its numbers occupy two digits, so "1" is displayed as " 1", and all nine lines start their text in the same column

#### Scenario: Cell of a hundred lines
- **WHEN** a cell has one hundred lines
- **THEN** its numbers occupy three digits and all one hundred lines, including the first, start their text in the same column

### Requirement: Numbers follow edits
After text is inserted into or deleted from a cell's source, the numbers shown for
that cell's lines SHALL match the lines' new positions once the cell is displayed,
wherever in the cell the edit happens. The numbers of other cells SHALL NOT change.

#### Scenario: Newline at the start of a cell
- **WHEN** a newline is inserted at the start of a three-line cell
- **THEN** the cell shows four lines numbered 1 to 4 and the neighbouring cells are unchanged

#### Scenario: Newline in the middle of a cell
- **WHEN** a newline is inserted in the second line of a three-line cell
- **THEN** the cell shows four lines numbered 1 to 4

#### Scenario: Newline removed
- **WHEN** the newline between the first and second lines of a three-line cell is deleted
- **THEN** the cell shows two lines numbered 1 and 2

#### Scenario: Newline at the bottom of the notebook
- **WHEN** a newline is typed after the last cell's final line
- **THEN** the new last line is numbered one more than the line before it, or 1 if it begins a new cell

#### Scenario: Cell operations keep numbers right
- **WHEN** a cell is moved, inserted, changed in type or deleted
- **THEN** every remaining cell's numbers still run from 1 through its own line count

### Requirement: The column widens and narrows with the cell
When an edit takes a cell across a power of ten in its line count, the whole
column of that cell SHALL widen or narrow with it, the first line's number
included.

#### Scenario: Ninety-nine lines become a hundred
- **WHEN** an edit takes a cell from 99 to 100 lines
- **THEN** every line of that cell, the first included, is displayed with a three-digit column

#### Scenario: A hundred lines become ninety-nine
- **WHEN** an edit takes a cell from 100 to 99 lines
- **THEN** every line of that cell, the first included, is displayed with a two-digit column

### Requirement: Off-screen lines are numbered when displayed
Renumbering after an edit SHALL NOT compute numbers for lines that are not on
screen; those lines SHALL be marked and numbered when they are first displayed.

#### Scenario: Newline at the top of a very long cell
- **WHEN** a newline is inserted at the top of a cell of ten thousand lines
- **THEN** the lines far below the edit are marked as needing numbers and none of them is renumbered until it is displayed

### Requirement: Per-cell numbers replace Emacs's own numbers
While per-cell numbers are shown, the notebook buffer SHALL NOT also display
Emacs's own line numbers: the buffer's `display-line-numbers` SHALL be nil while
`display-line-numbers-mode` stays on, so that the mode keeps recording the user's
wish for line numbers.

#### Scenario: Global line numbers on
- **WHEN** `global-display-line-numbers-mode` is on and a notebook is opened with the `cell` setting
- **THEN** the buffer shows per-cell numbers and `display-line-numbers` is nil in it

#### Scenario: Turning line numbers off and on again
- **WHEN** the user turns `display-line-numbers-mode` off and then on in an open notebook
- **THEN** the per-cell numbers disappear and then reappear, and Emacs's own numbers never show

### Requirement: Per-cell numbers follow the user's choice to have numbers
Per-cell numbers SHALL be shown only while `display-line-numbers-mode` is on in
the notebook buffer and numbering is absolute. A user with line numbers off SHALL
see no numbers. A buffer whose `display-line-numbers` is `relative` or `visual`
SHALL be left to Emacs, with no per-cell numbers added.

#### Scenario: Line numbers off
- **WHEN** a notebook is opened with `display-line-numbers-mode` off
- **THEN** no line numbers of any kind are shown

#### Scenario: Relative numbers
- **WHEN** a notebook is opened with `display-line-numbers-type` set to `relative`
- **THEN** Emacs's relative numbering is untouched and no per-cell numbers are shown

#### Scenario: Option read at toggle time
- **WHEN** the user changes `jsonyter-notebook-line-numbers` and toggles `display-line-numbers-mode` off and on in an open notebook
- **THEN** the buffer follows the new setting

### Requirement: The buffer setting keeps Emacs's numbering
When `jsonyter-notebook-line-numbers` is `buffer`, jsonyter SHALL NOT alter the
buffer's `display-line-numbers`, SHALL NOT add any numbering of its own, and SHALL
leave the prompts as they are without a number at their end.

#### Scenario: Buffer setting
- **WHEN** a notebook is opened with the `buffer` setting and line numbers on
- **THEN** `display-line-numbers` is untouched, no cell's text carries a line-prefix, and the prompts are unchanged

### Requirement: Per-cell numbers are display only
Per-cell numbers SHALL NOT be part of any cell's source text, of what is saved to
the `.ipynb` file, of the undo history or of the buffer's modified state, and
SHALL NOT be carried along when text is copied or killed.

#### Scenario: Source and save are unaffected
- **WHEN** per-cell numbers are showing
- **THEN** each cell's source as read for saving is exactly the text the user typed

#### Scenario: Not modified, nothing to undo
- **WHEN** a notebook is opened and displayed with per-cell numbers and nothing is edited
- **THEN** the buffer is not marked modified and its undo history is unchanged

#### Scenario: Copying source
- **WHEN** a region of a cell's source is copied or killed
- **THEN** the text in the kill ring carries no line-prefix or wrap-prefix property

### Requirement: Numbers do not depend on font-lock
Per-cell numbers SHALL be shown whether or not `font-lock-mode` is on.

#### Scenario: Font-lock off
- **WHEN** `font-lock-mode` is turned off in a notebook with per-cell numbers
- **THEN** the numbers are still displayed

### Requirement: Only notebook buffers are affected
Per-cell numbering SHALL apply to notebook (.ipynb) buffers only. REPL, script
and Org buffers SHALL keep Emacs's own line numbers exactly as configured.

#### Scenario: Script buffer
- **WHEN** a `# %%` script buffer has `display-line-numbers-mode` on
- **THEN** its `display-line-numbers` is untouched

### Requirement: Turning the notebook mode off restores Emacs's numbering
Disabling `jsonyter-notebook-mode` SHALL remove every number jsonyter added from
the buffer's text and prompts and SHALL restore Emacs's own line numbers if the
user has `display-line-numbers-mode` on.

#### Scenario: Mode off
- **WHEN** `jsonyter-notebook-mode` is turned off in a notebook showing per-cell numbers with `display-line-numbers-mode` on
- **THEN** no cell text carries a line-prefix or wrap-prefix, the prompts have no number, and `display-line-numbers` is `t` again
