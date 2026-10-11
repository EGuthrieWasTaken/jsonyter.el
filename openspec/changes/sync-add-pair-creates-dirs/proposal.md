# Proposal

## Why

`M-x jsonyter-sync-add-pair` reads a local directory and a remote (Contents-API)
directory, but both prompts accept a path that does not exist yet, and the
command then records a pair pointing at nothing. The first `jsonyter-sync`
against that pair fails or silently syncs an empty tree. A user setting up a
new project mirror has to leave the command, create both directories by hand
(one of them through `jsonyter-remote-dired-mkdir`), and start over.

## What Changes

- `jsonyter-sync-add-pair`, when called interactively, creates the local
  directory (with parents) if it is missing, and creates the remote directory
  (with parents, `mkdir -p` style, one Contents-API `make_directory` per missing
  level) if it is missing, *before* the pair is recorded.
- A remote path that exists but is a file is refused with a `user-error`, and no
  pair is recorded.
- Lisp callers keep the old behaviour by default: a new optional fifth argument
  `CREATE-DIRS` opts in; the interactive form passes `t`.

Surfaces affected: sync pairs (any notebook, REPL, script or Org session can
invoke the command). Kernel languages: none. No bridge protocol change: it only
uses the existing `list_contents` and `make_directory` verbs. Minimum bridge
version unchanged.

## Capabilities

### New Capabilities
- `sync-pairs`: how sync pairs are defined, including directory creation when a
  pair is added.

### Modified Capabilities

## Impact

- `jsonyter.el`: `jsonyter-sync-add-pair` plus two small private helpers next to
  it.
- `test/jsonyter-tests.el`: new tests; one existing interactive-form test is made
  hermetic.
- `README.md`: the sync-pairs section.
