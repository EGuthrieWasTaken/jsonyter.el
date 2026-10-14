# Spec Delta

## Purpose

Defines how `jsonyter-notebook-export` behaves in Emacs once the bridge has
written an export to disk, so a buffer already visiting the written file
never keeps showing a stale, pre-export view.

## ADDED Requirements

### Requirement: A buffer visiting an export's written path is reverted
After `jsonyter-notebook-export` (or a format-specific wrapper) succeeds,
for each path the bridge reports it actually wrote — the main `:path` and,
for a bundled export, every `:resources` entry's `:path` — any live,
unmodified buffer visiting that path SHALL be reverted so its contents
match what was just written.

#### Scenario: Buffer visiting the destination file
- **WHEN** a buffer is visiting the file at the export's reported `:path`, and the export succeeds
- **THEN** that buffer is reverted and displays the newly written content

#### Scenario: Buffer visiting a bundle resource
- **WHEN** a bundled export's result lists a `:resources` entry and a buffer is visiting that resource's `:path`
- **THEN** that buffer is reverted too

#### Scenario: No matching buffer
- **WHEN** no live buffer is visiting any path the export wrote
- **THEN** nothing is reverted and no new buffer is created or displayed

### Requirement: A modified buffer is never silently reverted
A live buffer visiting a written path that has unsaved changes of its own
SHALL NOT be reverted without the confirmation `revert-buffer` already
requires for a modified buffer.

#### Scenario: Buffer has unsaved edits
- **WHEN** a buffer visiting an export's written path has unsaved changes
- **THEN** reverting it goes through the same confirmation `M-x revert-buffer` would require, and its edits are not discarded without that confirmation
