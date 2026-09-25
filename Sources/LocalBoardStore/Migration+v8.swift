import Foundation

// Schema version 8 — what you are aiming at, what you are looking at, and
// what the hours were spent on.
//
// Three additions that are independent of one another:
//
//  * Goals. A goal is a number you want to reach by a date. The number either
//    comes from you (you type it in) or from the cards themselves (how many in
//    this list are done). Both are the same row; `kind` decides which of the
//    two is read, so there is one progress bar rather than two kinds of goal
//    that happen to look alike.
//
//  * Dashboards. A dashboard is a grid of widgets, and a widget is a saved
//    query plus a way of drawing it. Position is stored as grid cells rather
//    than points, so a dashboard laid out on a large display does not fall
//    apart on a small one.
//
//  * Richer fields, and billable time. The new field kinds are extra columns
//    on `custom_field` rather than a second table: a field has exactly one
//    kind, and the columns another kind would use stay null.
//
// As with every rung before it: every new table is empty when the migration
// finishes, and every new column defaults to what the app did yesterday.
extension Migration {
    static let v8Goals = Migration(
        version: 8,
        name: "goals",
        statements: [

            // MARK: Goals

            // Folders here are the same idea as folders over lists — a way of
            // tidying a list of goals, owning nothing and consulted by nothing.
            """
            CREATE TABLE goal_folder (
                id         TEXT PRIMARY KEY NOT NULL,
                project_id TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
                name       TEXT NOT NULL,
                sort_order REAL NOT NULL,
                created_at REAL NOT NULL
            );
            """,

            "CREATE INDEX goal_folder_by_project ON goal_folder (project_id, sort_order);",

            // `kind` says where the current value comes from:
            //   0 number    — a count you keep yourself
            //   1 currency  — the same, shown in `currency`
            //   2 boolean   — done or not; the target is 1
            //   3 tasks     — counted from the cards matching `query`
            //
            // `start_number` matters for the ones you keep yourself: a goal to
            // get from 40 open bugs down to 10 is at zero progress at 40, not
            // at 400%. For a target below the start the bar simply runs the
            // other way, which is the same arithmetic.
            """
            CREATE TABLE goal (
                id           TEXT PRIMARY KEY NOT NULL,
                project_id   TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
                folder_id    TEXT REFERENCES goal_folder(id) ON DELETE SET NULL,
                name         TEXT NOT NULL,
                notes        TEXT NOT NULL DEFAULT '',
                kind         INTEGER NOT NULL DEFAULT 0,
                start_number REAL NOT NULL DEFAULT 0,
                target_number REAL NOT NULL DEFAULT 1,
                current_number REAL NOT NULL DEFAULT 0,
                currency     TEXT NOT NULL DEFAULT 'USD',
                query        TEXT NOT NULL DEFAULT '',
                list_id      TEXT REFERENCES list(id) ON DELETE SET NULL,
                owner_id     TEXT REFERENCES person(id) ON DELETE SET NULL,
                due_at       REAL,
                completed_at REAL,
                archived     INTEGER NOT NULL DEFAULT 0,
                sort_order   REAL NOT NULL,
                created_at   REAL NOT NULL,
                updated_at   REAL NOT NULL
            );
            """,

            "CREATE INDEX goal_by_project ON goal (project_id, archived, sort_order);",
            "CREATE INDEX goal_by_folder ON goal (folder_id, sort_order);",

            // MARK: Dashboards

            """
            CREATE TABLE dashboard (
                id         TEXT PRIMARY KEY NOT NULL,
                project_id TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
                name       TEXT NOT NULL,
                sort_order REAL NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            """,

            "CREATE INDEX dashboard_by_project ON dashboard (project_id, sort_order);",

            // `column`/`row` are grid cells and `width`/`height` are spans in
            // cells. `config` is the widget's own settings as JSON — the chart
            // it draws, the goal it watches, the text of a note — and it is
            // per-kind, so a column per setting would be mostly nulls.
            """
            CREATE TABLE dashboard_widget (
                id           TEXT PRIMARY KEY NOT NULL,
                dashboard_id TEXT NOT NULL REFERENCES dashboard(id) ON DELETE CASCADE,
                kind         INTEGER NOT NULL,
                title        TEXT NOT NULL DEFAULT '',
                query        TEXT NOT NULL DEFAULT '',
                grid_column  INTEGER NOT NULL DEFAULT 0,
                grid_row     INTEGER NOT NULL DEFAULT 0,
                width        INTEGER NOT NULL DEFAULT 1,
                height       INTEGER NOT NULL DEFAULT 1,
                config       TEXT NOT NULL DEFAULT '',
                created_at   REAL NOT NULL
            );
            """,

            "CREATE INDEX widget_by_dashboard ON dashboard_widget (dashboard_id, grid_row, grid_column);",

            // MARK: Six more kinds of field

            // kind gains: 5 money, 6 rating, 7 progress, 8 relationship,
            // 9 formula, 10 rollup. Every column below is unused by the five
            // kinds that already exist, so existing fields are untouched.

            // Money: the amount goes in `number_value` like any other number,
            // and the currency belongs to the field rather than to each value —
            // a column of figures in mixed currencies cannot be summed.
            "ALTER TABLE custom_field ADD COLUMN currency TEXT NOT NULL DEFAULT 'USD';",

            // Progress: 0 typed in by hand, 1 from subtasks, 2 from checklist.
            "ALTER TABLE custom_field ADD COLUMN progress_mode INTEGER NOT NULL DEFAULT 0;",

            // Relationship: which list the other cards must come from. Null
            // means anywhere in the space.
            "ALTER TABLE custom_field ADD COLUMN target_list_id TEXT REFERENCES list(id) ON DELETE SET NULL;",

            // Formula: the expression, stored as the user typed it. It is
            // parsed and evaluated on read, never stored evaluated, so editing
            // a field it reads is immediately visible everywhere.
            "ALTER TABLE custom_field ADD COLUMN formula TEXT NOT NULL DEFAULT '';",

            // Rollup: where the rows come from (0 subtasks, 1 a relationship
            // field named by `rollup_link_id`), which field of them to read,
            // and how to reduce it (0 sum, 1 average, 2 count, 3 min, 4 max).
            "ALTER TABLE custom_field ADD COLUMN rollup_source INTEGER NOT NULL DEFAULT 0;",
            "ALTER TABLE custom_field ADD COLUMN rollup_link_id TEXT REFERENCES custom_field(id) ON DELETE SET NULL;",
            "ALTER TABLE custom_field ADD COLUMN rollup_field_id TEXT REFERENCES custom_field(id) ON DELETE SET NULL;",
            "ALTER TABLE custom_field ADD COLUMN rollup_function INTEGER NOT NULL DEFAULT 0;",

            // MARK: Billable time

            // Default 0: hours already logged were logged before anyone was
            // asked whether they were billable, and guessing yes would put
            // numbers on a timesheet that nobody stands behind.
            "ALTER TABLE work_log ADD COLUMN billable INTEGER NOT NULL DEFAULT 0;",

            "CREATE INDEX work_log_by_person ON work_log (person_id, worked_on);",
        ]
    )
}
