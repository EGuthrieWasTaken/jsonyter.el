# Spec Delta

## Purpose

Lets a reader of a notebook buffer see the mathematics in markdown cells
typeset, in place, while the notebook's text stays exactly what is saved.

## ADDED Requirements

### Requirement: Math is found in the forms Jupyter renders
Fragment detection SHALL recognise `$...$` (inline), `$$...$$` and `\[...\]`
(display), `\(...\)` (inline), and the environments `equation`, `align`,
`gather`, `multline`, `eqnarray` and `flalign` with or without a star
(display). Each fragment SHALL carry its start and end offsets in the text, its
kind and its TeX body.

#### Scenario: Each delimiter form
- **WHEN** a text contains `$a$`, `$$b$$`, `\(c\)`, `\[d\]` and an `equation` environment
- **THEN** five fragments are found, in text order, of kind inline, display, inline, display and display

#### Scenario: Currency is not math
- **WHEN** a text says `costs $5 and $6 today`
- **THEN** no fragment is found

#### Scenario: Escaped dollar
- **WHEN** a text says `price is \$5 and $x$`
- **THEN** only `$x$` is found

### Requirement: Code is never previewed
Text inside backtick code spans and inside fenced code blocks SHALL NOT yield
fragments.

#### Scenario: Dollar signs in code
- **WHEN** a text holds the inline code `` `echo $HOME and $PATH` `` and a fenced block containing `$$x$$`
- **THEN** no fragment is found in either

### Requirement: A preview is typeset with the user's macros
The LaTeX document built for a fragment SHALL contain the configured preamble,
every line of `jsonyter-notebook-latex-macros`, and the fragment wrapped
according to its kind: `$...$` for inline, `\[...\]` for display, unwrapped for
an environment.

#### Scenario: Macros included
- **WHEN** the macros list holds `\newcommand{\R}{\mathbb{R}}` and an inline fragment `x \in \R` is turned into a document
- **THEN** the document contains the macro line before `\begin{document}` and `$x \in \R$` inside it

### Requirement: Tools are checked and rendering is cached
Previewing SHALL signal a `user-error` naming the missing program when `latex`
or a converter (`dvipng` or `dvisvgm`, per `jsonyter-latex-preview-converter`)
is not on `exec-path`. A rendered image SHALL be stored under a name derived
from the document, converter, resolution and colour, and reused on a repeat.

#### Scenario: No LaTeX installed
- **WHEN** previewing is requested and `latex` cannot be found
- **THEN** a user-error mentioning `latex` is signalled and the buffer is unchanged

#### Scenario: Second preview reuses the image
- **WHEN** the same fragment is previewed twice
- **THEN** the TeX toolchain runs once

### Requirement: A failed fragment is reported, not fatal
When LaTeX rejects a fragment, previewing SHALL leave that fragment as text, say
so in the echo area with the first TeX error line, and still preview the other
fragments.

#### Scenario: One bad fragment
- **WHEN** a cell holds `$\badmacro$` and `$x$` and LaTeX rejects the first
- **THEN** only `$x$` gets an image and a message names the failure

### Requirement: Previews are overlays on untouched text
A preview SHALL be an overlay whose `display` is the image, covering exactly the
fragment's text. The buffer's text, the cells' sources and the saved file SHALL
be unchanged. Editing inside a preview SHALL remove only that preview.

#### Scenario: Save is unaffected
- **WHEN** a markdown cell is previewed and the notebook saved
- **THEN** the cell's source in the file is byte-for-byte what it was

#### Scenario: Editing removes one preview
- **WHEN** one of two previewed fragments is edited
- **THEN** its image disappears and the other remains

### Requirement: Commands act on the cell at point or on every markdown cell
The toggle command SHALL preview the markdown cell at point, or clear it if it
already shows previews; with a prefix argument it SHALL apply to every markdown
cell. Code and raw cells SHALL be ignored, and so SHALL the managed LaTeX-macros
cell.

#### Scenario: Toggle on and off
- **WHEN** the toggle runs twice in a markdown cell with math
- **THEN** the first run shows images over the math and the second removes them

#### Scenario: Code cell
- **WHEN** the toggle runs in a code cell
- **THEN** nothing is previewed and the user is told it is not a markdown cell
