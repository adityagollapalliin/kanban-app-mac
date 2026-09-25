# Changelog

All notable changes to LocalBoard. Newest first.

The version numbers are the app's marketing version; the **schema** number
beside them is the on-disk format, which moves independently. `localboard
version` prints both.

## Unreleased — schema 8

### Milestone 8: goals, dashboards, fields & time
- **Goals** with a target and a date: a number you keep yourself, an amount of
  money, done-or-not, or cards finished — counted from a list or a query. The
  bar is measured from a *starting* figure rather than from zero, so a goal to
  bring open bugs down from forty to ten reads as no progress at forty rather
  than as four hundred per cent, and says "22, down to 10" rather than the
  nonsense of "22 of 10". Goals sit in folders; deleting a folder tidies it
  away without taking the goals with it.
- **Dashboards**: a grid of widgets, each one a saved query and a way of
  drawing it — a count, a breakdown by status, priority or assignee, a task
  list, workload, time tracked, a goal's bar, a note, a cumulative flow
  diagram, a sprint burndown. Several dashboards per space, widgets dragged
  to rearrange, and a new dashboard arrives with four widgets that already say
  something rather than as an empty grid and a button.
- **Six more kinds of field**: money (the currency belongs to the field, so a
  column of figures can be summed), a one-to-five rating, a progress
  percentage typed in or counted off the subtasks or checklist, a
  relationship to other cards, a **formula**, and a **rollup**.
- **Formulas** are arithmetic and date maths over the other fields — `{Due} -
  {Start}`, `if({Due} < today(), days(today(), {Due}), 0)` — evaluated by a
  small local expression language with no way to reach a file, a process or
  the network. It is bounded in length, nesting and steps; a formula that ends
  up reading itself is reported as a circular reference rather than running
  until the stack gives out; and one that will not parse is refused when the
  field is made, with the mistake named, rather than the first time somebody
  opens a card.
- **Rollups** gather from the subtasks or through a relationship field and
  reduce with sum, average, count, minimum or maximum. An average divides by
  the cards that actually answered, a count counts the cards including the
  ones that left it blank, and nothing related at all is blank rather than
  zero — because zero is a figure somebody might act on.
- **Billable time**, per entry and per card, counted apart from the rest.
  Existing entries default to not billable: hours logged before anybody was
  asked the question are not hours anybody stands behind.
- **A weekly timesheet** you can type into. A cell holds the day's total,
  which may be several entries written at different moments, so typing more
  adds an entry and typing less takes it off the most recent first — the notes
  on the others survive, which is the part of a timesheet worth anything a
  month later. `1:30`, `1.5`, `90m` and `1h 30m` all mean ninety minutes.
- **Time in status**, computed from the status history: average, longest, how
  many cards and how many visits — and where the visits outnumber the cards,
  work is coming back. On each card too, because "why has this been open three
  weeks" is asked one card at a time.

### Fixed
- A widget's width did nothing. `LazyVGrid` has no way to make one cell wider
  than another, so every widget drew one cell wide whatever was set. The grid
  now lays rows out itself, and a widget's height is honestly a box height
  rather than a row span — neither of SwiftUI's grids can draw a cell across
  two rows, and a stored layout the app cannot render is one that comes back
  wrong.
- Two time-log entries written in the same second — a timer stopped and a
  correction typed straight after — left it to SQLite which one a timesheet
  edit reduced. The order is now settled by insertion.
- The timesheet and the time-in-status report drew centred in the window: a
  scroll view hands its content only the width it asked for.

## Unreleased — schema 7

### Milestone 7: the day in front of you, and what is written beside it
- **My Work**: Overdue, Today, Next 7 days and Unscheduled, with dragging
  between them to reschedule. Overdue sits *above* today rather than inside
  it — something due yesterday is not part of today's plan — and takes no
  drops, because you cannot decide to have been late.
- **Plan my day**: a list to tick rather than a plan the app writes. Choosing
  a card for today does not move its due date: "I am doing this today" and
  "this is due today" are different statements.
- **Snoozing** cards and reminders — later today, tomorrow, next week — which
  also leaves the due date alone. The date is a promise to other people; a
  snooze is five minutes' peace.
- **Reminders**: standalone, deliberately not cards, with local
  notifications at the time they were set for rather than at nine on the day.
- **Natural language everywhere you type a card**: `Fix login bug tomorrow
  3pm !high #backend @Aditya` sets the date, the time, the priority, the label
  and the assignee. What it understood is shown as chips before you press
  Return, and a tag or name that matches nothing is drawn faintly and left
  off rather than invented.
- **Notepad**: one pad, always the same one, with any unticked line a click
  away from being a card — and ticked off in the pad when it becomes one.
- **Task tray**: cards set aside rather than closed, in a strip along the
  bottom.
- **Comment action items**: a remark becomes a request with somebody's name
  against it, ticked off where it was made. They appear under "Asked of you"
  in My Work.
- **Docs**: Markdown pages that nest, with a slash menu that inserts only
  Markdown, `@KEY-12` mentions that show the card's status as it is now, and
  backlinks on the card. Selected text becomes a card and leaves a mention
  behind, so the page still says what was decided and now says where it went.
- **Whiteboards**: an infinite canvas with sticky notes, shapes, text,
  freehand ink and connectors. A sticky becomes a card keeping everything it
  said — first line the title, the rest the notes.

### Fixed
- **My Work cost 361 MB at a thousand cards.** Its Unscheduled section drew
  every undated card; each section now shows twenty and offers the rest.
  361 MB → 81 MB.
- **The Docs page tree floated in the middle of the window.** An `HSplitView`
  sized it to its content, and an empty list has no height to give.

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
