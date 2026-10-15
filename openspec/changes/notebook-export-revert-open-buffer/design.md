# Design

## Context

`jsonyter-notebook-export` (jsonyter.el, around line 9407) builds its
request from the live buffer and hands it to `jsonyter--export-run`, whose
`on-success` callback (a lambda closed over nothing but the result) only
formats the success message today — see proposal.md for why that's not
enough. The bridge's result plist, exercised by
`jsonyter-test-notebook-export-reports-path-and-size`, always carries
`:path` (the file actually written — for most formats the same as
`TO-PATH`, but `export_notebook` is free to normalize it) and, for a
bundled export (markdown/html with images), a `:resources` vector of
plists each carrying its own `:path`. `TO-PATH` itself is never guaranteed
to be what was written and so is not a reliable key to revert by.

## Goals / Non-Goals

**Goals:**
- Any already-open buffer visiting a path the export just wrote ends up
  showing that content, without ever discarding unsaved edits in it
  without the usual confirmation.
- No behavior change when nothing is open on those paths.

**Non-Goals:**
- Reverting a non-file buffer, an indirect buffer, or a buffer visiting the
  path via a different (non-canonical) filename spelling — `find-buffer-visiting`
  already resolves that via `file-truename`, so nothing extra is needed.
- Any change to what the bridge writes or to `export_notebook`'s protocol.
- Auto-reverting on a timer/watch; this only fires right after this
  Emacs session's own export call.

## Decisions

- **Drive the revert off the result's own `:path`/`:resources`, not
  `TO-PATH`.** `TO-PATH` is what was asked for; `:path` (and each
  resource's `:path`) is what was actually written, confirmed by the
  existing success-message code which already prefers `:path` for the
  same reason. Reverting by the requested path could miss or wrongly skip
  the real file a format normalizes to a different name.
- **One small helper, `jsonyter--revert-if-visiting`, called once per
  written path from `jsonyter-notebook-export`'s `on-success`.** Keeps the
  lookup (`find-buffer-visiting`) and the confirm-aware revert in one
  place rather than inlined in the message-formatting lambda.
- **Confirmation follows modification state, not a blanket prompt or a
  blanket skip.** An unmodified buffer is reverted with `noconfirm' t — the
  user has made no edits to lose, and prompting for a plain refresh after
  every export would be noise. A modified buffer is reverted with
  `noconfirm' nil, which is exactly the "Buffer ... modified; revert
  anyway?" prompt `M-x revert-buffer` already gives; declining it leaves
  the buffer exactly as it was. Alternative considered: always skip a
  modified buffer silently — rejected, since the spec's "never silently
  clobber" only requires asking, not refusing outright, and a hard skip
  would leave the user unaware their view is now stale for a reason
  distinct from "nothing to revert."
- **Errors from reverting one buffer don't stop the rest.** Reverting is
  best-effort cleanup after a successful export that has already
  succeeded and already been reported; a `file-missing` or permission
  error on one buffer's revert must not swallow or interfere with the
  export's own success message, and must not stop a later path (e.g. a
  second bundle resource) from being tried.

## Risks / Trade-offs

- A buffer visiting a bundle resource by coincidence (same path, unrelated
  to this export) still gets reverted → acceptable: the file at that path
  really did just change on disk, so reflecting it is correct regardless
  of why the buffer had it open.
- Iterating `:resources` on every export adds a few `find-buffer-visiting`
  calls (no-ops when nothing matches) → negligible next to an nbconvert
  render that already takes seconds.
