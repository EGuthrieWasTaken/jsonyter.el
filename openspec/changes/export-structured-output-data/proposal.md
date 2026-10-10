# Proposal

## Why

Exporting a notebook (`C-c C-x`, `jsonyter-notebook-export`) fails with
`wrong type argument: sequencep, :width` whenever any cell's stored output
carries image metadata such as `{"image/png": {"width": 300, "height": 200}}`
(Retina figures, `IPython.display.Image(width=...)`). The same code path also
crashes on any JSON mimetype in an output's data (`application/json`,
plotly/altair `application/vnd.*+json`), and silently corrupts array-valued
metadata (`"tags": ["a", "b"]` becomes `"ab"`). A previous fix handled
nbformat's list-of-lines strings but treated every list in `data` and
`metadata` as one.

## What Changes

- Output `metadata` is converted for the wire as real JSON: objects stay
  objects, arrays become arrays, nothing is joined.
- In an output's `data`, a value under a JSON mimetype (`application/json`,
  `*+json`) is converted as real JSON; a value under any other mimetype that
  is a list of strings is still joined into one string (nbformat's
  multi-line-string form); a non-string list under such a mimetype is
  converted as JSON instead of crashing.
- Export (and save-with-outputs, which shares the path) no longer signals for
  these notebooks, and what reaches the bridge is the same JSON structure the
  file holds.

Surfaces affected: notebook (.ipynb) export and `export_notebook` request
building; all kernel languages equally. No bridge protocol change; the
minimum bridge version is unchanged.

## Capabilities

### New Capabilities
- `notebook-export`: what gets sent to the bridge when a notebook is exported,
  so that stored outputs of any shape survive the trip.

### Modified Capabilities

## Impact

- `jsonyter.el`: `jsonyter--nb-data-for-wire`, `jsonyter--nb-output-for-wire`,
  plus one new private recursive converter.
- `test/jsonyter-tests.el`: new tests.
- `README.md`: one sentence in "Exporting notebooks".
