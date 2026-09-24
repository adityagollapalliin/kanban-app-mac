# Changelog

All notable changes to LocalBoard. Newest first.

The version numbers are the app's marketing version; the **schema** number
beside them is the on-disk format, which moves independently. `localboard
version` prints both.

## Unreleased — schema 5

### Milestone 5: Polish
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
