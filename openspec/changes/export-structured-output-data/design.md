# Design

## Context

`jsonyter--nb-collect-cells` (with ALL-OUTPUTS) feeds a notebook's stored
outputs through `jsonyter--nb-output-for-wire` into `json-serialize`.
The notebook was parsed with `:object-type 'plist :array-type 'list`, so
after parsing an object and an array are both Lisp lists, told apart only by
whether the car is a keyword. `json-serialize` accepts a plist as an object
and a *vector* as an array, never a list as an array. Today
`jsonyter--nb-data-for-wire` is used for both `:data` and `:metadata` and
treats every list as nbformat's list-of-lines, joining it with `mapconcat`,
which signals on any plist (a keyword is not a sequence).

## Goals / Non-Goals

**Goals:**
- Any nbformat-valid output exports without error and without changing
  meaning.

**Non-Goals:**
- Not touching the parse (`jsonyter--nb-parse`) or the save-without-outputs
  path.
- Not distinguishing an empty object from an empty array: both parse to nil
  and serialize alike; the file never needed the distinction here.

## Decisions

- **One recursive converter, `jsonyter--nb-json-for-wire`.** Plist (non-nil
  list whose car is a keyword) stays a plist with converted values; any other
  non-nil list becomes a vector of converted elements; vectors are mapped;
  atoms are unchanged. Alternative: parse with `:array-type 'array` everywhere
  — rejected, it would ripple through all consumers of parsed cells.
- **JSON-ness is decided by mimetype name.** nbformat stores only non-JSON
  mimetypes as line lists, so a key containing "json" (case-insensitive) is
  real JSON. Alternative: guess by "all elements are strings" — rejected,
  `application/json` may hold an array of strings.
- **Metadata is always real JSON.** nbformat never line-splits metadata.

## Risks / Trade-offs

- A non-JSON mimetype holding a non-string list is converted as JSON, not
  joined → no crash; the bridge/nbformat decide validity.
- Empty arrays/objects both serialize as `{}` → pre-existing, unchanged.
