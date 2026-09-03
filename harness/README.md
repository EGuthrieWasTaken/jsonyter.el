# Testing jsonyter.el in a real Emacs

`test/jsonyter-tests.el` answers *is the logic right*. It runs under
`emacs -Q --batch`, where there is no frame, no X server, no redisplay
and no images. That covers a lot — 91 tests of it — but it structurally
cannot see the half of this package that is about what appears on
screen: whether a base64 PNG in a mimebundle actually decodes or renders
as a placeholder box, whether a tall figure becomes five drawable rows
or one blob, whether `C-RET` is bound to what you think it is, whether
the mode line a user reads says `:dead` when the kernel died.

This directory is the other half: a profile for
[emacs-harness](https://github.com/EGuthrieWasTaken/emacs-harness),
which runs a **real graphical Emacs on an X server in a container** and
lets a test — or an agent — drive it through the actual command loop and
read back exactly what is on screen.

**46 scenarios.** 39 assert things a batch Emacs can also check and run
either way; 7 need a frame and skip without one.

---

## Running it

### The real thing — in the container

```bash
git clone https://github.com/EGuthrieWasTaken/emacs-harness ../emacs-harness
harness/run.sh --build
```

Then, once the image exists:

```bash
harness/run.sh                                   # every scenario
harness/run.sh -- run jsonyter --tag notebook    # one tag
harness/run.sh -- run jsonyter --scenario jsonyter/notebook-image-actually-decodes
harness/run.sh -- doctor                         # what can this image do?
```

Artifacts land in `runs/<id>/<scenario>/`: screenshots, buffer
snapshots, `*Messages*`, the bridge's stderr, and a backtrace for
anything that failed.

### The fast loop — batch, no container

```bash
harness/run-batch.sh                       # every scenario
harness/run-batch.sh '(tag repl)'          # an ERT selector
```

Same scenario files under plain `ert-run-tests-batch-and-exit`
(emacs-harness DESIGN §8.1). Seconds instead of minutes, and it needs
only `emacs-nox` plus an emacs-harness checkout. **Every graphical
scenario skips**, which is to say most of what the harness exists for —
so use it to get an assertion right, then run the container before
believing it.

### Driving a live session by hand

The point of the harness is not only the suite. An agent (or a person)
can hold a session open and poke at it — which is how you work out what
a bug actually *is* before writing the scenario that pins it:

```bash
eh session new --name jy --profile jsonyter
eh eval '(jy-start-repl)'
eh type 'small_plot()'
eh keys "RET"
eh wait jsonyter-idle
eh snapshot --buffer '*jsonyter[python]*' --images   # what is actually there
eh shot --out /tmp/repl.png                          # what it actually looks like
```

Exploration is disposable; scenarios accumulate. When you have worked
out what was wrong, add the scenario before closing it out.

---

## What is in here

```
harness/
├── run.sh              run the profile in a container
├── run-batch.sh        run the same scenarios under batch ERT
├── Dockerfile          the harness image + the real jsonyter bridge
└── profile/
    ├── profile.el      snapshot properties, named waiters, log buffers
    ├── init.el         the only config the Emacs under test sees
    ├── fixtures/       demo.ipynb, solid-plot.ipynb, cells.py, blocks.org, 3 PNGs
    ├── bridge-scripts/ the scripted stand-ins for the Python bridge
    └── scenarios/      repl · notebook · script · org · kernel-state · visual
```

The profile lives **here rather than in the harness repository** so that
a behaviour change and the scenario covering it are one commit in one
pull request. `run.sh` mounts it over `/srv/profiles/jsonyter` and this
repository read-only over `/srv/package`; no image rebuild is needed to
change either.

---

## The fake bridge, and why most scenarios use one

jsonyter.el talks to the `jsonyter` Python package over a line-oriented
JSON protocol on stdin/stdout. `jsonyter-command` is the option that
says how to launch it — so the profile points that at
`eh-fake-bridge`, a scriptable stand-in, and the package starts its
bridge exactly as it always does, appends its own `--url` and token
flags, and never learns the difference.

That is not a shortcut around a real server. It is the only way to reach
a whole class of states:

| `bridge-scripts/` | The state it stages | Why not for real |
| --- | --- | --- |
| `dying-kernel.jsonl` | the kernel dies mid-session, of something unrelated | killing a real kernel is racy and destroys the session under test |
| `lost-connection.jsonl` | a half-open socket — kernel alive, connection gone | needs the network actually broken mid-request |
| `busy-elsewhere.jsonl` | busy on behalf of *another* client (`:run[ext]`) | needs a second client attached at exactly the right moment |
| `wedged.jsonl` | a request accepted and never answered | the SAS kernel really does this to `history`; nothing else does it on cue |
| `unauthorized.jsonl` | a token-protected server's bare `Forbidden` | needs a server configured to reject you |
| `no-subscribe.jsonl` | an older bridge with no `subscribe` method | needs an old bridge installed |
| `streaming.jsonl` | output over time, a progress bar redrawing in place, `input()` mid-cell | needs byte-level control of timing, and a human to answer the prompt |
| `--fault stderr-noise` | the backend chattering on stderr while the protocol runs | needs a backend that misbehaves on request |

`base.jsonl` is the connection lifecycle every buffer walks through;
`python.jsonl` the everyday execute rules. A scenario layers its own
script *in front* of those with `jy-use-scripts`, and first match wins,
so a script can override a default rather than only add to it.

**The three scenarios the fake cannot answer** — saving a notebook — use
the real `jsonyter` Python package, because a save is written by the
bridge's own `write_notebook` and what comes out is a file the *backend*
wrote. They are gated on `:needs (:executable "jsonyter")` and skip
legibly where it is not installed. They start no kernel and need no
Jupyter server.

### Keeping fixtures honest

A fixture written from a protocol spec is how a suite ends up passing
against a fiction. When adding one, record real traffic instead:

```bash
eh-fake-bridge --record new-fixture.jsonl -- jsonyter --url http://localhost:8888
```

That proxies a real bridge, passing everything through unchanged, and
writes a replayable script of what actually crossed the wire. Hand-edit
afterwards.

---

## What the scenarios cover

**`repl.el` (12)** — the connection lifecycle; `RET` sending through the
command loop; sent input frozen while the live input area stays
editable; `Out[N]:` prompts; streamed output appearing *while the kernel
is still busy* and not being rendered twice when the final reply repeats
it; stderr faced differently from stdout; tracebacks with their ANSI
resolved; `RET` continuing incomplete input; history cycling restoring
the stashed half-typed line; kernel-backed completion; `C-c M-o`;
restart asking first and resetting the count.

**`notebook.el` (12)** — stored outputs rendering with no kernel; source
editable and output read-only in the same buffer; output outside the
undo history and not a modification; `C-RET` running one cell and only
that cell; staleness flipping on edit *and back* on undo; a save writing
source only, byte-for-byte; structural edits carrying output with their
cell; `C-c M-O`; toggling to markdown dropping output.

**`script.el` (3)** — `# %%` cells; output living in overlays so the
file is never touched; cell navigation.

**`org.el` (4)** — `jy:` blocks running into overlays with no
`#+RESULTS:` drawer until asked; two kernels in one file kept apart; a
block *without* a `jy:` session left entirely to Org.

**`kernel-state.el` (8)** — every row of the table above.

**`visual.el` (7, graphical only)** — an image that actually decodes
rather than a placeholder; a tall image sliced into rows with distinct,
ordered geometry; a sliced flat-colour image with no pixel of anything
else showing through it, the direct check behind the two above; `line-
spacing` dropped so slices tile; a REPL image rasterising in a live
frame; the mode-line tag reaching the rendered
mode line; one full-frame reference shot.

---

## Adding a scenario

1. Reproduce interactively against a live session (`eh eval`, `eh keys`,
   `eh shot`) until you know what is actually wrong.
2. If it needs the backend to behave in a way `bridge-scripts/` does not
   cover yet, add a rule — or record one.
3. Write the scenario in the file its surface belongs to. **Drive it
   with keys**: `eh-send-keys "C-c C-e"` exercises the keymap, the
   command loop and `last-command`; calling the function exercises none
   of them and will pass while the binding itself is broken.
4. **Never assert without waiting.** Every kernel round trip is
   asynchronous. Use `eh-wait` or one of the profile's named waiters
   (`jsonyter-idle`, `jsonyter-dead`, `jsonyter-offline`, …). A
   scenario that passes because a `sleep` happened to be long enough is
   one that will fail in CI.
5. Prefer a tier-1 assertion — text, faces, properties, overlays,
   read-only-ness — over a pixel one. Pixels are for questions whose
   answer is literally "did this rasterise", and the budget for the
   whole profile is on the order of 10–15 baselines.
6. Run `harness/run-batch.sh` while iterating, then `harness/run.sh`
   before you believe it.

---

## Continuous integration

`.github/workflows/harness.yml` runs both halves on every pull request:
the container job (a real frame, every scenario) and a batch job (the
existing `test/` suite plus the scenarios' tier-1 assertions, which
catches a broken scenario file in seconds rather than after an image
build). `runs/` is uploaded on failure, so a red check comes with the
screenshots and snapshots of the frame it failed in.

emacs-harness is a public repository, so the workflow's default
`GITHUB_TOKEN` checks it out with nothing else to configure — no secret,
no setup step.

Its ref is pinned to a commit in the workflow's `HARNESS_REF`, currently
`4756dcb`. Bump it on purpose, in its own commit: tracking `main` would
let a change over there turn a pull request red here that touched none
of it, and the person left debugging that is the one least equipped to.
