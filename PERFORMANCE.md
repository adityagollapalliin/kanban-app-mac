# Performance

The budget from the brief, what was measured, and how to measure it again.

## The budget, and where it stands

Measured on an Apple silicon Mac against a board of **1,013 cards**, seeded
with `localboard seed --count 1000`.

| Budget | Target | Measured at 1,013 cards |
|---|---|---|
| Idle memory | under 80 MB; hard ceiling 150 MB at 1,000 cards | **103 MB** board, **93 MB** list, **85 MB** table, **81 MB** my work, **77 MB** calendar, **96 MB** mind map, **71 MB** everything, **69 MB** activity, **62 MB** workload and whiteboard, **61 MB** box, **57 MB** docs, **56 MB** notepad (**67 MB** on a seven-card board) |
| Idle CPU | ~0%, no polling | **0.0%** |
| Launch | under 1 second to usable UI | **~150 ms** to process, UI immediately after |

### A correction to the earlier figures

An earlier version of this file reported **84.2 MB** at 1,007 cards and said
full-height columns were lazy. Re-measured with the board actually on screen,
the same build used **499 MB** — over the ceiling by more than three times.

The cause was two scroll views inside each other. The board scrolled in both
directions, and each column scrolled again inside it; a `LazyVStack` given
unbounded height concludes that all of it is visible and builds every card.
The laziness was real code and no laziness at all.

Two fixes, both in this release:

- **A board without swimlanes now scrolls sideways only**, and each column
  scrolls itself. Bounding the height is what makes the laziness real:
  499 MB → 86 MB.
- **A lane draws twelve cards and then says how many more there are**, with a
  click to show the rest. Lanes cannot scroll on their own — that is what
  makes them lanes — so everything in one is built at once, which is fine for
  the handful a lane usually holds and ruinous for a lane holding eight
  hundred: 503 MB → 107 MB.

The calendar's "no date" strip had the same shape of problem — every undated
card built at once — and is now lazy: 181 MB → 77 MB. So did **My Work** in
Milestone 7, whose Unscheduled section held nine hundred cards and cost
**361 MB**; each section now shows twenty and offers the rest, which is
**81 MB**.

The lesson worth keeping, now four times over: **a nested lazy container is
not lazy, and a container with no scrolling region of its own cannot be lazy
at all.** No test can tell you either. Only measuring with the view on screen
can — which is why every screen in this table was measured that way, one at a
time, rather than inferred from the board's number.

The same rule caught a third case in Milestone 6: the **mind map** built every
node at once and cost **297 MB** at a thousand cards. A map has no scrolling
region of its own to be lazy inside — the curves have to be drawn between
nodes that both exist — so it is bounded instead: a hundred and fifty nodes,
with a line saying what it is not showing. **297 MB → 96 MB**, and a map of a
thousand cards was not readable anyway.

### Measure memory the way Activity Monitor does

`ps -o rss` is misleading here: it counts shared framework pages, and reports
about 192 MB for a process whose actual footprint is 107 MB. The number that
matches Activity Monitor's "Memory" column is the physical footprint:

```sh
vmmap --summary $(pgrep -x LocalBoard) | grep 'Physical footprint'
# or
footprint -p $(pgrep -x LocalBoard)
```

## Seeding a board worth measuring

```sh
localboard seed --count 1000     # 1,000 cards spread across the columns
```

They are ordinary cards, so remove them the ordinary way — or, since they all
sit above your real cards' numbers, with SQL against `board.sqlite`.

## How the budget is held

**No polling.** Nothing runs on a timer to see whether anything changed. The
board notices another process's writes by reading `PRAGMA data_version` once,
when the window becomes active. The diagnostics purge runs at launch, on wake,
and on a low-frequency tolerance-enabled timer that does not prevent App Nap.

**Queries, not scans.** Schema indexes are chosen for the queries the board
actually runs: one column of one board, the backlog, and anything filtered by
date, assignee or label. Full-text search uses an FTS5 external-content table.

**One pass per board, not one per card.** Everything a card carries — labels,
checklist progress, subtask progress, comment and attachment counts, custom
field values, links — is gathered in a single query each and grouped in
memory. A board of two hundred cards costs the same handful of statements as a
board of two. The link cache exists precisely because the timeline once asked
per card per redraw.

**Lazy where it pays, and bounded where it cannot be.** A full-height column
uses `LazyVStack` inside its own vertical scroll view, and the board around it
scrolls sideways only — so the column has a real height and the laziness
works. A lane has no scroll view of its own, so it is capped at twelve cards
with a "more…" button rather than made lazy: a lazy stack nested in a view
that also scrolls vertically builds everything, which is the bug this
release fixed.

**Analytics are computed, never cached.** The cumulative flow diagram, control
chart, burndown and burnup all replay `status_change` when the screen opens.
There is no cache to go stale and no nightly job to miss a run. A busy year is
tens of thousands of rows, which SQLite returns in milliseconds.

## Measuring it yourself with Instruments

- **Allocations** — launch, open a seeded board, scroll every column, open
  the analytics screen. Watch for growth that does not come back down after
  switching screens; the snapshot is replaced wholesale on each load, so
  persistent growth means something is holding an old one.
- **Time Profiler** — drag a card between columns. The move is one
  transaction: a midpoint write, a history row, and a rebalance only when the
  gap can no longer be split.
- **Energy Log** — leave the app open and untouched for ten minutes. It should
  register no activity at all; anything else means something is polling.

## What to watch as the data grows

The board reads every card in the project into one snapshot. That is the right
trade at a thousand cards and the first thing to change if it stops being one
— `BoardViewModel` is the single type that would have to change, and the
snapshot is already a value the views cannot reach through.
