# Spec Delta

## Purpose

Defines how a user finds out which jsonyter.el and which jsonyter Python package
they are running.

## ADDED Requirements

### Requirement: jsonyter.el reports the version of the code that is loaded
The variable `jsonyter-version` SHALL hold the version in the `Version:` header of
jsonyter.el as a string, fixed when the file is compiled or loaded, so that a
compiled file reports its own version even when the source file is absent.

#### Scenario: Loaded from source
- **WHEN** jsonyter.el is loaded
- **THEN** `jsonyter-version` equals the file's `Version:` header

#### Scenario: Compiled, with the source gone
- **WHEN** a compiled copy is loaded and the source file has been deleted
- **THEN** `jsonyter-version` still equals the header it was compiled from

### Requirement: `jsonyter-version` names the Python package the bridge would run
`M-x jsonyter-version` SHALL show, and return, a line naming the version of
jsonyter.el and of the jsonyter Python package that `jsonyter-command` starts,
found by asking the interpreter that starts it, without a REPL or notebook open.
It SHALL work with `jsonyter-command` naming an interpreter and with it naming an
entry-point script, whatever form the script's first line takes.

#### Scenario: An interpreter and `-m`
- **WHEN** `jsonyter-command` is an interpreter followed by `-m jsonyter` and the package is 9.8.7
- **THEN** the report is "jsonyter.el v" and the file's version, then " running on jsonyter v9.8.7"

#### Scenario: An entry-point script
- **WHEN** `jsonyter-command` is a script whose first line names an interpreter directly, through `/usr/bin/env`, or in pip's `/bin/sh` form
- **THEN** that interpreter is the one asked

### Requirement: Not finding the Python package's version is reported, not signalled
When the package's version cannot be found the report SHALL still name jsonyter.el's
version and SHALL say why the other is unknown. The command SHALL NOT signal an
error, and SHALL NOT wait on an interpreter that does not answer for more than the
probe's timeout.

#### Scenario: The package cannot be imported
- **WHEN** the interpreter reports that the module is missing
- **THEN** the report ends "bridge version unknown (" followed by Python's own last line

#### Scenario: No such program, or a shell launcher
- **WHEN** `jsonyter-command` names a program that does not exist, or a script that starts with a shell
- **THEN** the report says it cannot tell which Python runs the command

#### Scenario: An interpreter that never answers
- **WHEN** the interpreter does not finish within the timeout
- **THEN** the report says it did not answer, and the command returns within a few seconds of the timeout

### Requirement: `jsonyter-version-full` adds what a bug report needs
`M-x jsonyter-version-full` SHALL add to the `jsonyter-version` report the file
jsonyter.el was loaded from, the Python version, the Jupyter server's version when the current
buffer has a live bridge and the server answers, and Emacs's version and system. It
SHALL NOT include the server's address.

#### Scenario: No bridge in the buffer
- **WHEN** the current buffer has no live bridge
- **THEN** the report says the server is not connected from this buffer

#### Scenario: A live bridge
- **WHEN** the buffer's bridge answers a version request with 2.14.2
- **THEN** the report contains "Jupyter server 2.14.2"

### Requirement: A report can be inserted
With a prefix argument either command SHALL insert its report at point and show
nothing; without one it SHALL show the report and leave the buffer alone.

#### Scenario: With and without a prefix argument
- **WHEN** the command is called interactively, then again with a prefix argument
- **THEN** the first shows the report and the second inserts it
