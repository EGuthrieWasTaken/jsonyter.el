# Design

## Context

jsonyter.el is one file with a `Version:` header that the release checks keep in
step with the README. The Python package is a separate project; the only bridge
facts available are in its source: `jsonyter.__version__`, a `version` JSON method
that returns the Jupyter server's `/api` document, a `methods` method that lists
names, and a command line with no `--version`.

## Goals / Non-Goals

**Goals:**
- One place the jsonyter.el version is written down, as it is now.
- The answer describes the code that is loaded.
- Works with nothing open, and never signals an error because the Python side
  cannot be inspected.

**Non-Goals:**
- No change to the Python package, and so no exact "the running bridge process's
  version": the report names the package the bridge command would start.
- No minimum-version check; the README states the minimum.

## Decisions

- **The version is read from the header by a macro, at compile or load time.** The
  alternatives were a literal constant kept in step by hand (a fourth place to
  edit on every release, with a test as its only guard) and reading the header
  from disk when asked (which reports the new version from old code after an
  in-place upgrade, the confusion this exists to clear up). The macro reads the
  file being compiled, or loaded as source, and expands to a string, so a
  compiled file keeps its own version with the source gone. If the file cannot be
  found while the macro expands, the value is `"unknown"` and a test would show it.
- **The Python package is asked through its interpreter.** `jsonyter-command`
  names either an interpreter (`python3 -m jsonyter`) or an entry-point script.
  For the first the interpreter is the first word; for a script it is the one on
  the script's first line (`#!/path/python`, `#!/usr/bin/env python3`, or the
  `/bin/sh` form pip writes for long paths). The code run is
  `import jsonyter`, then `__version__` with `importlib.metadata` as the fallback,
  printing the package's and Python's versions. A shell launcher is not taken for
  a Python.
  Alternatives considered:
  - *Ask the running bridge.* Not possible: no verb reports it.
  - *`jsonyter --version`.* Not in the package today. If it is added, trying it
    first would be exact for any launcher; until then it would only add a failing
    process.
  - *Add the verb to the Python package.* A change to another project and a
    higher minimum bridge version; not worth it for a diagnostic.
- **The probe is bounded and out of process.** It runs in a short-lived process and
  waits at most ten seconds, so a hung interpreter or a slow filesystem cannot
  freeze Emacs. The current directory is dropped from the import path so a stray
  `jsonyter/` directory is not imported in place of the package, as it would not
  be when the entry-point script starts the bridge.
- **The server's version is only asked for when it is free.** `jsonyter-version-full`
  uses the current buffer's bridge if one is live, with a short timeout, and
  otherwise says "not connected from this buffer". The server's address is left
  out of the report so it can be pasted into a public issue.
- **Two commands, as `emacs-version` does.** A prefix argument inserts, and the
  report is also the return value.

## Risks / Trade-offs

- Importing `jsonyter` needs its dependencies (`requests`, `websocket-client`,
  `nbformat`), so a half-installed package reports "No module named ..." instead
  of a version. That is true to what starting the bridge would do.
- The version is that of the installed package, not of an already-running bridge
  process that was started before an upgrade of the Python package.
- A launcher that is neither an interpreter nor a script with a recognisable first
  line (a Windows `.exe`, `uvx`) gets "cannot tell which Python runs ...".
