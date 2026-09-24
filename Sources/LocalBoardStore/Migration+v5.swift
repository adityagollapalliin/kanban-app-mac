import Foundation

// Schema version 5 — sprints, custom fields, rules and templates.
//
// The common thread: everything here is a project deciding how *it* works,
// rather than the app deciding for everyone. A project defines its own fields,
// its own allowed transitions, its own automations and its own templates —
// and a project that defines none of them behaves exactly as it did before.
//
// That last part is the design constraint. Every table here is empty after the
// migration and every new column defaults to off, so upgrading changes nothing
// until somebody asks for something.
extension Migration {
    static let v5Agile = Migration(
        version: 5,
        name: "agile",
        statements: [

            // MARK: Custom fields

            // Typed columns rather than one TEXT blob. A number field that
            // stores "12" as text cannot be compared, sorted or summed, and
            // `points > 3` in the query language would silently do string
            // comparison — which puts 10 before 9.
            """
            CREATE TABLE custom_field (
                id         TEXT PRIMARY KEY NOT NULL,
                project_id TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
                name       TEXT NOT NULL,
                kind       INTEGER NOT NULL,   -- 0 text, 1 number, 2 date, 3 choice, 4 checkbox
                options    TEXT NOT NULL DEFAULT '',  -- newline-separated, for choice
                sort_order REAL NOT NULL,
                created_at REAL NOT NULL,
                UNIQUE (project_id, name)
            );
            """,

            "CREATE INDEX custom_field_by_project ON custom_field (project_id, sort_order);",

            """
            CREATE TABLE custom_field_value (
                task_id      TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
                field_id     TEXT NOT NULL REFERENCES custom_field(id) ON DELETE CASCADE,
                text_value   TEXT,
                number_value REAL,
                date_value   REAL,
                bool_value   INTEGER,
                PRIMARY KEY (task_id, field_id)
            );
            """,

            "CREATE INDEX field_value_by_field ON custom_field_value (field_id);",

            // MARK: Sprints

            """
            CREATE TABLE sprint (
                id           TEXT PRIMARY KEY NOT NULL,
                project_id   TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
                name         TEXT NOT NULL,
                goal         TEXT NOT NULL DEFAULT '',
                state        INTEGER NOT NULL DEFAULT 0,  -- 0 planned, 1 active, 2 complete
                starts_at    REAL,
                ends_at      REAL,
                completed_at REAL,
                sort_order   REAL NOT NULL,
                created_at   REAL NOT NULL,
                UNIQUE (project_id, name)
            );
            """,

            "CREATE INDEX sprint_by_project ON sprint (project_id, sort_order);",

            "ALTER TABLE task ADD COLUMN sprint_id TEXT REFERENCES sprint(id) ON DELETE SET NULL;",
            "CREATE INDEX task_by_sprint ON task (sprint_id);",

            // What a sprint committed to on the day it started.
            //
            // Recorded rather than derived, because commitment is a fact about
            // a moment: a burndown drawn against today's contents would move
            // its own starting line every time work was added, which is the
            // one thing the chart exists to make visible.
            """
            CREATE TABLE sprint_commitment (
                sprint_id TEXT NOT NULL REFERENCES sprint(id) ON DELETE CASCADE,
                task_id   TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
                estimate  REAL,
                PRIMARY KEY (sprint_id, task_id)
            );
            """,

            // MARK: Workflow rules

            // Off by default, and with no rows a project allows everything —
            // so this migration cannot change how any existing board behaves.
            "ALTER TABLE project ADD COLUMN enforce_workflow INTEGER NOT NULL DEFAULT 0;",

            """
            CREATE TABLE workflow_transition (
                id             TEXT PRIMARY KEY NOT NULL,
                project_id     TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
                from_status_id TEXT NOT NULL REFERENCES status(id) ON DELETE CASCADE,
                to_status_id   TEXT NOT NULL REFERENCES status(id) ON DELETE CASCADE,
                UNIQUE (project_id, from_status_id, to_status_id)
            );
            """,

            "CREATE INDEX transition_by_project ON workflow_transition (project_id, from_status_id);",

            // MARK: Templates

            // The payload is JSON because a template is a *shape*, not a row:
            // a project template carries columns, labels and starter cards,
            // and modelling each of those as tables would be modelling the
            // whole schema twice.
            """
            CREATE TABLE template (
                id         TEXT PRIMARY KEY NOT NULL,
                project_id TEXT REFERENCES project(id) ON DELETE CASCADE,
                kind       INTEGER NOT NULL,   -- 0 card, 1 project
                name       TEXT NOT NULL,
                payload    TEXT NOT NULL,
                created_at REAL NOT NULL
            );
            """,

            "CREATE INDEX template_by_kind ON template (kind, name);",

            // MARK: Automations

            """
            CREATE TABLE automation (
                id                TEXT PRIMARY KEY NOT NULL,
                project_id        TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
                name              TEXT NOT NULL,
                trigger           INTEGER NOT NULL,
                trigger_status_id TEXT REFERENCES status(id) ON DELETE CASCADE,
                action            INTEGER NOT NULL,
                action_value      TEXT NOT NULL DEFAULT '',
                enabled           INTEGER NOT NULL DEFAULT 1,
                sort_order        REAL NOT NULL,
                created_at        REAL NOT NULL
            );
            """,

            "CREATE INDEX automation_by_project ON automation (project_id, sort_order);",

            // MARK: The running timer

            // A table rather than a column on `task`, so that "is anything
            // running" is one small read instead of a scan, and so the
            // single-timer rule is the primary key rather than a convention.
            """
            CREATE TABLE running_timer (
                id         INTEGER PRIMARY KEY CHECK (id = 1),
                task_id    TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
                person_id  TEXT REFERENCES person(id) ON DELETE SET NULL,
                started_at REAL NOT NULL
            );
            """,
        ]
    )
}
