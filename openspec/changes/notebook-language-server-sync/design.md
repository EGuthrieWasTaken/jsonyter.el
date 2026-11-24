# Design

- **Report, don't un-silence.** Dropping `with-silent-modifications` would
  put output in the undo history and flip the modified flag, which the
  notebook deliberately avoids. Instead the write is wrapped: hooks off
  for the write itself, then run by hand once, in the order Emacs runs them
  for a replacement (before with the old region, after with the new end
  and old length). `jsonyter--nb-cell-surgery` stays bound so this
  package's own hook stands down as before.
- **Failures are contained.** A third-party tracker that signals must not
  stop output from appearing, so each hook run is wrapped and the error is
  shown as a message.
- **Narrowing for indentation, not for everything.** Only
  `indent-line-function` is advised: `syntax-ppss` keeps a separate parse for
  a narrowed buffer, which is what isolates the cell. The three
  `indent-relative` functions are never advised, since `TAB` and
  `indent-according-to-mode` recognise them by identity. `indent-region` is
  left alone; it calls the line function per line.
- **Not done:** whether the reported hundred spaces come from a language
  server is unconfirmed, as it was when reported (the real R server could
  not be run); the sync defect is the one that was demonstrated.
