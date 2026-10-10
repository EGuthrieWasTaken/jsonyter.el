# Gemma trial report: jsonyter 2.5.0

This release was built as two things at once: a bugfix and minor-feature update
for `jsonyter.el`, and a real-world trial of the Gemma subagent behind the
Subagent_Handoff MCP server. This file is the accounting of the second part.
It is written to be accurate rather than flattering, including where the
numbers make Gemma look better than it deserves.

## Setup

- Server: `gemma4:12b` through aider 0.86.2, diff edit format, 64k context,
  roughly 55-60 tokens/s. Each task runs in a mirror of the repo, then the
  server runs the whole ERT suite plus an elisp byte-compile lint after every
  iteration, and reports `done`, `escalate`, `failed` or `cancelled`.
- Workflow: for each of the eight reported issues I wrote an OpenSpec change
  (`openspec/changes/*`, proposal, design, spec scenarios, tasks) and the ERT
  tests first. Gemma then implemented one function (or one small edit) per task
  against a stub I had written, with the acceptance tests injected by the
  server. I downloaded each patch, applied it with `git am`, and re-ran the tests
  on the real branch before moving on.
- An "attempt" means one `submit_task` or one `followup` run.

## Headline numbers

| | |
|---|---|
| Tasks submitted | 53 (`t_20261010_0001` to `0053`) |
| Follow-up runs | 4 (on `0007`, `0019`, `0021`, `0046`) |
| Attempts in total | 57 |
| Attempts that ended `done` | 45 (41 first runs, 4 follow-ups), 79% |
| Attempts that did not | 12: 1 `failed`, 4 `cancelled` by me, 7 `escalate` |
| Of the 7 escalations | 2 were my own mistakes (see below), so 5 were Gemma failures |
| Lines of `jsonyter.el` added on this branch that survive | 758 |
| ...of which authored by Gemma (git blame) | 376 (50%) |
| ...of which authored by me | 382 (50%) |
| Lines of tests Gemma wrote | 0 (the 63-line commit attributed to "Gemma Handoff" is the server inserting my acceptance tests) |
| Specs, tests, stubs, defcustoms, regexp constants, docstrings, reference implementations | all mine |

Three caveats on the 376 lines, in decreasing order of importance:

1. **138 of them (37%) were code I wrote and Gemma only typed.** For 15 tasks
   (14 function bodies and a one-line keymap entry) the spec contained the
   finished code, usually with a paren count, because prose and numbered-step
   specs kept producing code that did not parse (below). Counting only the
   tasks where Gemma designed the body (including the skeleton and follow-up
   hint cases), the surviving figure is **238 lines in 40 commits**, about 31%
   of the branch's new code in `jsonyter.el`.
2. Every function had a signature, a docstring that fully described its
   contract, and a failing test before Gemma saw it. Nothing here shows Gemma
   can design a feature. It shows it can fill in a well-specified function.
3. The 758-line figure counts blank lines and comments. The code-only figure is
   694 (375 Gemma, 319 me).

The git history is misleading for authorship: my commits carry the repository's
configured identity (and `Co-Authored-By` trailers), so `git log --author` cannot
tell me from the user. The split above comes from `git blame` restricted to the
commits between `origin/main` and `HEAD`, with the Gemma commits identified by
`handoff@localhost`.

## What worked

- **A single function against a stub, with a docstring contract and a test.**
  This was about 25 s and one iteration per task. 37 of the 45 tasks that ended
  `done` did so in a single iteration. Examples: `ensure-local-dir`, `empty-cell-p`,
  `next-cell-type`, `type-from-prefix`, `nb-set-type`, `find-envs`,
  `find-display-dollars`, `mask-code`, `cache-file`, `fg`, `first-error`,
  `image`, `nb-latex-clear`.
- **Numbered steps for a 6-15 line body** worked first time for
  `adopt-stray-text`, `notebook-prune`, `json-for-wire` and the `sync C` wiring.
  It failed for `ensure-remote-dir`, `forget-cells`, `find-brackets`,
  `fragments` and `render` (below), so it is not a reliable method for anything
  with nested forms.
- **An exact body with a paren count** was the most reliable method: of 14 tasks
  where I gave the finished body, 11 passed on iteration 1, 1 on iteration 2,
  and 2 escalated only because of my own set-up errors (next section) with
  correct code.
- **A code skeleton with two holes** rescued the remote-directory helper after
  the prose-only attempt failed.
- Lint-clean output and correct Emacs idiom on the whole, where it parsed.

## What did not work

- **Unbalanced parentheses in nested forms** was the dominant failure: the
  logic was right and the form was one `)` short (`forget-cells`,
  `data-for-wire`, `find-brackets`, `fragments`; `render` had that plus invented
  forms). Gemma did not repair this itself: the next iteration either made no
  edit or repeated the mistake. A follow-up naming the exact last line fixed it
  each time it was tried (3 of 3: `forget-cells`, `data-for-wire`, `fragments`).
  A paren-aware validator in the loop would remove most of these failures.
- **Multi-region edits.** `0004` asked for two edit regions and produced no
  applicable block in 2 iterations. Splitting it into two single-region tasks
  worked first time. `0001`, the monolithic "do the whole sync-add-pair change"
  task, used 13 LLM calls and 17,618 evaluated tokens and kept no lines: it broke
  the SEARCH/REPLACE protocol (no closing marker), then invented functions
  (`remove-prefix-chars`) and wrote `(setq (file-directory-p dir) ...)`.
- **Stalls after a failed iteration.** Four tasks sat for many minutes (5-8 in
  three cases) in iteration 2-4 (`0003`, `0020`, `0026`, `0044`) and I cancelled
  them. All four were resubmitted with a tighter spec and passed within one
  iteration.
- **Prose-only specs for non-trivial control flow.** `ensure-remote-dir` failed
  three completed iterations (stray body form in `condition-case`, `(signal
  (user-error ...))`). `render` invented `(with-temp-buffer (setq
  default-directory ...))` and `(error (user-error ...))`. Both passed only once I
  supplied the code.
- **Lint-width on docstrings.** Two tasks failed lint because Gemma put
  backslash-newline continuations in a docstring I had written wider than 80
  columns. That is partly my spec's fault, but the model did not recover on its
  own either (one task stalled, the other made no edit).
- **Lint diagnostics outside its own edit.** In `0053` the diagnostic was about
  where my `defcustom` sat in the file; Gemma made no edit in iteration 2. See
  the next section.

## Escalations that were my fault

Two of the seven `escalate` results were correct code held back by my own set-up,
and I merged Gemma's output:

- `0043` (`nb-latex-target-cells`): I submitted it in the same wave as `0042`,
  whose function it calls. In `0043`'s base that function was still a stub, so
  the server's test run failed four times. The code was identical to my reference
  from iteration 1. Merged after checking on the real branch.
- `0053` (on-open hook in `jsonyter-notebook-open`): the 4-line form was right on
  iteration 1. Lint flagged a free-variable warning because my `defcustom` sits
  later in the file than the function that reads it. Gemma made no edit in
  iteration 2. I merged iteration 1 unchanged and added the one-line
  `(defvar jsonyter-notebook-latex-preview-on-open)` forward declaration myself.

## Per-change breakdown

Specificity: **P** = prose or numbered steps (Gemma designed the body),
**S** = my code skeleton with holes, **V** = finished body given by me,
**H** = follow-up hint ("add the missing paren, last line is ...").

| Change | Tasks | Notes |
|---|---|---|
| `sync-add-pair-creates-dirs` | `0001`-`0003`, `0006`, `0002`, `0010` | `ensure-local-dir` P done; `ensure-remote-dir` P failed (cancelled), S done; wiring P done; monolith failed |
| `notebook-cell-integrity` | `0004`, `0005`, `0007`-`0009`, `0011`, `0014`, `0015` | `forget-cells` needed H; `drop-empty-cells` needed 3 iterations; the rest P first try |
| `notebook-raw-cells` | `0012`, `0013`, `0016`, `0018`-`0020`, `0022`, `0037` | R1-R3 P first try; `set-cell-type` V (2 iterations); `insert-cell-below/above` P then docstring V; toggle V |
| `export-structured-output-data` | `0017`, `0021`, `0045` | `json-for-wire` P first try; `data-for-wire` P then H (4 iterations); metadata one-token change (2 iterations) |
| `notebook-latex-preview` | `0023`-`0036`, `0038`-`0044`, `0046`-`0053` | 29 tasks (functions, keybinding, hook). 13 V, the rest P; see below |

The full per-task ledger is the appendix below. The git history also holds one
commit per Gemma iteration (`git log --author="Gemma Handoff"`).

### The LaTeX change in particular

The LaTeX change is the best case for this style and the worst for claims about
Gemma. It decomposes into 27 small pure-ish functions, most of them under 15
lines, so the success rate was high (23 of its 29 tasks passed on the first
iteration), but the regexps (`jsonyter--latex-fence-regexp` and friends) are
`defconst`s I wrote because I did not trust the model with Emacs regexp syntax
(a `^` mid-pattern is a literal caret, which bit me first). Eleven functions
(`find-brackets`, `find-inline-dollars`, `inline-find-close`, `check-tools`,
`nb-latex-markdown-cells`, `nb-latex-target-cells`, `render`, `preview-cell`
and the three commands) plus the keybinding and the on-open hook were given as
finished code.

## Items I could not reproduce

Two of the eight reported symptoms were not reproduced and **are not claimed
fixed**:

- **"Inserting newlines often hangs Emacs (needs C-g)".** Not reproduced in
  batch Emacs 29.3, in fuzz runs (about 150 seeds of random edits, RET,
  deletion, undo, over notebooks with and without outputs), or in Xvfb-driven GUI
  sessions with `display-line-numbers-mode` on. What I did find is that phantom
  empty overlays (the first bug, which duplicated every cell as an empty
  overlay on each re-render) made every after-change hook walk a growing overlay
  set. That is consistent with the hang, and removing the phantoms removes the
  growth, but I have no direct evidence that this is the cause on your machine.
  Emacs 31.1 itself was not available to me.
- **"Line numbers inconsistent; RET at the top or bottom of a cell does not
  update them".** Not changed. `display-line-numbers-mode` draws the number on
  the first visual row of a logical line. A cell's prompt is a `before-string`
  that contains newlines, so the number for a cell's first line lands on the
  prompt's blank row, not beside the first source line. It looks inconsistent
  rather than wrong. Two fixes are possible and neither is in this release: draw the
  prompt in its own overlay at the end of the previous line, or give the package
  its own per-cell numbering option. Say which you prefer.

## Known limitation

One of the 150 undo fuzz seeds still ends with a stale `jsonyter-source-end`
marker after an undo that crosses a heal. I did not chase it further.

## Not verified

- Emacs 31.1 (I tested on Emacs 29.3, the version available in the container).
- The graphical harness scenarios (`harness/`) for the three user-visible
  changes. Marked as not run in `tasks.md` of the affected changes.
- The CI coverage gate (`coverage.yml`) was not run.
- `jsonyter-test-kernel-activity-formats-or-falls-back` fails here before and
  after this work (it failed in the first baseline run). The rest of the suite is
  green: 560 tests, 558 pass, 1 skipped (the bridge export round trip), 1 known
  failure.
- The OpenSpec changes are validated but left unarchived.

## Verdict

Gemma is useful as a fast, cheap typist for small functions that are already
fully specified. About half of the new code in this release went through it,
and none of the hard decisions did: which bug is actually the cause, what the
contract is, how to split the work so each piece is single-region, what the
regexps are, and what the tests assert. On anything with nested forms, the
failure is almost always the same one (a missing closing paren), it cannot fix
it unprompted, and a precise one-line follow-up fixes it nearly every time. The
overhead of writing a spec exact enough for a 12B model was, for the longest
functions, close to the cost of writing the function.

## Appendix: per-task ledger

Columns: task, unit of work, outcome, iterations, lines kept, notes. LLM-call and token counts were recorded only for a few tasks; where I have them they are in the notes.

| task | unit | outcome | iters | lines kept | notes |
|---|---|---|---|---|---|
| t_20261010_0001 | sync-add-pair: all 3 pieces in one task | FAILED (splice_anchor_mismatch) | 2/4 | 0 | iter1: broke SEARCH/REPLACE protocol (no `>>>>>>> REPLACE`), 0 files edited; iter2: dropped BEGIN/END markers. Visible code was invalid Elisp: `(setq (file-directory-p dir) ...)`, invented `remove-prefix-chars`/`remove-prefix-tree`, malformed condition-case, `(y-or-n-p "..." t)` (13 LLM calls, 17618 eval tokens) |
| t_20261010_0002 | sync helper A (ensure-local-dir) against stub | DONE | 1/4 | +5/-2 (all) | correct first try, 16 s (? LLM calls, ? eval tokens) |
| t_20261010_0003 | sync helper B (ensure-remote-dir), prose-only spec | CANCELLED by me (iter 4 hung >8 min; 3 completed iters all failed lint+tests) | 4/4 (3 done) | 0 | unbalanced parens; existence check put inside condition-case as stray body form; `(signal (user-error ...))` misuse; each iter 24-42 s, iter 4 never returned (3 LLM calls, 3834 eval tokens) |
| t_20261010_0004 | integrity I1 forget-cells (stub body) + render call (2 edit regions) | ESCALATE "stuck" (no edits made, 2 iterations) | 2/4 | 0 | `no_edit_iterations: 2`: never produced an applicable block for a 2-region task; split into single-region tasks (2 LLM calls, 1476 eval tokens) |
| t_20261010_0005 | integrity I2 drop-empty-cells | DONE | 3/4 | +9/-1 (all) | correct; needed 3 iterations (? LLM calls, ? eval tokens) |
| t_20261010_0006 | sync helper B attempt 2 WITH my code skeleton (2 holes) | DONE | 1/4 | body = 14 lines: 10 are my skeleton verbatim; Gemma filled the 2 holes (4 lines) | correct; 26 s. Prose-only attempt (t_0003) had failed 3/3 completed iterations (? LLM calls, ? eval tokens) |
| t_20261010_0007 | integrity I1a forget-cells body | attempt 1: lint/tests FAILED (missing ONE closing paren on the defun); escalate "stuck" after 2 iters (iter 2 made no edit) -> followup queued | 2/4 | 0 (so far) | body logic correct, paren off by one (4 LLM calls, 9000 eval tokens) |
| t_20261010_0008 | integrity I5a empty-cell-p body | DONE | 1/4 | +3/-2 (all) | correct first try, ~26 s (? LLM calls, ? eval tokens) |
| t_20261010_0007 (followup run 2) | integrity I1a, followup "add the missing paren" | DONE | +1 run (3 iters total) | +5 (all; one paren added by followup) | fixed with a targeted hint |
| t_20261010_0009 | integrity I3 adopt-stray-text (prose-only, step list) | DONE | 1/4 | ~14 lines (all) | correct first try |
| t_20261010_0010 | sync C wire create-dirs (3 exact small edits, prose-only) | DONE | 1/4 | ~15 lines (all) | correct first try |
| t_20261010_0011 | integrity I5b prune (prose step list) | DONE | 1/4 | ~14 lines (all) | correct first try |
| t_20261010_0012 | raw R1 next-cell-type | DONE | 1/4 | ~5 lines (all) | correct first try |
| t_20261010_0013 | raw R2 type-from-prefix | DONE | 1/4 | ~8 lines (all) | correct first try |
| t_20261010_0014 | integrity I1b: one-line call in render | DONE | 1/4 | +1 line | correct first try |
| t_20261010_0015 | integrity I4: two-line wiring in stale-after-change | DONE | 1/4 | +2 lines | correct first try |
| t_20261010_0016 | raw R3 nb-set-type (5 numbered steps) | DONE | 1/4 | ~10 lines (all) | correct first try |
| t_20261010_0017 | export E1 json-for-wire (cond with explicit while loop steps) | DONE | 1/4 | ~14 lines (all) | correct first try |
| t_20261010_0018 | raw R4 set-cell-type command body (exact 5-line body given) | DONE | 2/4 | ~5 lines (all) | iter 1 failed, iter 2 ok |
| t_20261010_0019 | raw R5a insert-cell-below edit (3 small edits) | attempt 1: tests OK but lint FAILED (my spec's docstring had >80-col lines; Gemma used backslash-newline continuations); escalate "stuck" -> followup with a narrower docstring queued | 2/4 | pending | logic correct, lint failure traced to my docstring text (3 LLM calls, 2591 eval tokens) |
| t_20261010_0020 | raw R5b insert-cell-above edit (same spec as R5a) | CANCELLED by me (iter 1 lint failed on the same docstring; iter 2 hung >6 min) | 2/4 | 0 | 2nd observed degenerate-generation stall after a lint-failed iteration |
| t_20261010_0019 (followup) | raw R5a with narrower docstring | DONE | 3 total | ~8 lines (all) | followup fixed lint |
| t_20261010_0022 | raw R5b attempt 2 (docstring text supplied verbatim, <=70 cols) | DONE | 1/4 | ~8 lines (all) | correct first try once the docstring was lint-safe |
| t_20261010_0023 | latex LX1 mask-code | DONE | 1/4 | ~6 lines (all) |  |
| t_20261010_0024 | latex LX2 find-envs | DONE | 1/4 | ~8 lines (all) |  |
| t_20261010_0025 | latex LX3 find-display-dollars | DONE | 1/4 | ~8 lines (all) |  |
| t_20261010_0021 | export E2 data-for-wire (explicit cond text given) | attempt 1: logic CORRECT but one `)` short (defun not closed) x3 iterations -> escalate stuck; followup w/ exact last line queued | 3 | 0 | the recurring "drops the defun's closing paren" failure (8 LLM calls, 3818 eval tokens) |
| t_20261010_0026 | latex LX4 find-brackets (step list) | CANCELLED by me: iter 1 body right but one `)` short; iter 2 stalled >7 min | 2 | 0 | 3rd stall after a failed iteration; resubmitted with the exact final line + paren count (t_0038) |
| t_20261010_0027 | latex LX5a inline-open-p | DONE | 1/4 | ~5 lines (all) | 150 s for the first iteration (slowest single iteration so far; char literals `?\\`) |
| t_20261010_0028 | latex LX5b inline-close-p | DONE | 1/4 | ~6 lines (all) | 15 s |
| t_20261010_0029 | latex LX7 document | DONE | 3/4 | ~14 lines (all) | needed 3 iterations (backslash doubling in string literals) |
| t_20261010_0030 | latex LX8 converter | DONE | 1/4 | ~7 lines (all) |  |
| t_20261010_0031 | latex LX9 cache-file | DONE | 1/4 | ~6 lines (all) |  |
| t_20261010_0032 | latex LX10 fg | DONE | 1/4 | ~7 lines (all) |  |
| t_20261010_0033 | latex LX11 first-error | DONE | 1/4 | ~7 lines (all) |  |
| t_20261010_0034 | latex LX13 image | DONE | 1/4 | ~7 lines (all) |  |
| t_20261010_0035 | latex LX14a nb-latex-clear | DONE | 1/4 | ~7 lines (all) |  |
| t_20261010_0036 | latex LX14b overlay-modified | DONE | 1/4 | 1 line |  |
| t_20261010_0037 | raw R6 toggle rewrite (body given verbatim, paren count warned) | DONE | 1/4 | ~8 lines (all) |  |
| t_20261010_0038 | latex LX4 attempt 2 (body + last line given verbatim, paren count) | DONE | 1/4 | ~10 lines (all) | succeeded once the exact last line was given |
| t_20261010_0039 | latex LX5c inline-find-close (body given verbatim, paren count) | DONE | 1/4 | ~10 lines (all) |  |
| t_20261010_0021 (followup run 2) | export E2 followup: "add the missing 4th paren, last line given verbatim" | DONE | +1 iter (4 total) | ~8 lines (all) | targeted hint fixed it in one iteration |
| t_20261010_0040 | latex LX15 check-tools (body given verbatim) | DONE | 1/4 | ~6 lines (all) |  |
| t_20261010_0041 | latex LX5d find-inline-dollars (body given verbatim, paren count) | DONE | 1/4 | ~14 lines (all) |  |
| t_20261010_0042 | latex LX17a markdown-cells (body given verbatim) | DONE | 1/4 | ~6 lines (all) |  |
| t_20261010_0043 | latex LX17b target-cells (body given verbatim) | server said ESCALATE after 4 iterations, but the code was correct (identical to my reference from iteration 1/3); the task's tests failed only because it called `jsonyter--nb-latex-markdown-cells`, still a stub in that task's base -- MY dependency/ordering mistake. Verified green on the real branch and merged. | 4/4 | ~8 lines (all) | not a Gemma failure |
| t_20261010_0044 | latex LX12 render (numbered prose steps, ~25-line body) | CANCELLED by me during iter 3: iter 1 and 2 both failed lint+tests (invented `with-temp-buffer (setq default-directory ..)`, `(error (user-error ..))`, unbalanced); iter 2 took 3.5 min and 22k prompt tokens | 2 (+1 running) | 0 | resubmitted with the exact body (t_0047) |
| t_20261010_0045 | export E3 output-for-wire metadata (one-token change + docstring sentence) | DONE | 2/4 | 1 token + 1 docstring sentence | iter 1 failed lint (docstring) |
| t_20261010_0046 | latex LX6 fragments (numbered steps) | iter 1: logic right, parens miscounted at the nested dolists (unparseable); iter 2: no edit; escalate "stuck" -> followup with the exact two final lines + paren counts: DONE in 1 more iteration | 3 total | ~12 lines (all) |  |
| t_20261010_0047 | latex LX12 attempt 2 (exact body, paren walkthrough) | DONE | 1/4 | ~25 lines (all, but body was given verbatim) | 22 s |
| t_20261010_0048 | latex LX19a keymap line | DONE | 1/4 | +1 line | via `lines` slice |
| t_20261010_0049 | latex LX16 preview-cell (exact body) | DONE | 1/4 | ~25 lines (all, but body was given verbatim) |  |
| t_20261010_0050 | latex LX18a preview command (exact body) | DONE | 1/4 | ~8 lines (all, body given verbatim) |  |
| t_20261010_0051 | latex LX18b clear command (exact body) | DONE | 1/4 | ~9 lines (all, body given verbatim) |  |
| t_20261010_0052 | latex LX18c toggle command (exact body) | DONE | 1/4 | ~10 lines (all, body given verbatim) | 16 s |
| t_20261010_0053 | latex LX19b on-open form (exact 4-line form) | server said ESCALATE after 2 iterations: the form was correct on iteration 1, but lint flagged a free-variable warning because MY defcustom sits later in the file than `jsonyter-notebook-open`; Gemma could not fix it in iteration 2 (no edit, 2 min). I merged iteration 1 unchanged and added the one-line `(defvar ...)` forward declaration myself. | 2/4 | 4 lines (all, given verbatim) | my ordering mistake, not a Gemma failure |
