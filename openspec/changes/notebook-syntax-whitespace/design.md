# Design

## Context

A notebook buffer is one buffer under the kernel language's major mode, so one
syntax table, holding code-cell source, other cells' source and rendered output.
2.4.1 added a `syntax-propertize-function` that puts the `syntax-table` property
on every character of the latter two, so that prose or a traceback cannot open a
string or comment that runs on through the next cells. The value was the
punctuation syntax descriptor for every character.

A major mode's code and the packages around it assume an invariant that this broke:
a newline is whitespace or the end of a comment. ESS's indentation relies on it
in `ess-skip-blanks-backward` (go up a line, jump to `ess-code-end-position`,
repeat while at the start of a line) and `ess-code-end-position` (move past the
newline, then `forward-comment -1`). `forward-comment` moves backward only over
whitespace and comment ends, so over a punctuation newline it returns with point
unmoved and the loop makes no progress.

Reproduced with ESS 24.1.1 from the distribution and an R notebook of 120 cells
generated for the purpose, in batch Emacs: the same key commands on 2.5.1 and on
the fix, each run on its own with a time limit. Counting calls to
`ess-code-end-position` (one per step of the loop) with an error past 2,000 turns
the endless loop into a failure with a backtrace of the same shape as the
reporter's.

## Goals / Non-Goals

**Goals:**
- Prose and output still cannot open or close a string, comment or pair.
- Whitespace in them reads as whitespace, to the same degree as in code.
- No cost the user can see.

**Non-Goals:**
- No change to which text is code, to fontification, or to indentation rules.
- No change in ESS or any other package.

## Decisions

- **A `syntax-table` text property may be a whole syntax table, so use one.** Every
  character of a prose or output span gets a char-table in which all characters
  are punctuation, except the ASCII characters the buffer's own syntax table gives
  the whitespace or comment-end class, which are copied from it. The newline is
  therefore whatever the language says it is (comment-end for R, Python and
  Julia), and `forward-comment` treats one that ends no comment as whitespace.
  The property is still a single value over each span, so the number of text
  property intervals is what it was.
- **Built from, and cached against, the buffer's syntax table.** Copying from the
  buffer's table rather than hard-coding a class keeps this right for a language
  whose newline is not a comment end. The table is kept in a buffer-local variable
  with the table it came from, and rebuilt when the buffer's table changes.
  Spans propertized earlier keep the old table; that is harmless because only
  whitespace differs.
  Alternatives considered:
  - *Narrow the buffer to the cell around indentation.* Rejected: it stops the walk
    at the top of a code cell, but not inside a markdown cell, where the previous
    line is also prose; it also changes `point-min` for every after-change hook.
  - *Leave whitespace without a property.* Rejected: a property per run of
    whitespace multiplies the intervals in the buffer by the number of words in
    every output.
  - *Turn off `electric-indent` for notebooks.* Rejected: it removes only RET as
    the trigger. TAB hangs the same way, and so would anything else that calls the
    indenter or walks back.
  - *Advise ESS.* Rejected: it is not jsonyter's code, and the invariant is
    reasonable.
- **Comment end rather than whitespace for the newline.** It is the language's own
  entry, so `skip-syntax-backward` over blanks stops at a newline in prose exactly
  as it does in code. No comment can start in the text, so a comment-end there
  closes nothing.

## Risks / Trade-offs

- Whitespace characters outside ASCII (a no-break space) stay punctuation, as they
  were. Nothing known walks back over them.
- A language mode that gives the newline a meaning other than whitespace or
  comment-end keeps it only if it is in one of those two classes; others are
  punctuation as before.
- Verified with ESS only. Other modes whose indentation or motion finds the end of
  the previous line with `forward-comment` should now behave, but were not
  available to run.
- Measured on a 227,000-character notebook, propertizing the whole buffer takes
  0.8 ms against 0.6 ms, and filling the whole notebook with font-lock about 50 ms
  either way; opening and every edit are unchanged.
