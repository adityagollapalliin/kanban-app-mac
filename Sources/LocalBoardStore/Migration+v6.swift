import Foundation

// Schema version 6 — the hierarchy, and the things that hang off it.
//
// A project has always been the thing that owns statuses, fields, rules and
// sprints. That is exactly what ClickUp calls a Space, so a project *becomes*
// a Space here rather than being replaced by one: no row moves, nothing is
// rewritten, and every id that existed still means what it meant.
//
// What arrives underneath it is new: optional folders, and lists that actually
// hold the cards. Every existing project gets one list containing everything
// it already had, so a file that has never heard of lists opens as a file with
// exactly one list per project — which is what it always was, now named.
//
// The rest follows the same rule as v5: every new table is empty after the
// migration, and every new column defaults to the behaviour that was there
// before. Upgrading changes nothing until somebody asks for something.
extension Migration {
    static let v6Structure = Migration(
        version: 6,
        name: "structure",
        statements: [

            // MARK: A project becomes a Space

            // A colour and an icon, because a sidebar of a dozen spaces is
            // unreadable as a dozen lines of text. Empty means "no choice
            // made", which draws as the app's accent rather than as a colour
            // nobody picked.
            "ALTER TABLE project ADD COLUMN color TEXT NOT NULL DEFAULT '';",
            "ALTER TABLE project ADD COLUMN icon TEXT NOT NULL DEFAULT '';",

            // MARK: Folders and lists

            // A folder is optional and holds lists. It owns nothing else: it
            // is a way of tidying a sidebar, not a level of the data model
            // that anything has to consult.
            """
            CREATE TABLE folder (
                id         TEXT PRIMARY KEY NOT NULL,
                project_id TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
                name       TEXT NOT NULL,
                color      TEXT NOT NULL DEFAULT '',
                icon       TEXT NOT NULL DEFAULT '',
                archived   INTEGER NOT NULL DEFAULT 0,
                sort_order REAL NOT NULL,
                created_at REAL NOT NULL
            );
            """,

            "CREATE INDEX folder_by_project ON folder (project_id, sort_order);",

            // A list holds cards. `folder_id` is nullable because a folder is
            // optional — a list sits either in a folder or directly in the
            // space, and both are ordinary rather than one being a fallback.
            """
            CREATE TABLE list (
                id         TEXT PRIMARY KEY NOT NULL,
                project_id TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
                folder_id  TEXT REFERENCES folder(id) ON DELETE SET NULL,
                name       TEXT NOT NULL,
                color      TEXT NOT NULL DEFAULT '',
                icon       TEXT NOT NULL DEFAULT '',
                archived   INTEGER NOT NULL DEFAULT 0,
                sort_order REAL NOT NULL,
                created_at REAL NOT NULL
            );
            """,

            "CREATE INDEX list_by_project ON list (project_id, sort_order);",
            "CREATE INDEX list_by_folder ON list (folder_id, sort_order);",

            // Every project gets one list holding everything it has. The name
            // is the project's own: on a file that never uses lists, the
            // sidebar then reads the same as it always did.
            """
            INSERT INTO list (id, project_id, folder_id, name, sort_order, created_at)
            SELECT lower(hex(randomblob(16))), id, NULL, name, 1000.0, created_at FROM project;
            """,

            // A card's home list. Nullable only for the instant between the
            // column arriving and the backfill below; every card has one.
            "ALTER TABLE task ADD COLUMN list_id TEXT REFERENCES list(id) ON DELETE SET NULL;",

            """
            UPDATE task SET list_id = (
                SELECT list.id FROM list WHERE list.project_id = task.project_id LIMIT 1
            );
            """,

            "CREATE INDEX task_by_list ON task (list_id, trashed, sort_order);",

            // MARK: Statuses per space, overridden per list

            // Empty for every list after the migration, and an empty override
            // means "use the space's statuses". A list that wants its own set
            // says so by having rows here — so inheritance is the absence of a
            // decision rather than a flag that can disagree with the rows.
            """
            CREATE TABLE list_status (
                list_id    TEXT NOT NULL REFERENCES list(id) ON DELETE CASCADE,
                status_id  TEXT NOT NULL REFERENCES status(id) ON DELETE CASCADE,
                sort_order REAL NOT NULL,
                PRIMARY KEY (list_id, status_id)
            );
            """,

            // MARK: Several people on one card

            // The card keeps `assignee_id` and it keeps meaning what it meant:
            // the first assignee. Everything that already reads it — queries,
            // `is:mine`, the avatar on the card — carries on working, and this
            // table is what the rest of them live in.
            """
            CREATE TABLE task_assignee (
                task_id    TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
                person_id  TEXT NOT NULL REFERENCES person(id) ON DELETE CASCADE,
                estimate   REAL,
                sort_order REAL NOT NULL,
                PRIMARY KEY (task_id, person_id)
            );
            """,

            "CREATE INDEX assignee_by_person ON task_assignee (person_id);",

            """
            INSERT INTO task_assignee (task_id, person_id, estimate, sort_order)
            SELECT id, assignee_id, NULL, 1000.0 FROM task WHERE assignee_id IS NOT NULL;
            """,

            // MARK: One card, several lists

            // The home list stays on the card. This table is only the *extra*
            // places it appears, so there is one answer to "where does this
            // card live" and a separate answer to "where else is it shown".
            """
            CREATE TABLE task_list (
                task_id    TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
                list_id    TEXT NOT NULL REFERENCES list(id) ON DELETE CASCADE,
                added_at   REAL NOT NULL,
                PRIMARY KEY (task_id, list_id)
            );
            """,

            "CREATE INDEX task_list_by_list ON task_list (list_id);",

            // MARK: Milestones

            // A milestone is a date that matters, drawn as a diamond rather
            // than a bar: it has no length, and giving it one would be a lie
            // about when the work happens.
            "ALTER TABLE task ADD COLUMN is_milestone INTEGER NOT NULL DEFAULT 0;",

            // MARK: Recurrence

            // One row per card, so a card either recurs or does not — rather
            // than a set of nullable columns on `task` that can half-describe
            // a rule nobody can act on.
            //
            // `mode` is the decision that matters: on a schedule, the next one
            // is due whether or not this one was done; on completion, the
            // clock starts when it is finished. A cleaner recurs weekly; a
            // filter change recurs three months after you actually changed it.
            """
            CREATE TABLE recurrence (
                id             TEXT PRIMARY KEY NOT NULL,
                task_id        TEXT NOT NULL UNIQUE REFERENCES task(id) ON DELETE CASCADE,
                frequency      INTEGER NOT NULL,          -- 0 daily, 1 weekly, 2 monthly, 3 yearly
                interval       INTEGER NOT NULL DEFAULT 1,
                weekdays       TEXT NOT NULL DEFAULT '',  -- comma-separated 1=Sun..7=Sat, weekly
                week_of_month  INTEGER,                   -- 1..5, or -1 for last; monthly
                month_day      INTEGER,                   -- 1..31; monthly
                mode           INTEGER NOT NULL DEFAULT 0, -- 0 schedule, 1 completion
                reset_checklist INTEGER NOT NULL DEFAULT 1,
                reset_subtasks  INTEGER NOT NULL DEFAULT 1,
                reset_status    INTEGER NOT NULL DEFAULT 1,
                ends_at        REAL,
                last_spawned_at REAL,
                created_at     REAL NOT NULL
            );
            """,

            // MARK: What each view remembers

            // Every view keeps its own sort, grouping, filter and columns, and
            // keeps them per place: the table you set up on one list should not
            // rearrange the table on another. `scope_id` is the list, folder,
            // space or board the settings belong to.
            """
            CREATE TABLE view_config (
                id           TEXT PRIMARY KEY NOT NULL,
                scope_kind   INTEGER NOT NULL,   -- 0 space, 1 folder, 2 list, 3 everything
                scope_id     TEXT NOT NULL DEFAULT '',
                view_kind    INTEGER NOT NULL,   -- 0 table, 1 workload, 2 box, 3 activity, 4 mind map, 5 everything
                group_by     TEXT NOT NULL DEFAULT '',
                sort_field   TEXT NOT NULL DEFAULT '',
                sort_ascending INTEGER NOT NULL DEFAULT 1,
                filter_query TEXT NOT NULL DEFAULT '',
                columns      TEXT NOT NULL DEFAULT '',
                updated_at   REAL NOT NULL,
                UNIQUE (scope_kind, scope_id, view_kind)
            );
            """,

            // MARK: Capacity, for the workload view

            // Per person, because capacity is a fact about a person and not
            // about a project. Zero means "not set", which draws as a bar with
            // no ceiling rather than as a person who can do nothing.
            "ALTER TABLE person ADD COLUMN capacity_amount REAL NOT NULL DEFAULT 0;",
            // unit: 0 hours, 1 points. period: 0 a day, 1 a week.
            "ALTER TABLE person ADD COLUMN capacity_unit INTEGER NOT NULL DEFAULT 0;",
            "ALTER TABLE person ADD COLUMN capacity_period INTEGER NOT NULL DEFAULT 1;",

            // MARK: Favourites, pins and what you were just looking at

            // One table for all three, because they are one idea — a shortcut
            // to something — differing only in whether the user put it there
            // and whether it expires.
            """
            CREATE TABLE shortcut (
                id         TEXT PRIMARY KEY NOT NULL,
                kind       INTEGER NOT NULL,   -- 0 favourite, 1 pinned view, 2 recently viewed
                target     INTEGER NOT NULL,   -- 0 space, 1 folder, 2 list, 3 board, 4 saved view, 5 task
                target_id  TEXT NOT NULL,
                label      TEXT NOT NULL DEFAULT '',
                sort_order REAL NOT NULL,
                at         REAL NOT NULL,
                UNIQUE (kind, target, target_id)
            );
            """,

            "CREATE INDEX shortcut_by_kind ON shortcut (kind, sort_order);",

            // MARK: Trash that empties itself

            // Thirty days from when it was thrown away, which is a different
            // date from when it was last edited — `updated_at` moves when the
            // trashing itself is recorded, so it cannot answer this.
            "ALTER TABLE task ADD COLUMN trashed_at REAL;",

            "UPDATE task SET trashed_at = updated_at WHERE trashed = 1;",

            "CREATE INDEX task_trashed_at ON task (trashed, trashed_at);",
        ]
    )
}
