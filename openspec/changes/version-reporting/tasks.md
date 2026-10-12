# Tasks

## 1. Implement

- [x] 1.1 `jsonyter-version` variable from the header at compile or load time; verify it equals the header from source and from a compiled copy with the source deleted
- [x] 1.2 Find the interpreter behind `jsonyter-command` (an interpreter, or a script's first line) and ask it for the package's version; verify with the real package and with the failure cases
- [x] 1.3 `jsonyter-version` and `jsonyter-version-full`, autoloaded, with insertion on a prefix argument

## 2. Tests

- [x] 2.1 Nine tests with a shell script standing in for Python: header, compiled copy, autoload, the interpreter forms, the failure explanations, the timeout, the full report with a live bridge, insertion
- [x] 2.2 Full ERT suite green apart from the known `kernel-activity-formats-or-falls-back` failure

## 3. Docs

- [x] 3.1 README section "Checking what you are running"
