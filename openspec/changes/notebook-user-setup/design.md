# Design

## Context

The configuration was an org-tangled `init` of about 2,100 lines. Only what could
touch a notebook buffer on each edit mattered, so it was read for per-edit hooks,
idle timers and display features, and reduced to those: `global-company-mode`
(0.1 s idle, a grouped `company-capf` backend with a dabbrev-derived one),
`yas-global-mode`, `global-flycheck-mode`, `display-line-numbers-mode` and
`display-fill-column-indicator-mode` on `prog-mode-hook`, `fill-column` 80, and a
`jsonyter-notebook-mode-hook` function that switches flycheck off. jsonyter itself
installs no per-edit network call in a notebook (its completion function is
REPL-only), so a hang had to come from the notebook's own overlays or from
interaction with one of those.

Method: a notebook generated at the scale the user described (120 cells, 312
outputs, 12 figures, 227,000 characters), then measured with real key events from
`xdotool` in a live frame on Xvfb with a profiler and per-timer timing, because
batch Emacs never redisplays and so cannot see the cost. `company`, `yasnippet`
and `flycheck` came from the distribution; Meow, doom-modeline and the rest do
not hook edits.

| Redisplay after a newline at the top | 0 reloads | 4 reloads | 20 reloads |
|---|---|---|---|
| 2.4.1, jsonyter alone | 3 ms | 240 ms | 9.5 s |
| 2.4.1, with the configuration's packages | 6 ms | 405 ms | 17.5 s |
| 2.5.0, with the configuration's packages | 4 ms | 4 ms | 4 ms |

Overlays after 20 reloads: 2,520 on 2.4.1 (120 real, 2,400 empty), 120 on 2.5.0.
A newline mid-notebook cost about 2 ms in every row. The configuration's
packages roughly double the pathology and cause none of it.

## Goals / Non-Goals

**Goals:**
- A test that fails when a reload leaves overlays behind, under the hooks a real
  user has.
- The fill-column indicator in the same place against source text with or without
  per-cell numbers.
- Help text that shows what the function does.

**Non-Goals:**
- No per-edit timing assertion: it would be flaky and batch cannot redisplay.
- No dependency on `company`, `yasnippet` or `flycheck` in the suite: what
  matters is their hooks, and a stand-in minor mode reproduces the one that is
  switched off.

## Decisions

- **Assert the cause, the overlay count.** After many reloads there must be one
  string-drawing overlay per cell, none empty, and an edit at the top must add
  none. Mutation-checked: with the render's call to `jsonyter--nb-forget-cells`
  and the after-change hook's `jsonyter--nb-drop-empty-cells` both removed (which
  is 2.4.1), three of the four user-setup tests fail. With only one removed they
  still pass, because 2.5.0 has two independent defences (a reload's own delete
  fires the hook that drops empty cells); that redundancy is deliberate and the
  tests do not demand it.
- **Shift the indicator by the narrowest gutter, once.** The column becomes
  `fill-column` (or a user-chosen integer) plus three, the width of a gutter for a
  cell under a hundred lines, and is restored on teardown. A per-cell shift is
  impossible, since the indicator is one line for the whole window; a notebook-wide
  maximum would need every prompt and prefix rewritten when any cell crossed a
  power of ten. A hundred-line cell is a column off and says so in the docs.
  Alternative: leave the indicator and document it. Rejected: it is on in many
  configurations (`prog-mode-hook`) and visible on every long line.
- **The indicator is set with `setq-local` through a bare `defvar`,** so it works
  before `display-fill-column-indicator-mode` has loaded its library, and whichever
  order the mode and the numbers are switched on in.
- **A docstring guard in the suite.** It scans every jsonyter function and
  variable for control characters, stray command-key references and implementation
  steps, so the `\[` mistake cannot return.

## Risks / Trade-offs

- A cell of a hundred lines or more has a gutter a column wider than the shift
  allows for, so a line of exactly `fill-column` characters ends a column past the
  indicator there.
- The indicator follows `fill-column` as it was when the numbers started; a later
  `setq-local` of `fill-column` is not tracked.
- Prompt and output rows have no gutter, so the indicator sits three columns right
  of where they reach column 80. One line cannot serve both, and it is source
  code the indicator is for.
