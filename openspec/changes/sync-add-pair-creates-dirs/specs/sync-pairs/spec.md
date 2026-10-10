# Spec Delta

## Purpose

Defines how a sync pair (a local directory mirrored with a Jupyter server's
Contents-API directory) is added, so that a pair never points at a directory
that does not exist.

## ADDED Requirements

### Requirement: Adding a pair creates a missing local directory
When `jsonyter-sync-add-pair` is asked to create directories, a local directory
that does not exist SHALL be created, parents included, before the pair is
recorded.

#### Scenario: Local directory is missing
- **WHEN** a pair is added with creation requested and its local directory does not exist
- **THEN** the directory and all missing parents exist afterwards and the pair is recorded

#### Scenario: Local directory already exists
- **WHEN** a pair is added with creation requested and its local directory exists
- **THEN** the directory is left untouched and the pair is recorded

### Requirement: Adding a pair creates a missing remote directory
When asked to create directories, `jsonyter-sync-add-pair` SHALL create every
missing level of the remote path on the server, outermost first, before the
pair is recorded, and SHALL NOT touch levels that already exist.

#### Scenario: Remote directory and a parent are missing
- **WHEN** the remote path is `work/new/deep`, `work` exists and `work/new` does not
- **THEN** `work/new` is created, then `work/new/deep`, in that order, and the pair is recorded

#### Scenario: Remote directory already exists
- **WHEN** the remote path already exists as a directory
- **THEN** no directory is created on the server

#### Scenario: Remote path is the contents root
- **WHEN** the remote path is empty (the contents root)
- **THEN** the server is not contacted for directory creation

### Requirement: A remote path that is a file is refused
If any level of the remote path exists on the server and is not a directory, the
command SHALL signal a `user-error` naming the path and SHALL NOT record the pair.

#### Scenario: Remote path is a file
- **WHEN** the remote path `work/data.csv` exists on the server as a file
- **THEN** a `user-error` is signalled and `jsonyter-sync-pairs` is unchanged

### Requirement: Lisp callers must opt in to directory creation
Calling `jsonyter-sync-add-pair` from Lisp SHALL NOT create or contact anything
unless the caller passes a non-nil `CREATE-DIRS` argument; calling it
interactively SHALL behave as if `CREATE-DIRS` were non-nil.

#### Scenario: Lisp call without the opt-in
- **WHEN** a Lisp program adds a pair for directories that do not exist, without `CREATE-DIRS`
- **THEN** nothing is created and the server is not contacted

#### Scenario: Interactive call
- **WHEN** the command is invoked interactively with a missing local and remote directory
- **THEN** both are created before the pair is recorded
