# Feature request: directory sync commands for `jsonyter.el`

**Status:** proposed
**Date:** 2026-09-15
**Scope:** `jsonyter.el` (this repo). The companion document in `jsonyter`
defines the protocol and does all the work; this side is a consumer and should
be implemented **second**. Section references of the form "bridge §N" point at
`FEATURE-REQUEST-directory-sync.md` in that repo.

---

## 1. Problem

`jsonyter-upload-file`, `jsonyter-download-file` and `jsonyter-remote-dired`
cover the deliberate, one-file-at-a-time case well. What they do not cover is
the standing relationship: **a local data directory and a remote one that are
supposed to hold the same thing.**

Today that means remembering what changed on which side since the last time,
and then driving `U` and `D` in the remote browser once per file. The failure
mode is not friction, it is loss — the file you forget to pull is the file you
then overwrite.

This adds one command with one meaning: *make these two directories agree*.

## 2. What Emacs is and is not responsible for

The bridge owns hashing, walking both trees, the three-way comparison against
its baseline, conflict policy, deletion guards, and every byte that moves.
Emacs owns **the pair, the review, and the reporting** — which directory maps
to which, showing the user what is about to happen before it happens, and
saying clearly what happened afterwards.

That split is the same one `jsonyter--transfer-run` already embodies, and it is
what keeps a multi-hundred-megabyte transfer out of Emacs's memory and off its
main thread. Nothing here reads a data file.

One consequence worth stating up front: **the review UI is not decoration.**
Sync is the first jsonyter command that can modify many files in both
directions from a single keystroke, including deleting them. A user who cannot
see the plan before it runs will, correctly, not trust the command. The plan
buffer (§6) is the feature.

## 3. Pairs

A *pair* is `(local directory, remote Contents-API path)` for a given server.
The remote half is a Contents-API path — POSIX, relative to the server's
`root_dir`, no leading slash — under the same rule the transfer section already
enforces everywhere: never interchange it with the kernel's absolute cwd, and
say "Remote (contents) directory" in every prompt.

```elisp
(defcustom jsonyter-sync-pairs nil
  "Directory pairs `jsonyter-sync' can reconcile.

Each entry is (LOCAL . REMOTE), or a plist for the fuller form:

    (:local \"~/project/data\" :remote \"work/data\"
     :server \"https://jupyter.example.org\"   ; nil = any server
     :conflict newest :delete none :ignore (\"*.tmp\"))

LOCAL is expanded with `expand-file-name'.  REMOTE is a Contents-API
path -- relative to the server's `root_dir', no leading slash -- not the
kernel's absolute working directory.  :conflict and :delete override
`jsonyter-sync-conflict-policy' and `jsonyter-sync-delete-policy' for
that pair alone."
  :type '(repeat sexp))
```

### 3.1 Resolving which pair a command means

In order, stopping at the first that answers:

1. A pair whose `:local` is `default-directory` or one of its parents, and
   whose `:server` matches the buffer's (or is nil).
2. Exactly one pair matching the server, regardless of directory.
3. `completing-read` over the matching pairs.
4. No pairs at all → offer to create one, seeded from `default-directory` and
   from `jsonyter--transfer-remote-dir` (the kernel-cwd probe), then offer to
   persist it via `customize-save-variable`.

Step 4 matters more than it looks: the probe already knows where the kernel is
working, so the common case — "sync this project directory with wherever the
kernel is" — should be two `y`s and no typing. A feature that requires
configuring a defcustom before it can be tried once will not be tried once.

The bridge/session context itself comes from the existing
`jsonyter--resolve-transfer-context`, unchanged: a sync is REST-only, so it
needs a live bridge and only optionally a session.

## 4. Settings

```elisp
(defcustom jsonyter-sync-conflict-policy 'ask ...)   ; ask | newest | local | remote | skip
(defcustom jsonyter-sync-delete-policy 'none ...)    ; none | push | pull | both
(defcustom jsonyter-sync-ignore nil ...)             ; extra patterns, added to the bridge's defaults
(defcustom jsonyter-sync-review 'when-destructive ...) ; always | when-destructive | never
(defcustom jsonyter-sync-keep-conflict-copies t ...)
(defcustom jsonyter-sync-max-deletes 25 ...)
(defcustom jsonyter-sync-state-directory nil ...)    ; nil = the bridge's XDG default
```

Three defaults are deliberate:

- **`jsonyter-sync-conflict-policy` is `ask`, not `newest`.** The bridge's
  non-interactive `sync()` defaults to `newest` because a script cannot answer
  a question. Emacs *can*, and the whole reason for a front end is to put the
  decision in front of someone who knows which edit they meant to keep.
  `newest` remains one keystroke away in the plan buffer, and setting it as the
  default is a supported choice — it just should not be made on the user's
  behalf the first time they run the command.
- **`jsonyter-sync-review` is `when-destructive`:** show the plan when it would
  delete anything, overwrite a conflict loser, or move more than
  `jsonyter-sync-review-threshold` files (default 10); otherwise just run.
  `always` for the cautious, `never` for the confident. A sync that is purely
  additive in one direction does not need ceremony, but one that deletes always
  does.
- **`jsonyter-sync-delete-policy` is `none`**, matching the bridge. Deletion
  propagation is opt-in per bridge §7, and the front end must not quietly widen
  it.

## 5. Commands

```
jsonyter-sync                  Reconcile the current pair (plan, maybe review, apply).
jsonyter-sync-status           Plan only.  Never writes.  The "what would change?" verb.
jsonyter-sync-push             One-way: local wins for everything that differs.
jsonyter-sync-pull             One-way: remote wins for everything that differs.
jsonyter-sync-abort            Stop the running sync after the current file.
jsonyter-sync-add-pair         Define a pair, seeded from this buffer and the cwd probe.
jsonyter-sync-forget-pair      Drop a pair, optionally deleting its baseline.
jsonyter-sync-reset-baseline   Discard the baseline; the next sync is a first sync.
```

All take a prefix argument to force the review buffer regardless of
`jsonyter-sync-review`.

`jsonyter-sync-push` / `-pull` are *not* "upload the tree" / "download the
tree": they are a normal plan with `conflict` forced to `local` / `remote`.
They still skip unchanged files, still respect ignores, and still never delete
unless the delete policy says so. Name them in the docstring as "this side
wins", not "copy everything", because the difference is the entire safety
argument.

`jsonyter-sync-reset-baseline` exists because the baseline is disposable by
design (bridge §5.2) and "turn it off and on again" should be a supported,
documented recovery rather than folklore about deleting a file in
`~/.local/state`.

Bind `C-c C-y` to `jsonyter-sync` in `jsonyter-repl-mode-map`,
`jsonyter-notebook-mode-map` and `jsonyter-script-mode-map` — free in all
three — and add `S` (sync this directory) and `%` (sync status) to
`jsonyter-remote-dired-mode-map`, where the user is already looking at the
remote side of a pair.

## 6. The plan buffer: `jsonyter-sync-mode`

A `tabulated-list-mode` buffer, modelled directly on `jsonyter-remote-dired`
(same derivation, same `revert-buffer-function` wiring, same face conventions),
named `*jsonyter-sync: <local> <-> <remote>*`.

```
  ~/project/data  <->  work/data   on https://jupyter.example.org
  8 to transfer (184.3 MB up, 4.1 KB down) · 1 conflict · 110 unchanged

  A  File                        Size      Local            Remote
  >  trials.csv                  184.3 MB  14:22            09-07 14:22
  <  out/fig.png                   4.1 KB  --               15:58
  !  notes.md                      2.1 KB  15:40            16:10   both changed
  =  README.md                     1.2 KB  09-01 10:00      09-01 10:00
  x  scratch.tmp                     512 B  15:59            --      ignored
```

The action column is one glyph, because the eye should be able to scan the
direction of a hundred rows without reading:

| | |
|---|---|
| `>` | push — local to remote |
| `<` | pull — remote to local |
| `!` | conflict, unresolved |
| `=` | already identical (converge / in-sync) |
| `-` | delete (with `>`/`<` for the side) |
| `x` | skipped or ignored |

Colour reinforces it: pushes in one face, pulls in another, conflicts in
`warning`, deletions in `error`, unchanged rows in `shadow`. Hide `=` rows by
default behind a toggle — in steady state they are the overwhelming majority
and they are the least interesting thing on screen.

### 6.1 Keys

```
RET   describe this entry: both hashes, both mtimes, the baseline, the reason
>     override to push          <   override to pull
d     override to delete        k   skip this entry
n/N   resolve conflict: newest / by the other side
u     clear the override        U   clear all overrides
g     re-plan (the trees may have moved)
T     toggle display of unchanged entries
D     diff this entry's two versions
x     execute the plan          q   quit without doing anything
```

`x` is the only key that writes, and it confirms with a one-line summary
naming the counts and, when the plan deletes, the deletion count separately.
`q` must be an obvious, safe exit — a user who does not understand the plan
should be able to leave without doing anything, and should feel that.

### 6.2 `D` — diff

Download the remote version to a temp file (via the existing `download`, into
`temporary-file-directory`) and hand both to `ediff-files`, or to `diff` with
`jsonyter-sync-diff-function`. Refuse for binary files and for anything over
`jsonyter-sync-diff-max-size` (default 2 MB) with a message that says why
rather than hanging on a 200 MB CSV.

This is the single highest-value key in the buffer. "Both sides changed" is
unanswerable in the abstract; it is usually trivial once you can see the two
versions. Without `D`, every conflict is resolved by guessing at a timestamp.

### 6.3 Overrides go to the bridge as data

Each override sets the row's action. `x` collects them into the
`overrides` alist of `sync_apply` (bridge §8), sending the *unmodified plan*
plus the overrides rather than an edited plan. The bridge stays the authority
on what a plan means, Emacs contributes only per-path decisions, and the wire
format is trivially inspectable when something goes wrong.

## 7. Running it

Reuse `jsonyter--transfer-run`'s structure — it already does everything a sync
needs — rather than writing a second async runner:

- **Asynchronous via `jsonyter--send`**, never `jsonyter--request-sync`. A sync
  runs for minutes and must not wedge Emacs. `jsonyter-sync-status` on a small
  pair may be synchronous; anything that transfers must not be.
- **`:progress` handler.** The bridge's sync progress lines (bridge §11.1) add
  `file_index` / `files_total` / `files_done` / `sync_bytes_*` to the existing
  shape, so the current handler keeps working and just gains detail. Show
  `Syncing trials.csv (4/12) — 25.1 MB / 184.3 MB` in the echo area.
- **A `"phase": "scan"` line arrives before any transfer.** Render it as
  `Scanning work/data… (9 directories)`. The scan of a large tree is seconds of
  silence before anything moves, and silence from a command that is about to
  modify files reads as a hang.
- **Mode line.** Reuse the existing `transfer` session slot — the same one
  `:up NN%` / `:down NN%` / `:export` already use — with a sync phase rendering
  as `:sync 4/12`. A sync started from a `dired` buffer stays visible from the
  REPL it belongs to, exactly as a transfer does, and the multi-session `~`
  indicator keeps working unchanged.
- **Clear the slot on result *and* on a synchronous `jsonyter--send` failure**,
  per the `condition-case` that `jsonyter--transfer-run` already wraps around
  the send. A dead bridge must not leave a stale `:sync` tag in the mode line
  forever.

### 7.1 Abort

`jsonyter-sync-abort` sends `cancel_sync` with the in-flight request id. The
bridge stops after the current file, writes the baseline for what completed,
and returns normally with `cancelled: t`. Report it as a partial success — "12
of 40 files synced before you stopped; re-run to continue" — because that is
precisely what it is. Bind it to `C-c C-k`-adjacent muscle memory if a slot is
free in the sync buffer; otherwise `M-x` is fine, since aborting is rare.

Also offer to abort from `jsonyter-sync` itself when a sync for the same pair
is already running, rather than starting a second one — the bridge will refuse
the second with `SyncRefused(reason="locked")` (bridge §8.4), and a clear "a
sync of this pair is already running; abort it?" beats surfacing that error.

## 8. Reporting

The completion message must answer "what state am I in now?" in one line, and
be specific:

```
jsonyter: synced ~/project/data <-> work/data — 3 up (184.3 MB), 5 down
(4.1 KB), 1 converged, 110 unchanged, sha256 verified, 31.8s
```

With anything unresolved or failed, say so and name the recovery:

```
jsonyter: synced 8 file(s); 1 conflict left unresolved (notes.md) — M-x
jsonyter-sync-status to resolve it
```

```
jsonyter: synced 8 file(s); 1 failed — locked.db changed on the server between
the scan and the transfer [re-run to pick it up]
```

Extend `jsonyter--error-message` with the sync-specific structured errors, the
way it already special-cases `cf_ray` and the transfer conflict reasons:

- `SyncRefused` with `reason: "too-many-deletes"` → name
  `jsonyter-sync-max-deletes` **and** raise the possibility that `:local` is on
  an unmounted volume. That is the actual cause nine times in ten, and it is
  not a guess the user will make on their own while staring at a number.
- `reason: "locked"` → name `jsonyter-sync-abort` and the holding pid.
- `reason: "too-many-files"` → name the pair's `:local` and the limit, since a
  mistyped path is the usual cause.
- `integrity: "size"` in a *successful* result → append a one-off warning that
  this server predates jupyter_server 2.11 and a same-size edit cannot be
  detected. Once per Emacs session per server, not once per sync; a warning
  that fires every time is a warning nobody reads.

Keep the full result in a `*jsonyter-sync-log*` buffer (per-file lines, newest
run first), and have the echo-area message mention it when anything failed. An
echo line is the wrong place for a list of twelve failures.

## 9. Testing

Both layers, as the transfer work did:

**Batch ERT (`test/jsonyter-tests.el`), off a stubbed bridge:**

- Pair resolution: `default-directory` inside a pair's `:local`; a nested pair
  picking the most specific; server mismatch excluding a pair; the zero-pairs
  path offering to create one.
- Plan rendering is a pure function of the plan plist — feed fabricated plans
  covering every `action`/`reason` from bridge §5's table and assert the
  `tabulated-list` entries, glyphs and faces. No I/O. This mirrors
  `jsonyter--remote-entries`, which is already factored exactly this way and
  should be the model.
- Override bookkeeping: `>`/`<`/`d`/`k` set actions, `u`/`U` clear them, and
  the alist handed to `sync_apply` contains only genuine overrides — not every
  row.
- Two-level progress: feed real sync `progress` lines to `jsonyter--dispatch`
  and assert the echo-area text, the mode-line `:sync 4/12` tag, and that the
  tag clears on the result. Cover the `scan` phase line, which has no
  `bytes_total`, and assert it does not divide by zero.
- Error rendering: each `SyncRefused` reason produces its recovery hint; the
  unmounted-volume hypothesis appears for `too-many-deletes`; the
  `integrity: "size"` warning fires once per server, not per sync.
- The destructive-review threshold: a plan with a deletion forces the buffer
  under `when-destructive`; a small additive plan does not.

**Harness scenarios (`harness/profile/scenarios/sync.el`, with a
`sync.jsonl` bridge script):** the same approach `transfer.el` takes, and for
the same reason — a real server cannot be made to produce a specific conflict
on cue.

- `jsonyter-sync` end to end on a clean plan: applies without review, prints
  the completion line, mode line back to `:idle`.
- A plan with one conflict: the buffer opens, `n` resolves it to newest, `x`
  applies, the message names what moved.
- A plan with deletions forces the review buffer under `when-destructive` --
  and, under an explicit `never`, does *not*. The front end must honour a
  setting the user actually chose; the guard against catastrophe belongs in the
  bridge's `max_deletes`, where it cannot be clicked past, not in a front end
  second-guessing a defcustom.
- `q` from the plan buffer issues no `sync_apply` at all. Assert on the absence
  of the request, not just the absence of a message.
- `jsonyter-sync-status` issues `sync_plan` and never `sync_apply`, under any
  keystroke in the buffer other than `x`.

Note the same gap `transfer.el` documents: `eh-fake-bridge` has no `progress`
emit key, so mid-flight progress is asserted in batch ERT rather than in the
scenarios. Extending the harness with one would benefit both features and is
worth doing first if it is cheap.

## 10. Documentation

- A README section under the transfer one: what a pair is, why the remote half
  is a Contents-API path, the conflict policies, and — prominently — that
  deletion propagation is off by default and how to turn it on.
- The commentary header at the top of the new section should carry the same
  one-idea-to-hold-on-to line the transfer section does. Here it is: **the
  baseline is what makes a bidirectional sync safe.** Comparing two directories
  tells you they differ; comparing them against what they last agreed on tells
  you who changed, which is the only way to tell a routine update from a
  conflict.
- Say plainly in the README that this is on-demand, not continuous. Users who
  expect Dropbox will otherwise discover the difference the hard way.

## 11. Out of scope for v1

- **Sync on a timer, on save, or on kernel start.** The bridge is explicitly
  one-shot (bridge §2) and this side must not smuggle a watcher in via
  `run-with-idle-timer`. If it turns out to be wanted, it is a separate feature
  with its own document and its own failure modes.
- **TRAMP integration.** `:local` is a local directory. A TRAMP path would put
  a second remote hop under a transfer that is already remote.
- **Per-file sync from `dired`.** `jsonyter-dired-upload-dwim` already covers
  the ad-hoc case; sync is about directories.
- **Merging conflicted files.** `D` shows the difference and the user picks a
  side, or edits one side and re-runs. An `ediff-merge` path is plausible later;
  it is not v1.
- **Sync status in the mode line when idle.** Only an in-flight sync shows a
  tag. Knowing a pair is "3 files behind" requires a plan, which requires
  requests, which is a background poll — and that is the watcher this document
  declines to build.
