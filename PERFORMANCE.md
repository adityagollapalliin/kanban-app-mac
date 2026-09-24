# Performance

The budget from the brief, what was measured, and how to measure it again.

## The budget, and where it stands

Measured on an Apple silicon Mac against a board of **1,007 cards**, seeded
with `localboard seed --count 1000`.

| Budget | Target | Measured |
|---|---|---|
| Idle memory | under 80 MB; hard ceiling 150 MB at 1,000 cards | **59.5 MB** small board, **84.2 MB** at 1,007 cards |
| Idle CPU | ~0%, no polling | **0.0%** |
| Launch | under 1 second to usable UI | **~83 ms** to process, UI immediately after |

### Measure memory the way Activity Monitor does

`ps -o rss` is misleading here: it counts shared framework pages, and reports
about 158 MB for a process whose actual footprint is 84 MB. The number that
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

**Lazy where it pays.** Full-height columns use `LazyVStack`, so a column of
five hundred cards renders what is on screen. Lanes deliberately do **not**:
they hold a handful of cards, and a lazy stack nested in the board's two-way
scroll view could not work out which part of itself was visible.

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
