# Spec Delta

## Purpose

Defines how a notebook's stored cell outputs are reshaped for the bridge on
export, so that any valid nbformat output can be exported without error and
without changing its meaning.

## ADDED Requirements

### Requirement: Output metadata is sent as structured JSON
An output's `metadata` SHALL be sent to the bridge with objects as objects and
arrays as arrays, at any depth. No list under `metadata` SHALL be joined into a
string.

#### Scenario: Image size metadata
- **WHEN** a notebook is exported and an output has metadata `{"image/png": {"width": 300, "height": 200}}`
- **THEN** the export request is built without error and carries that object unchanged

#### Scenario: Array-valued metadata
- **WHEN** an output has metadata `{"tags": ["a", "b"]}`
- **THEN** the request carries `tags` as the array `["a", "b"]`, not the string `"ab"`

### Requirement: JSON mimetypes in output data are sent as structured JSON
A value in an output's `data` under `application/json` or any mimetype ending
in `+json` SHALL be sent as structured JSON, objects as objects and arrays as
arrays at any depth.

#### Scenario: Plotly-style output
- **WHEN** an output's data has `application/vnd.plotly.v1+json` holding an object with a `data` array of objects
- **THEN** the request carries the same nesting, with every array still an array

### Requirement: Multi-line text values are still joined
A value in an output's `data` under any other mimetype that nbformat stored as
a list of strings SHALL be sent as the single string those fragments
concatenate to; a string value SHALL be sent unchanged.

#### Scenario: Text stored as lines
- **WHEN** an output's data has `text/plain` stored as `["a\n", "b"]`
- **THEN** the request carries the string `"a\nb"`

### Requirement: Export request building never fails on stored outputs
Building the cell list for export from a notebook whose outputs contain any of
the shapes above SHALL succeed, and the result SHALL be serializable to JSON.

#### Scenario: Notebook mixing all shapes
- **WHEN** a notebook with one image output with size metadata and one JSON-mimetype output is collected for export
- **THEN** collecting and serializing the cells signals no error
