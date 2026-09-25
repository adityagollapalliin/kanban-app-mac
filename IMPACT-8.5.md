# Impact analysis — Milestone 8.5, advanced Jira features

Written before any code changes, as §7 now requires: *"When the brief changes
after some milestones are built, first write an impact analysis … Wait for my
approval before changing code."*

Nothing in this document has been implemented. The working tree is at
`1ace5ce` (Milestone 8, schema 8) and is clean.

---

## 0. Two standing rules I am not currently meeting

These arrived with the new text and are not satisfied by what is already
built. Both are cheap to fix and both should be fixed *before* 8.5 starts,
because 8.5 is the largest schema change the project has had.

| Rule | State | Proposed fix |
|---|---|---|
| "Back up the store automatically before running a migration." | **Not done.** `Database.migrate()` upgrades in place. A failed migration leaves the file at the last version that fully applied, which is recoverable, but there is no copy to go back to. | Copy `board.sqlite` (with its WAL checkpointed) to `Backups/board-v<n>-<date>.sqlite` inside the container before the first statement of any migration run; keep the last five. |
| "Commit to git and tag each completed milestone (e.g. `milestone-1.5`)." | **Not done — there are no tags at all.** | Backfill the eight tags below, then tag as I go. |

Proposed backfill (each at the commit that completed that milestone):

```
milestone-0    98fba3a    milestone-5    e67cd0c
milestone-1    139f1ec    milestone-6    70949f1
milestone-1.5  51b5a95    milestone-7    59f1423
milestone-2    25cee18    milestone-8    1ace5ce
milestone-3    34b97eb
milestone-4    026da12
```

Milestones 3, 4 and 5 were not committed one-to-one — `e67cd0c` is "Milestones
3 to 5" — so `milestone-3` and `milestone-4` point at the commits that
*contained* that work rather than at a commit that completed it alone. Say the
word if you would rather have only the tags that are honest one-to-one
(`0`, `1`, `1.5`, `2`, `5`, `6`, `7`, `8`).

On "SwiftData versioned schemas": this project has never used SwiftData. It
uses the `PRAGMA user_version` migration ladder, which the brief permits as
"or equivalent SQL migrations". No change of approach is proposed.

---

## 1. The headline risk: four fixed enumerations must become user data

This is the structural heart of 8.5 and the thing most likely to break saved
data if done carelessly.

| Today | Stored as | 8.5 requires |
|---|---|---|
| `TaskType` — epic, story, task, bug | `task.type` INTEGER | Custom issue types with icons, and a configurable hierarchy above Epic |
| `Priority` — lowest…highest | `task.priority` INTEGER | Customizable priority schemes |
| `LinkKind` | `task_link.kind` INTEGER | Configurable link types in named pairs |
| *(no resolution at all)* | — | A customizable Resolution scheme |

**Migration approach: keep the integer column, add a table beside it.**

Each becomes a row table (`issue_type`, `priority_scheme` + `priority_value`,
`link_type`, `resolution`) seeded during the migration with exactly today's
values, **keeping today's raw integers as the rows' ids**. `task.type` stays
an INTEGER and keeps meaning what it means; it simply now refers to a row
somebody can rename, re-icon or add siblings to.

Why this rather than a `TEXT` foreign key: every saved filter, every board
column rule, every automation and the whole query compiler already compare
against those integers. Rewriting the column would mean rewriting all of them
in the same migration, and any one that was missed would silently match the
wrong thing. Keeping the integer makes the migration additive and makes
"nothing changes until somebody asks for something" true again.

**Consequence to accept:** `Priority`'s `Comparable` conformance is what makes
`priority >= high` work. A custom scheme has to carry an explicit rank so that
comparison still has a meaning. I propose each priority row carries a `rank`,
and the seeded rows' ranks are today's raw values.

**Code affected:** `Enumerations.swift`, `Models.swift`, `RowDecoding.swift`,
`TaskQuery.swift`, `TaskQueryCompiler.swift`, `CardAppearance.swift`,
`TaskCardView`, `ListView`, `TableView`, `BulkActionBar`, `CommandPalette`,
`ProjectSettingsView`, `AutomationRepository`, `WorkflowRepository`.

---

## 2. The query language — the backward-compatibility promise

> "Every previously saved filter must still parse and return the same
> results. Add regression tests for this."

Today: a 496-line hand-written parser (`TaskQuery.swift`) and a 580-line
compiler, with `field op value`, `is:` flags, `cf:Name`, `and`/`or`/`not`,
bare text, and relative dates. Saved filters live in `saved_view.query`, and
the same text also lives in `quick_filter`, `view_config.filter_query`,
`goal.query` and `dashboard_widget.query` — **five** places, not one. Any
parser change affects all five.

JQL adds: `ORDER BY`, `IN`, `NOT IN`, `IS EMPTY`, `~`, the history operators
`WAS` / `CHANGED` / `CHANGED FROM … TO … DURING`, and ten functions.

**Two genuine conflicts with what exists:**

1. **Bare text search.** Today an unrecognised word is a full-text search
   term. In JQL a bare word is a syntax error. If I adopt JQL strictly,
   every saved filter that relies on bare text stops working. **Proposal:**
   keep bare text as text search; it is a deliberate divergence from JQL and I
   will document it rather than quietly dropping it.
2. **`=` vs `~`.** Today `title = foo` already matches loosely for text
   fields. JQL reserves `~` for that and makes `=` exact. Changing `=` would
   change the results of existing saved filters. **Proposal:** add `~`, leave
   `=` behaving exactly as it does today.

**Regression approach:** before touching the parser, snapshot every query
string in those five tables from the live database plus every query in the
existing test suite into a fixture file, and assert that each one parses to
the identical `TaskFilter` and compiles to the identical SQL before and after.
That fixture is the contract; it goes in the repo so it survives me.

**History operators need history that does not exist yet.** `WAS` and
`CHANGED FROM "X" TO "Y"` can be answered for *status* (we have
`status_change` since v3, backfilled to creation) but not for any other field,
because field-level history has never been recorded (see §5). Honest position:
these operators will work on status immediately and on other fields only from
the day the audit table starts recording. They must not silently return empty
for older data — they should say what window they can answer for.

---

## 3. Sprints — a real breaking assumption

`SprintRepository.activeSprint(inProject:)` returns **one** optional sprint,
and `BoardViewModel.activeSprint` is a single value the burndown, the sprint
badge and the backlog all read. 8.5 requires **multiple parallel sprints**.

This is not additive: it changes a return type and every call site. Affected:
`SprintRepository`, `AnalyticsRepository.burndown`, `SprintsView`,
`BacklogView`, `CardDetailSections`, `BoardViewModel`, `DashboardDataRepository`
(the burndown widget picks "the active sprint").

**Proposal:** `activeSprints(inProject:) -> [Sprint]`, with the old single
accessor kept as "the first active sprint" only where a single answer is
genuinely required (the card's sprint badge). The burndown widget and the
sprint report gain an explicit sprint picker rather than guessing.

Also new here: sprint scope-change markers (needs a recorded "added to sprint
at" time — new column on `sprint_commitment`), per-person capacity *per
sprint* (we have capacity per person globally, from v6), and the
complete-sprint dialog.

---

## 4. Time tracking — two changes that can corrupt figures

Today: one `task.estimate` REAL, plus `work_log` rows. 8.5 wants Jira's
three-value model — Original estimate, Remaining estimate, Time spent — with
`1w 2d 3h 30m` syntax and configurable hours/day and days/week.

- **Migration:** `task.estimate` becomes Original estimate (a rename in
  meaning, not in storage); `remaining_estimate` is added and backfilled to
  equal the original minus time already logged, floored at zero. That is the
  only defensible backfill, and it should be stated in the changelog because
  it is an *interpretation* of existing data, not a copy of it.
- **Risk in the parser:** `DurationFormat.minutes(from:)` currently reads a
  bare `30` as thirty minutes and `0.5` as half an hour, and is used by the
  timesheet and the card's work-log box. Adding `w` and `d` is additive, but
  **units become relative to a setting** — `1d` means eight hours or
  twenty-four depending on configuration. Existing stored values are minutes
  and are unaffected; only new typing is interpreted. I will not
  retro-reinterpret anything already logged.

---

## 5. History — what cannot be recovered

8.5 wants a History tab with "field-level before/after diffs with timestamps".

`EditHistory.swift` is an **undo stack**, not an audit log: it is in memory,
bounded, and dies with the window. The only durable history is `status_change`.
There is no record of who changed a priority last March, and none can be
invented.

**Proposal:** a `task_history` table written from today forward, and the tab
says plainly that it covers changes since the feature arrived, with status
changes shown from their real history back to each card's creation. A History
tab that looked complete and was not would be worse than one that admits its
start date.

---

## 6. Everything with no existing counterpart

These are new subsystems rather than changes, so they carry migration risk
only in the tables they add:

- **Plans and scenarios** (cross-Space, hierarchy levels, capacity per sprint,
  dependency report, sandboxed changes committed on demand). The scenario
  sandbox is the largest single new idea in 8.5: draft edits that are *not*
  applied to real tasks until committed. That is a shadow-write store with its
  own lifecycle, and it should be its own phase.
- **Service desk**: queues, SLA timers, pause conditions, working-hours
  calendars, breach warnings. Off by default, as specified.
- **Inbox**, watching, filter subscriptions, per-event notification settings.
  `DueDateReminders` already owns `UNUserNotificationCenter`, so this extends
  rather than introduces.
- **Importers** for Jira CSV/JSON and ClickUp CSV, with a mapping step. Reads
  a file the user picks — the same sandbox capability attachments already use.
  No API access, consistent with the no-network rule.
- **Reports** (nine new) and **export to CSV / PNG / PDF** via a Save panel.
- **Issue navigator**, **components**, **Affects/Fix Version**
  (`version` exists since v3 but is used as a single "fix version"; affects
  version is new), **Environment**, **field configuration per issue type**,
  **visual workflow editor**, **clone/move with key aliases**, **rich text**,
  **Quick Look preview**, **single-key shortcuts**.

---

## 7. Things I need you to decide before I start

1. **Single-key shortcuts conflict with what is already bound.** `j`/`k` and
   the arrow keys both want to move the selection; `e`, `a`, `i`, `m`, `.`
   are plain letters that must not fire while you are typing in a title,
   comment or query box. Do you want them **on by default** (Jira's habit) or
   **behind a setting**? I would default them on but suppress them whenever a
   text field has focus.
2. **The `localboard://` URL scheme** needs a `CFBundleURLTypes` entry in
   `App/Info.plist`. It is a declaration rather than an entitlement, and the
   brief asks for it explicitly — I am flagging it only because §7 says to ask
   before changing the app's declared capabilities. Confirm and I will add it.
3. **Quick Look preview** means linking `QuickLookUI`. A system framework, not
   a third-party dependency, but it is new to this app. Confirm.
4. **Order and size.** 8.5 is roughly the size of Milestones 6, 7 and 8 put
   together. I propose six phases, each ending with tests, the network check,
   measured memory and a tag:

   | Phase | Contents | Schema |
   |---|---|---|
   | 8.5a | Backup-before-migration, tag backfill, resolutions, status-category cleanup, configurable types/priorities/links, components, Affects/Fix Version, Environment | v9 |
   | 8.5b | Query language → JQL, with the regression fixture first; issue navigator; saved/starred filters | v10 |
   | 8.5c | Workflow editor with conditions, validators, post-functions and transition screens; field configuration per issue type | v11 |
   | 8.5d | Time tracking triple, field-level history, detail tabs, rich text, clone/move/convert, URL scheme, shortcuts | v12 |
   | 8.5e | Sprints (parallel, scope change, complete dialog), backlog panels, Plans and scenarios | v13 |
   | 8.5f | Reports + export, automation upgrade, Inbox/watch/subscriptions, importers, service desk | v14 |

   Is that the order you want? In particular, 8.5b before 8.5c means the
   workflow editor can use the new query language for its conditions; the
   other way round means one less rewrite later.
5. **Automation upgrade and existing rules.** Today's `automation` row is one
   trigger and one action. The new builder has branches and smart values.
   Existing rows migrate to single-step rules with no branch. Confirm that
   existing automations continuing to behave identically is the priority, even
   where the new model would express them differently.

---

## 8. What is *not* affected

Worth saying, because it bounds the risk: nothing in 8.5 touches the board
canvas, lists, folders, spaces, docs, whiteboards, the notepad, goals,
dashboards, the calendar, mind map, box view, or the no-network guarantee.
Every table added is empty after its migration, and every column added keeps
its prior behaviour as the default — the same rule that has held since v2.
