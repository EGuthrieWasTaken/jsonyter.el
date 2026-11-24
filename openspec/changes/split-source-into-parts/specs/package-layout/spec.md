# Spec Delta

## Purpose

How the package is divided into files, so that loading, versioning and
packaging stay predictable.

## ADDED Requirements

### Requirement: jsonyter.el loads the whole package
`(require 'jsonyter)` SHALL load every part. `jsonyter.el` SHALL carry the
package header, including the `;; Version:` line, and every
`jsonyter-NAME.el` in the directory SHALL be required by it.

#### Scenario: A part is added
- **WHEN** a new `jsonyter-NAME.el` is added to the package
- **THEN** a test fails until `jsonyter.el` requires it

### Requirement: Each part loads on its own
`(require 'jsonyter-NAME)` in a fresh Emacs SHALL succeed for every part,
loading what it needs, without any other part having been loaded first.

#### Scenario: Loading one part
- **WHEN** a fresh `emacs -Q` requires `jsonyter-sync`
- **THEN** it succeeds, and its dependencies are loaded as a consequence

### Requirement: Options are grouped
Every user option and face in every part SHALL belong to the `jsonyter`
customization group.

#### Scenario: Customizing
- **WHEN** a user runs `M-x customize-group RET jsonyter`
- **THEN** options from every part are listed

### Requirement: The version is the header's
`jsonyter-version` SHALL equal the `Version:` header of `jsonyter.el`, also
when the package is byte-compiled and the sources are gone.

#### Scenario: Compiled install
- **WHEN** every part is byte-compiled and the `.el` files are removed
- **THEN** `jsonyter-version` still reports the header's version
