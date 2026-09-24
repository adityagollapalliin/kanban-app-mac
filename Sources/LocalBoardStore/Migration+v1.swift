import Foundation

// Schema version 1 — the Kanban foundation.
//
// Conventions used throughout:
//  * Primary keys are UUID strings, so records keep their identity across
//    export/import and across the app/CLI boundary.
//  * Dates are REAL Unix epoch seconds, so SQL can compare them directly.
//    That is what lets the query language push `due < +7d` down into SQLite.
//  * `sort_order` is a sparse REAL. A drag-and-drop writes the midpoint between
//    its new neighbours, so reordering touches one row instead of renumbering
//    the whole column. A rebalance pass runs only when the gap gets too small.
//  * Enumerations (priority, status category, issue type) are INTEGER so that
//    `priority >= High` is an ordinary indexed comparison.
extension Migration {
    static let v1Foundation = Migration(
        version: 1,
        name: "foundation",
        statements: [
            """
            CREATE TABLE app_meta (
                key   TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            );
            """,

            """
            CREATE TABLE workspace (
                id         TEXT PRIMARY KEY NOT NULL,
                name       TEXT NOT NULL,
                sort_order REAL NOT NULL,
                created_at REAL NOT NULL
            );
            """,

            """
            CREATE TABLE person (
                id         TEXT PRIMARY KEY NOT NULL,
                name       TEXT NOT NULL,
                color      TEXT NOT NULL DEFAULT 'graphite',
                sort_order REAL NOT NULL,
                created_at REAL NOT NULL
            );
            """,

            """
            CREATE TABLE project (
                id               TEXT PRIMARY KEY NOT NULL,
                workspace_id     TEXT NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
                name             TEXT NOT NULL,
                key              TEXT NOT NULL,
                description_md   TEXT NOT NULL DEFAULT '',
                next_task_number INTEGER NOT NULL DEFAULT 1,
                archived         INTEGER NOT NULL DEFAULT 0,
                sort_order       REAL NOT NULL,
                created_at       REAL NOT NULL,
                UNIQUE (workspace_id, key)
            );
            """,

            """
            CREATE TABLE status (
                id         TEXT PRIMARY KEY NOT NULL,
                project_id TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
                name       TEXT NOT NULL,
                category   INTEGER NOT NULL DEFAULT 0,  -- 0 to do, 1 in progress, 2 done
                sort_order REAL NOT NULL,
                UNIQUE (project_id, name)
            );
            """,

            """
            CREATE TABLE board (
                id         TEXT PRIMARY KEY NOT NULL,
                project_id TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
                name       TEXT NOT NULL,
                sort_order REAL NOT NULL,
                created_at REAL NOT NULL
            );
            """,

            """
            CREATE TABLE board_column (
                id         TEXT PRIMARY KEY NOT NULL,
                board_id   TEXT NOT NULL REFERENCES board(id) ON DELETE CASCADE,
                status_id  TEXT NOT NULL REFERENCES status(id) ON DELETE CASCADE,
                name       TEXT NOT NULL,
                wip_limit  INTEGER,                      -- NULL means no limit
                sort_order REAL NOT NULL,
                UNIQUE (board_id, status_id)
            );
            """,

            """
            CREATE TABLE label (
                id         TEXT PRIMARY KEY NOT NULL,
                project_id TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
                name       TEXT NOT NULL,
                color      TEXT NOT NULL DEFAULT 'slate',
                UNIQUE (project_id, name)
            );
            """,

            """
            CREATE TABLE task (
                id             TEXT PRIMARY KEY NOT NULL,
                project_id     TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
                status_id      TEXT NOT NULL REFERENCES status(id),
                number         INTEGER NOT NULL,
                type           INTEGER NOT NULL DEFAULT 2,  -- 0 epic, 1 story, 2 task, 3 bug
                title          TEXT NOT NULL,
                description_md TEXT NOT NULL DEFAULT '',
                assignee_id    TEXT REFERENCES person(id) ON DELETE SET NULL,
                priority       INTEGER NOT NULL DEFAULT 2,  -- 0 lowest .. 4 highest
                parent_id      TEXT REFERENCES task(id) ON DELETE CASCADE,
                epic_id        TEXT REFERENCES task(id) ON DELETE SET NULL,
                start_date     REAL,
                due_date       REAL,
                estimate       REAL,
                sort_order     REAL NOT NULL,
                trashed        INTEGER NOT NULL DEFAULT 0,
                created_at     REAL NOT NULL,
                updated_at     REAL NOT NULL,
                completed_at   REAL,
                UNIQUE (project_id, number)
            );
            """,

            """
            CREATE TABLE task_label (
                task_id  TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
                label_id TEXT NOT NULL REFERENCES label(id) ON DELETE CASCADE,
                PRIMARY KEY (task_id, label_id)
            );
            """,

            """
            CREATE TABLE checklist_item (
                id         TEXT PRIMARY KEY NOT NULL,
                task_id    TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
                text       TEXT NOT NULL,
                done       INTEGER NOT NULL DEFAULT 0,
                sort_order REAL NOT NULL
            );
            """,

            // Indexes chosen for the queries the board actually runs: one column
            // of one board, the backlog, and anything date-filtered.
            "CREATE INDEX task_by_column ON task (project_id, status_id, trashed, sort_order);",
            "CREATE INDEX task_by_parent ON task (parent_id);",
            "CREATE INDEX task_by_epic ON task (epic_id);",
            "CREATE INDEX task_by_due ON task (due_date);",
            "CREATE INDEX task_by_assignee ON task (assignee_id);",
            "CREATE INDEX task_by_updated ON task (updated_at);",
            "CREATE INDEX status_by_project ON status (project_id, sort_order);",
            "CREATE INDEX board_by_project ON board (project_id, sort_order);",
            "CREATE INDEX column_by_board ON board_column (board_id, sort_order);",
            "CREATE INDEX label_by_project ON label (project_id, name);",
            "CREATE INDEX checklist_by_task ON checklist_item (task_id, sort_order);",
            "CREATE INDEX project_by_workspace ON project (workspace_id, sort_order);",

            // Full-text search over titles and descriptions. External-content
            // table, so the text is stored once and kept in sync by triggers.
            """
            CREATE VIRTUAL TABLE task_fts USING fts5 (
                title,
                description_md,
                content = 'task',
                content_rowid = 'rowid',
                tokenize = 'unicode61 remove_diacritics 2'
            );
            """,

            """
            CREATE TRIGGER task_fts_after_insert AFTER INSERT ON task BEGIN
                INSERT INTO task_fts (rowid, title, description_md)
                VALUES (new.rowid, new.title, new.description_md);
            END;
            """,

            """
            CREATE TRIGGER task_fts_after_delete AFTER DELETE ON task BEGIN
                INSERT INTO task_fts (task_fts, rowid, title, description_md)
                VALUES ('delete', old.rowid, old.title, old.description_md);
            END;
            """,

            """
            CREATE TRIGGER task_fts_after_update AFTER UPDATE OF title, description_md ON task BEGIN
                INSERT INTO task_fts (task_fts, rowid, title, description_md)
                VALUES ('delete', old.rowid, old.title, old.description_md);
                INSERT INTO task_fts (rowid, title, description_md)
                VALUES (new.rowid, new.title, new.description_md);
            END;
            """,
        ]
    )
}
