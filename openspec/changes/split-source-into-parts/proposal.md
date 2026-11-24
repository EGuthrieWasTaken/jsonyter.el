# Proposal

## Why

`jsonyter.el` had grown to a single 9,800-line file, with fourteen
sections of unrelated concerns (the bridge process, notebooks, file
transfer, directory sync, Org, export) that already announced their own
boundaries in `;;;;` headings. One file is hard to navigate, hard to review
in a diff, and makes every change to any surface a change to "the" file.

## What Changes

- `jsonyter.el` becomes the entry point: the package header (including
  `;; Version:`), the Commentary, and `require`s of every part.
- The code moves, unchanged, into `jsonyter-custom`, `-core`, `-repl`,
  `-attach`, `-notebook`, `-latex`, `-transfer`, `-sync`, `-script`, `-org`,
  `-babel`, `-convert` and `-export`, along the existing section boundaries.
- Each part requires what it uses and `declare-function`s the few
  functions defined in a part that loads after it.
- User options and minor modes in the parts gain an explicit
  `:group 'jsonyter`, since they no longer share a file with `defgroup`.
- `jsonyter-version` still reads the header of `jsonyter.el`, found next to
  the file being compiled or loaded.
- CI, README install instructions and the OpenSpec config follow: the
  version check watches `jsonyter-*.el` too, the release attaches every
  part, coverage instruments `jsonyter*.el`, and the manual install clones
  the tag instead of downloading one file.

Surfaces affected: all, by file layout only. No behavior change, no bridge
protocol change, no change to the minimum bridge version. Anyone loading
`jsonyter.el` by itself rather than as a directory on `load-path` must now
have the whole directory.

## Capabilities

### New Capabilities
- `package-layout`: how the package is divided into files and how they load.

### Modified Capabilities

## Impact

- `jsonyter.el` and thirteen new `jsonyter-*.el` files.
- `test/jsonyter-tests.el`: version tests follow the new files; new tests
  check every part is required, loads on its own, and groups its options.
- `.github/workflows/{coverage,release,version-check}.yml`, `README.md`,
  `openspec/config.yaml`.
