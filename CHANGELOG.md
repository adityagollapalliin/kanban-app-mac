# Changelog

All notable changes to LocalBoard. Newest first.

The version numbers are the app's marketing version; the **schema** number
beside them is the on-disk format, which moves independently. `localboard
version` prints both.

## Unreleased — schema 6

### Milestone 6: structure and views
- **Hierarchy**: Workspace → Space → Folder (optional) → List → Task. A project
  *became* a space rather than being replaced by one — it already owned the
  statuses, fields, rules and sprints a space owns — so no row moved and every
  id still means what it meant. Every existing project gained one list holding
  everything it had, so a file that has never made a second list reads exactly
  as it did before. Spaces take a colour and an SF Symbol.
- **Statuses per space, overridden per list.** Inheritance is the absence of an
  override rather than a flag, so no list can claim to override and override
  nothing.
- **Several people on a card**, with a share of the estimate each. The first is
  still `assignee_id`, so `is:mine`, the card's avatar and every query written
  before this still read something true.
- **One card, several lists.** A card has one home and can be shown anywhere
  else; the panel says where, and an edit in any of them is the same card.
- **Milestones**: drawn on the timeline as diamonds, because a date has no
  length and a bar would claim one.
- **Recurring cards**: daily, weekly (by weekday), monthly (by date or by
  "the 2nd Tuesday"), yearly — on a schedule or after completion, with the
  checklist, subtasks and status reset as asked. Finishing one produces the
  next and leaves the finished one finished, so the history survives. A missed
  fortnight catches up by one card, not fourteen.
- **Six more views**, each remembering its own sort, grouping, filter and
  columns *per place*: **Table** (editable cells, totals, CSV export),
  **Workload** (capacity per person, red when over, drag to rebalance),
  **Box** (per person, with a status breakdown), **Everything** (every space,
  same filters), **Activity** (a feed derived from the file's own history
  rather than a second log to keep in step), and **Mind Map** (a node graph
  where adding a node creates a card and dragging one onto another makes it a
  subtask).
- **Sidebar**: favourites, pinned views, recently viewed, an archive that puts
  things back, and a trash that says how many days each card has left. Cards
  are removed thirty days after they are thrown away, counted from when that
  happened rather than from when the card was last edited.

### Fixed
- **A pinned table header drew over its own first rows.** The same fault as
  the lazy-stack one below: a pinned section header inside a view that scrolls
  both ways mis-measures. The header is now a safe-area inset on a vertically
  bounded scroll view.
- **The mind map cost 297 MB at a thousand cards.** It is now bounded to a
  hundred and fifty nodes, which is more than a map can usefully show, and it
  says what it is leaving out. 297 MB → 96 MB.
- **The trash countdown said 29 days the moment a card was thrown away.** It
  truncated a part-day; it now rounds up, so the last day you can still
  recover something does not read as zero.

## Unreleased — schema 5

### Milestone 2: the two views that were missing
- **List view**: the same filtered cards as a sortable table — key, title,
  status, priority, assignee, due, points and days in column — groupable by
  status, assignee, priority, type, epic or sprint. Selecting one row opens
  it; selecting several is a bulk edit through the same bar the board uses.
- **Calendar view**: a month of the same cards, against due dates or start
  dates. Cards are dragged between days to change the date, and the ones with
  no date sit in a strip along the bottom where they can be dragged onto one.
- **Import**: `localboard import <file>` reads back what `localboard export`
  writes, as a new project. Always a new project, never a merge — see
  `ProjectArchive.restore` for why. Assignees are matched to people already in
  the file by name; card numbers survive, so WORK-14 is still 14.
  The export format gained people, labels, label attachments and checklists,
  all optional on the way in, so a file written by an older build still reads.

### Fixed
- **A thousand-card board used half a gigabyte.** The board scrolled in both
  directions and each column scrolled again inside it, so the columns'
  `LazyVStack`s were handed unbounded height and built every card. A board
  without swimlanes now scrolls sideways only, and a lane — which cannot
  scroll on its own — draws twelve cards and offers the rest on a click.
  499 MB → 86 MB, and 503 MB → 107 MB with swimlanes. See PERFORMANCE.md,
  which carried the wrong number until now.

### Milestone 5: Polish
- **Light, dark or system**, in Settings → Appearance, alongside the accent
  and density that were already there. System is the default and follows the
  Mac, including when it switches at sunset.
- **Keyboard navigation** on the board: arrow keys move between cards, ⌘ with
  an arrow moves the card itself, Return opens, Space selects, Escape gives
  back the selection and then the focus, Delete trashes. ⌘N opens the
  add-a-card field in the column the keyboard is already in.
- **Command palette** (⌘K) over every card and every action, ranked so that
  what you typed comes first: an exact match beats a prefix, which beats a
  word beginning, which beats a match buried in the middle.
- **Undo and redo** throughout, with the standard shortcuts in the Edit menu.
  One mechanism covers a single mistyped title and a twenty-card bulk edit.
  It does not cover labels, checklists or comments, which live in other
  tables — Undo never claims to reverse what it cannot.
- **Density** (comfortable or compact) and an **accent colour**, stored with
  the board rather than with the Mac.
- **Menu bar extra** showing what is due today and the running timer.
  Optional, and off unless asked for.

### Milestone 4: Productivity
- **Start/stop timer** per card, with one timer running at a time; stopping
  writes what it measured into the work log.
- **Templates** for cards and projects. A card template is built from a card
  that already exists.
- **Automations**: one trigger, one action, cascades capped at one level.
- **Local notifications** for due dates, at nine on the morning they are due.
  Off until asked for; nothing is registered with any push service.

### Milestone 3: Agile and tracking
- **Sprints**: plan, start, complete, carrying unfinished work forward. What a
  sprint committed to is recorded when it starts, so the burndown has a fixed
  line to measure against and added scope shows.
- **Burndown** and **velocity** charts.
- **Workflow rules**: allowed transitions per project. The only thing in the
  app that refuses a move rather than reporting it, and off by default.
- **Timeline** (Gantt) view with dependency arrows between blocked cards.

### Also
- **Lasso selection** on the board, alongside ⌘- and shift-click.
- **Custom fields** per project — text, number, date, choice, checkbox —
  searchable with `cf:Name`, and showable on cards.

### Fixed
- Lanes counted cards in their heading and then drew none: a `LazyVStack`
  nested inside the board's two-way scroll view decided none of itself was
  visible. Lanes now lay their cards out eagerly.

## Milestone 1.5 — schema 4

- Columns map to several statuses; a board is a view of the work rather than
  the work itself.
- Swimlanes, quick filters and facets, card colour rules, configurable card
  rows, days-in-column dots, flags with searchable reasons.
- WIP minimums and points-based limits, with amber and red states.
- Backlog screen with a commitment line; releases; boards defined by a query.
- Bulk edits with undo; a card in its own window.
- Comments, attachments, links between cards, and a work log.
- Cumulative flow, control chart and burnup, computed from recorded history.
- Optional read-only link to a local git checkout.

## Milestone 2 — schema 2

- The filter language and saved views.

## Milestone 1 — schema 1

- Sidebar, board, drag and drop, people, labels, checklists, subtasks and
  epics; structure management for columns, boards and projects.

## Milestone 0

- App shell, SQLite store with a migration ladder, and the `localboard` CLI.
