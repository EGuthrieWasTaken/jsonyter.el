# Bug report: exporting a notebook that contains images

**Status:** open
**Date:** 2026-09-18
**Affects:** `jsonyter.el` 2.4.0 (this repo)
**Verified against:** GNU Emacs 29.3 (`-Q --batch`), `jsonyter` bridge 2.1.0,
`nbformat` 5.11.1, `nbconvert` 7.17.1
**Severity:** blocking — `M-x jsonyter-notebook-export` and every
`jsonyter-notebook-export-*` wrapper fail outright on any notebook whose stored
outputs contain a figure
**Tests added:** `test/jsonyter-tests.el`, sections "Export and the wire" and
"Org results survive the trip into a notebook" (8 tests, all
`:expected-result :failed`)

---

## 0. Summary

Five separate defects sit under the reported symptom. They are independent and
can be fixed independently, but **defect 1 is the one that makes export fail**,
and defect 2 is the one that makes an export come out with no images in it.

| # | Defect | Effect | Severity |
| --- | --- | --- | --- |
| 1 | `jsonyter--nb-collect-cells` sends nbformat's list-of-lines values to `json-serialize` | export dies in Emacs, before the bridge | blocking |
| 2 | `jsonyter--org-parse-results-drawer` returns nbformat-shaped outputs, `jsonyter--nb-output-to-spec` reads kernel-shaped ones | every Org result, images included, becomes `[jsonyter: unrecognized output type nil]` | high |
| 3 | `--by-block` spans stop at `#+end_src` | a hand-written Org file's results are dropped entirely | high |
| 4 | export sends `:cells`, never the notebook's `metadata` | nbconvert gets a notebook with no `kernelspec`/`language_info` | medium |
| 5 | the bridge's toolchain hint is keyed on format, not on cause | every `pdf` failure reads as "no TeX environment" | medium (diagnostics) |

Defects 1–4 are in this repository. Defect 5 is in the `jsonyter` Python
bridge, but `jsonyter.el` is where it surfaces, and it is what made the real
cause of the reported PDF failure impossible to see; see §5.

---

## 1. Defect 1 — a notebook's stored outputs cannot be put on the wire

### 1.1 What happens

```
M-x jsonyter-notebook-export-pdf RET ~/report.pdf RET
  => Wrong type argument: consp, nil
```

Nothing is sent. The bridge is never contacted, the Jupyter server is never
contacted, and no `export_notebook` request exists to fail. The error comes
from `json-serialize` inside `jsonyter--send` (`jsonyter.el:937`).

### 1.2 Why images are what trigger it

`jsonyter--nb-parse` (`jsonyter.el:2801`) parses the notebook with
`:array-type 'list`, so every JSON array in the file becomes a Lisp list.
`jsonyter--nb-make-cell` (`jsonyter.el:3105`) stores the cell's outputs
verbatim on the `jsonyter-file-outputs` overlay property, and
`jsonyter--nb-collect-cells`'s ALL-OUTPUTS branch (`jsonyter.el:3353`) hands
them back out verbatim:

```elisp
((and include-outputs all-outputs code-p)
 (list :outputs (vconcat (overlay-get cell 'jsonyter-file-outputs))
       :execution_count (or (overlay-get cell 'jsonyter-exec-count) :null)))
```

The `vconcat` makes the *outer* list a vector. Everything nested inside stays a
list — and Emacs's native `json-serialize` cannot tell a list meant as a JSON
array from a malformed plist or alist, so it signals instead of encoding one.

This is exactly the hazard §"Reshaping a plan for the wire (bridge §8.1)"
already documents at `jsonyter.el:5322`, and which
`jsonyter--sync-plan-for-wire` exists to solve for `sync_apply`. The export
path has no equivalent.

Every notebook Jupyter has ever saved a matplotlib figure into hits it,
because a figure is written as:

```json
{"output_type": "display_data",
 "data": {"image/png": "iVBORw0KGgo...",
          "text/plain": ["<Figure size 640x480 with 1 Axes>"]},
 "metadata": {"needs_background": "light"}}
```

The `text/plain` companion is an **array**. So is a `text/plain` repr of a
DataFrame, a `text/html` table, an `image/svg+xml` figure, an `error`
output's `traceback`, and a `stream` output's `text`. An `image/png` itself is
usually a single string, but nbformat permits the split form too and some
writers produce it.

Concretely, four shapes all fail:

| nbformat shape | `json-serialize` result |
| --- | --- |
| `"text/plain": ["<Figure ...>"]` | `Wrong type argument: consp, nil` |
| `"image/png": ["iVBO", "Rw0K"]` | `Wrong type argument: symbolp, "iVBO"` |
| `"text": ["a\n", "b\n"]` (stream) | `Wrong type argument: symbolp, "a\n"` |
| `"traceback": ["...", "..."]` (error) | `Wrong type argument: symbolp, "..."` |

### 1.3 Reproduction

The repository's own harness fixtures already carry the failing shape —
`harness/profile/fixtures/solid-plot.ipynb` and `demo.ipynb` both store
`text/plain` as a list. End to end, against the real bridge:

```elisp
;; emacs -Q --batch -L . -l repro.el, with jsonyter>=2.0.0 installed
(require 'jsonyter)
(add-to-list 'auto-mode-alist '("\\.ipynb\\'" . jsonyter-notebook-open))
(setq jsonyter-command '("python3" "-m" "jsonyter"))
(with-current-buffer (find-file-noselect "harness/profile/fixtures/solid-plot.ipynb")
  (jsonyter--ensure-bridge)
  (jsonyter--request-sync
   "export_notebook"
   (list :format "html" :cells (vconcat (jsonyter--nb-collect-cells t t))
         :to_path "/tmp/out.html" :include_outputs t :timeout 120)
   120))
;; => jsonyter: ... Wrong type argument: consp, nil
```

Joining the list-valued fields into strings before the call — changing nothing
else — makes the request serialize and reach the server. That is the whole
defect.

### 1.4 Why the tests missed it

`jsonyter-test-collect-cells-all-outputs-carries-stored-results`
(`test/jsonyter-tests.el`) asserts the list shape is passed through, and treats
that as the correct behaviour:

```elisp
;; Read straight from the file, nbformat's list-of-lines
;; shape and all -- this is `jsonyter-file-outputs' passed
;; through untouched, not run through any conversion.
(should (equal '("stored one\n" "stored two\n")
               (plist-get (car outputs-0) :text)))
```

It stops one step short of `json-serialize`, which is the step that fails.

Every other export test stubs `jsonyter--export-run` or `jsonyter--send`, so
none of them encodes a request either. The one test that does drive a real
bridge, `jsonyter-test-notebook-export-round-trips-with-bridge`, uses
`jsonyter-tests--notebook` — the three-cell fixture with **no outputs at all** —
and additionally skips whenever the bridge is missing, which it was in CI
(`.github/workflows/coverage.yml` pins `jsonyter==1.0.0`, and export needs
`>= 2.0.0`).

### 1.5 The same hazard on the save path

`jsonyter--nb-output-to-spec` (`jsonyter.el:3508`) copies `:data` and
`:metadata` through as read from the kernel reply, which is parsed with
`:array-type 'list` like everything else. `jsonyter--mime`
(`jsonyter.el:1509`) documents that mimebundle values really do arrive as
lists of line fragments — it joins them before rendering — so the same crash is
reachable from `jsonyter-notebook-save-with-outputs` (`C-c C-s`), not only from
export. The renderer normalizes; the serializer does not. Only `:traceback`
gets a `vconcat`.

### 1.6 Fix direction

The bridge is not the problem and needs no change: `nbformat.v4.new_output`
accepts the list-of-lines shape unmodified (verified), so this is purely about
getting the value onto the wire as a JSON array.

A `jsonyter--nb-outputs-for-wire` in the spirit of `jsonyter--sync-plan-for-wire`,
applied on **both** branches of `jsonyter--nb-collect-cells` and inside
`jsonyter--nb-output-to-spec`:

- `stream` `:text` — join a list of fragments into one string (`jsonyter--nb-text`
  already does exactly this).
- `error` `:traceback` — `vconcat` (already done on the kernel branch, missing
  on the ALL-OUTPUTS branch).
- every mimebundle value in `:data` — join a list of fragments (`jsonyter--mime`
  already does exactly this); leave non-string, non-list values alone.
- `:metadata` — nil already serializes as `{}`, which is correct; a nested array
  inside it needs the same treatment as `:data` if it can occur.

Whatever the shape of the fix, it must be covered by a test that actually calls
`json-serialize` on the finished params, not one that inspects the plist.

### 1.7 Tests added

```
jsonyter-test-export-params-serialize-with-stored-figure
jsonyter-test-export-params-serialize-with-stored-stream-lines
jsonyter-test-output-to-spec-serializes-split-mime-value
jsonyter-test-output-to-spec-serializes-file-error-traceback
```

---

## 2. Defect 2 — every Org result becomes an error placeholder

### 2.1 What happens

`jsonyter--org-parse-results-drawer` (`jsonyter.el:7760`) builds outputs keyed
by `:output_type` — the **nbformat** key — and its docstring calls them
"kernel-shape outputs". Its only caller,
`jsonyter--org-notebook-cell-from-span` (`jsonyter.el:7911`), runs each one
through `jsonyter--nb-output-to-spec`, which dispatches on `:type` — the
**kernel protocol** key:

```elisp
(let ((type (plist-get output :type)))   ; always nil for these
  (pcase type
    ...
    (_ (list :output_type "stream" :name "stdout"
             :text (format "[jsonyter: unrecognized output type %s]\n" type)))))
```

Nothing matches, so every output — the image *and* the text — is replaced by
the literal string `[jsonyter: unrecognized output type nil]`.

### 2.2 Reproduction

```elisp
;; An Org file of the shape `jsonyter-org-from-notebook' writes.
(with-current-buffer (find-file-noselect "doc.org")
  (jsonyter--org-to-notebook-cells))
;; code cell outputs:
;;   (:output_type "stream" :name "stdout"
;;    :text "[jsonyter: unrecognized output type nil]\n")
;;   (:output_type "stream" :name "stdout"
;;    :text "[jsonyter: unrecognized output type nil]\n")
```

`README.md` §"Exporting notebooks" names `jsonyter-org-to-notebook` plus
`jsonyter-notebook-export` as the supported route from an Org document to
HTML/PDF. That route produces a document with no images in it — which matches
the reported "returns an object without any in-line images" precisely.

### 2.3 Why the tests missed it

Both halves are tested, separately, and both pass:

- `jsonyter-test-org-parse-results-drawer-recovers-image-output` asserts the
  parser emits `:output_type "display_data"` with `:image/png` data.
- the `jsonyter--nb-output-to-spec` tests feed it kernel-shaped `:type`
  outputs.

No test composes the two, and composing them is where the key names disagree.

### 2.4 Fix direction

Two candidates; either works, but pick one and make the docstrings agree with
it:

1. Have `jsonyter--org-parse-results-drawer` emit genuinely kernel-shaped
   outputs (`:type "display_data"` / `:type "stream"`), which is what its
   docstring already claims. Smallest change; check no other caller depends on
   the nbformat keys.
2. Have `jsonyter--org-notebook-cell-from-span` skip
   `jsonyter--nb-output-to-spec` altogether, since the drawer parser is already
   producing the nbformat shape that `write_notebook` wants.

Either way, `jsonyter--nb-output-to-spec`'s `_` fallback should not silently
turn a caller's mistake into notebook content. Signalling, or at least
including the whole output plist in the placeholder, would have made this
visible immediately.

### 2.5 Tests added

```
jsonyter-test-org-cell-from-span-preserves-image-output
jsonyter-test-org-cell-from-span-preserves-stream-output
```

---

## 3. Defect 3 — a hand-written Org file's results are dropped entirely

`jsonyter--org-notebook-cell-spans` (`jsonyter.el:7822`) takes the
`--by-block` path for any Org file with no `:JSONYTER_CELL_ID:` drawer — that
is, any Org file the user wrote themselves rather than one
`jsonyter-org-from-notebook` produced. That path's code span ends at
`#+end_src` (`jsonyter.el:7900`):

```elisp
(push (cons nil (buffer-substring-no-properties block-start block-end)) spans)
(setq start block-end)
```

so the block's `#+RESULTS:` drawer falls into the *following prose* span.
`jsonyter--org-notebook-cell-from-span` then re-parses the code span inside a
temp buffer that contains no drawer at all, and
`org-babel-where-is-src-block-result` correctly finds nothing.

Result: the code cell is rebuilt with **no outputs**, and the drawer's raw Org
text (`#+RESULTS:`, `:results:`, `[[file:plot.png]]`, `:end:`) is emitted as a
**markdown cell**. Verified.

Defect 2 and defect 3 do not overlap: defect 3 hits Org files with no id
drawers, defect 2 hits the ones that have them. Between them, no Org file
converts its results correctly.

**Fix direction:** extend the code span to include the block's `#+RESULTS:`
drawer, the way the `--by-drawer` path already does implicitly.

**Test added:** `jsonyter-test-org-to-notebook-by-block-keeps-results`

---

## 4. Defect 4 — the notebook's own metadata is never exported

`jsonyter-notebook-export` (`jsonyter.el:8120`) sends:

```elisp
(list :format format :cells (vconcat cells) :to_path path
      :include_outputs t :timeout (or timeout jsonyter-export-timeout))
```

Given only `cells`, the bridge builds `nbformat.v4.new_notebook()` and merges
the cells into it, so what reaches nbconvert has `metadata == {}`: no
`kernelspec`, no `language_info`. `jsonyter--nb-metadata` (`jsonyter.el:2733`)
holds the real thing and is read at open time, but is only ever used by the
script exporter.

Verified: this does **not** by itself break the `latex` or `html` exporters.
What it costs is fidelity — the language nbconvert's templates highlight by,
anything a custom template reads out of notebook metadata, and the slides
configuration. It is a correctness bug rather than a crash, and it is cheap to
fix.

`export_notebook` already accepts a whole nbformat document as its `notebook`
parameter, and normalizes a list-valued `source` on that path itself. Sending
the document rather than bare cells fixes this defect and reduces the surface
of defect 1 at the same time.

**Test added:** `jsonyter-test-export-request-carries-notebook-metadata`

---

## 5. Defect 5 — "there is no TeX environment" is not a diagnosis

The reported PDF failure said there was no TeX toolchain on a server where
exporting to PDF through the Jupyter web UI works. That message is not a
finding. The bridge attaches it **by format, unconditionally**, to every `pdf`
failure it reports:

```python
TOOLCHAIN_HINTS = {
    "pdf": "the 'pdf' exporter needs pandoc and a LaTeX engine (xelatex) "
           "installed on the Jupyter server",
    ...
}
...
raise ExportError(detail, status=500, url=response.url,
                  format=format, hint=TOOLCHAIN_HINTS.get(format))
```

and `jsonyter--error-message` (`jsonyter.el:940`) renders it verbatim in
square brackets after the server's own message. A `pdf` export that failed for
*any* reason therefore reads as a missing TeX install.

This is in the `jsonyter` Python package, not here, so it is out of scope for
a fix in this repo — but it should be filed there, and it matters for triage:
**the "no TeX environment" text tells you nothing about what actually failed.**

### 5.1 What is still unconfirmed, and how to confirm it

Defect 1 makes export fail in Emacs with `Wrong type argument`, which is not
the message reported. Two readings fit, and they need the reporter's own
server to tell apart:

1. The cells in the failing notebook had all been re-run in that session, so
   `jsonyter--nb-collect-cells` took the *touched* branch and the request did
   go out — in which case the PDF failure is genuinely server-side and the
   hint hid its cause.
2. A different (older) bridge produced a different client-side error.

To settle it, on the reporter's machine:

```elisp
M-x jsonyter-notebook-export-formats   ; confirms `pdf' is offered at all
```

then reproduce the failure and read the **whole** echo-area message — the text
*before* the `[...]` hint is the server's own, recovered from nbconvert's
traceback, and is the only part worth acting on. `M-x view-echo-area-messages`
has it if it was truncated.

Also worth capturing: `pip show jsonyter` on the machine running the bridge.
The report of a **ZIP** coming back from a `latex` export does not match
bridge 2.1.0, which unpacks a zipped response and writes the `.tex` plus each
image as ordinary sidecar files next to it (`_unpack_bundle` / `_write_to_path`
in `jsonyter/export.py`). A ZIP landing on disk suggests an older bridge. If it
persists on 2.1.0, that is a bridge bug and belongs in that repo.

### 5.2 One thing on this side is worth fixing regardless

`latex` and `markdown` exports of a notebook with figures legitimately produce
**sidecar image files** written into the destination directory alongside the
document. `jsonyter-notebook-export`'s success message mentions the count
afterwards, but `read-file-name` gives no warning beforehand that choosing
`~/report.tex` will also drop `output_0_0.png` and friends into `~/`. Worth a
line in the prompt or in `README.md` §"Exporting notebooks".

---

## 6. Running the new tests

```sh
emacs -Q --batch -L . -l test/jsonyter-tests.el -f ert-run-tests-batch-and-exit
```

The eight tests this report adds are marked `:expected-result :failed`, so the
suite stays green while the defects are open:

```
Ran 473 tests, 472 results as expected, 0 unexpected, 1 skipped
11 expected failures
```

(The other three expected failures are from
`BUG-REPORT-cell-syntax-bleed.md`.)

**When a defect is fixed, its test becomes an *unexpected* pass and the batch
runner exits non-zero.** That is deliberate: it is the signal to delete the
`:expected-result :failed` marker from that test, not to delete the test.

Two gaps remain that these tests do not close, and that the fix should close:

- **No test exports a notebook with a figure through a real bridge and a real
  Jupyter server.** `jsonyter-test-notebook-export-round-trips-with-bridge`
  exports the no-outputs fixture and skips without a server; a sibling using
  `jsonyter-tests--notebook-with-figure` would have caught defect 1 years
  earlier than a unit test would have.
- **The harness profile has no export scenario at all**
  (`harness/profile/scenarios/`), even though its own fixtures
  (`solid-plot.ipynb`, `demo.ipynb`) are precisely the notebooks that fail.
- **CI pins `jsonyter==1.0.0`** (`.github/workflows/coverage.yml`), which
  predates `export_notebook`, so every bridge-driven export test skips there
  by construction. Bump it to `>=2.0.0`.
