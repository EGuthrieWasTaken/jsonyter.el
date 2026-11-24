# Design

- **One capf, four contexts.** What differs between surfaces is only where
  the code at point is. Each mode registers a function returning a plist
  (`:code :pos :start :session`, plus `:patient` for the REPL), so the
  capf, inspect and Eldoc code are written once.
- **Never block typing.** The request is synchronous (the bridge call is),
  so the safeguards are: no live or idle kernel means nil; a short timeout
  away from the REPL; and after one failure a quiet period, instead of a
  wait per keystroke. The REPL keeps `jsonyter-request-timeout` because TAB
  is deliberate there.
- **Reorder, don't filter.** Argument names are moved to the front through
  the table's `display-sort-function` metadata, so a typed prefix reaches
  everything. The table is a plain list whenever no reordering applies, so
  existing consumers that read the candidates keep working.
- **Call detection is a small scanner**, not the language's parser: it
  tracks brackets, strings and `#` comments, and treats a `(` as a call
  when it follows a name or the end of a call or subscript. A wrong guess
  only changes the order of candidates.
- **Help shorthand is client-side.** It works with the bridge as it is for
  any kernel that implements `inspect`; forwarding IPython's `page`
  payloads would be a bridge change. Only the exact single-line forms
  match, and any failure falls back to sending the input.
- **Unverified for R**: IRkernel's `complete` and `inspect` replies. The
  argument predicate is configurable per language for that reason.
