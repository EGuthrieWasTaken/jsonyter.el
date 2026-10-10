# Design

## Context

`jsonyter-sync-add-pair` (jsonyter.el) reads its arguments in an `interactive`
form and then only pushes a plist onto `jsonyter-sync-pairs`. The remote half is
read by `jsonyter--read-remote-path`, which completes against existing
directories but accepts anything typed. The Contents API has no recursive
create: `make_directory` creates exactly one level and fails when the parent is
missing. Existing tests call the command from Lisp with fictitious paths
(`/tmp/proj`, `work/proj`) and no bridge, and must keep passing unchanged.

## Goals / Non-Goals

**Goals:**
- A pair added interactively always refers to real directories on both sides.
- Fail before recording anything when the remote path is blocked by a file.

**Non-Goals:**
- No change to `jsonyter-sync` itself, to pair storage, or to the bridge.
- No confirmation prompt before creating a directory (the user typed the path
  into a directory prompt; a message reports what was created).

## Decisions

- **Opt-in argument, interactive form passes `t`.** Rather than creating
  directories unconditionally in the body, which would make Lisp callers (and
  the existing tests) touch the file system and the network. Alternative:
  a defcustom. Rejected as more surface than the bug warrants.
- **Two private helpers** `jsonyter--sync-ensure-local-dir` and
  `jsonyter--sync-ensure-remote-dir`, so each side is testable alone and the
  interactive-form test can stub them.
- **Remote mkdir -p by probing.** For each cumulative prefix of the remote path
  (`a`, `a/b`, `a/b/c`) call `list_contents`; a bridge error means missing, so
  call `make_directory` for that prefix; a successful reply whose `:type` is not
  `"directory"` means a file is in the way. Alternative: call `make_directory`
  for every level and ignore "already exists" errors, rejected because the error
  shape for an existing directory is server-specific.
- **Order: local first, then remote, both before `push`.** An error on either
  side leaves `jsonyter-sync-pairs` untouched.
- **Which buffer talks to the server.** The body re-resolves
  `jsonyter--resolve-transfer-context` and uses its buffer
  (`jsonyter--request-sync` must run in the owning buffer, as
  `jsonyter--remote-children` does).

## Risks / Trade-offs

- A typo creates a stray directory → the message names every directory created,
  and `jsonyter-sync-forget-pair` plus a manual delete undoes it.
- `list_contents` on a missing path may be slow on a far-away server → at most
  one probe per level of the path, and only when the command is used.
