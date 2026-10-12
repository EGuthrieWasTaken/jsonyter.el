# Proposal

## Why

There is no way to ask jsonyter which version is running. While chasing the
reported newline hang the question "did the upgrade take?" had to be answered by
probing for functions that only some versions define, and the version of the
Python package under jsonyter.el, which a bug report needs just as much, could not
be had without leaving Emacs.

## What Changes

- New command `jsonyter-version`: shows, and returns, a line such as
  `jsonyter.el v2.5.2 running on jsonyter v2.1.1`.
- New command `jsonyter-version-full`: the same plus the file jsonyter.el was loaded
  from, the Python version, the Jupyter server's version when the current buffer
  has a live bridge, and Emacs's version and system.
- A prefix argument inserts the report at point instead of showing it.
- New variable `jsonyter-version`: the jsonyter.el version as a string, taken from
  the file's `Version:` header when the file is compiled or loaded, so it names
  the code that is running rather than whatever is on disk now.
- The Python package's version comes from the interpreter that starts the bridge,
  because the bridge protocol has no verb for it: its `version` method reports
  the Jupyter server's version, and its command line has no `--version`. When it
  cannot be found the report says why instead of failing.
- README: a short section on checking what you are running.

Surfaces affected: all of jsonyter.el; the commands work with no REPL or notebook
open. No bridge protocol change; minimum bridge version unchanged.

## Capabilities

### New Capabilities
- `version-reporting`: how the user finds out which jsonyter.el and which jsonyter
  Python package they are running.

### Modified Capabilities

## Impact

- `jsonyter.el`: a "Version" section with the two commands, the variable and the
  helpers that find and ask the interpreter; autoload cookies.
- `test/jsonyter-tests.el`: nine tests, with a shell script standing in for Python.
- `README.md`: the new section.
