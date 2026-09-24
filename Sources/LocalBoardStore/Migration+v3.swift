import Foundation

// Schema version 3 — the Jira-grade board.
//
// Four ideas arrive together because they are one idea: a board is a *view* of
// the work, and until now it was the work itself.
//
//  * A column is no longer one status. `column_status` lets "In Review" and
//    "In Progress" sit under a single "Doing" heading on one board and stand
//    apart on another, without either board owning the statuses.
//  * A card's history is recorded rather than inferred. `status_change` is
//    what makes days-in-column, the cumulative flow diagram and the control
//    chart possible; none of them can be reconstructed from the current row,
//    which is why the column stamps have to start now rather than later.
//  * A board carries its own presentation — swimlanes, card fields, colour
//    rule, staleness threshold. These are columns on `board` rather than a
//    preferences file, so two boards over one project genuinely differ and a
//    board keeps its shape when the app is reinstalled.
//  * Flags, versions and quick filters are the remaining nouns the board needs
//    to talk about work it cannot currently name.
//
// Backfill is the careful part. Every existing row is given a defensible past:
// each column gets the mapping row it always implicitly had, and each task an
// opening `status_change` at its creation time. The charts then start at the
// beginning of the data rather than at the moment of upgrade.
extension Migration {
    static let v3JiraBoard = Migration(
        version: 3,
        name: "jira-board",
        statements: [

            // MARK: Columns map to many statuses

            """
            CREATE TABLE column_status (
                column_id  TEXT NOT NULL REFERENCES board_column(id) ON DELETE CASCADE,
                status_id  TEXT NOT NULL REFERENCES status(id) ON DELETE CASCADE,
                sort_order REAL NOT NULL,
                PRIMARY KEY (column_id, status_id)
            );
            """,

            // Every column already showed exactly one status. Say so out loud,
            // so the mapping table is the single truth from here on and
            // `board_column.status_id` degrades to "where a drop lands".
            """
            INSERT INTO column_status (column_id, status_id, sort_order)
            SELECT id, status_id, 1000.0 FROM board_column;
            """,

            "CREATE INDEX column_status_by_status ON column_status (status_id);",

            // MARK: Limits that count something other than cards

            "ALTER TABLE board_column ADD COLUMN wip_minimum INTEGER;",
            "ALTER TABLE board_column ADD COLUMN wip_measure INTEGER NOT NULL DEFAULT 0;",

            // The commitment point of a Kanban backlog: cards in a backlog
            // column are off the board proper and do not count against WIP.
            "ALTER TABLE board_column ADD COLUMN is_backlog INTEGER NOT NULL DEFAULT 0;",

            // MARK: Releases

            """
            CREATE TABLE version (
                id             TEXT PRIMARY KEY NOT NULL,
                project_id     TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
                name           TEXT NOT NULL,
                description_md TEXT NOT NULL DEFAULT '',
                release_date   REAL,
                released       INTEGER NOT NULL DEFAULT 0,
                sort_order     REAL NOT NULL,
                created_at     REAL NOT NULL,
                UNIQUE (project_id, name)
            );
            """,

            "CREATE INDEX version_by_project ON version (project_id, sort_order);",

            // MARK: What a card gained

            "ALTER TABLE task ADD COLUMN flagged INTEGER NOT NULL DEFAULT 0;",
            "ALTER TABLE task ADD COLUMN flag_reason TEXT NOT NULL DEFAULT '';",
            "ALTER TABLE task ADD COLUMN status_changed_at REAL;",
            "ALTER TABLE task ADD COLUMN version_id TEXT REFERENCES version(id) ON DELETE SET NULL;",

            // A card that has never moved has been in its column since it was
            // made. That is true, and it means the dots are right on day one
            // rather than only for cards touched after the upgrade.
            "UPDATE task SET status_changed_at = created_at WHERE status_changed_at IS NULL;",

            "CREATE INDEX task_by_flag ON task (flagged) WHERE flagged = 1;",
            "CREATE INDEX task_by_version ON task (version_id);",

            // MARK: History

            // Append-only. Nothing updates or deletes a row here except the
            // cascade when its task is truly gone, because the whole point is
            // that it records what happened rather than what is the case.
            """
            CREATE TABLE status_change (
                id             TEXT PRIMARY KEY NOT NULL,
                task_id        TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
                from_status_id TEXT,
                to_status_id   TEXT NOT NULL,
                at             REAL NOT NULL
            );
            """,

            "CREATE INDEX status_change_by_task ON status_change (task_id, at);",
            "CREATE INDEX status_change_by_time ON status_change (at);",

            // The opening entry for work that predates the table: created into
            // the status it currently holds. A cumulative flow diagram drawn
            // tomorrow then covers the whole history rather than one day of it.
            """
            INSERT INTO status_change (id, task_id, from_status_id, to_status_id, at)
            SELECT lower(hex(randomblob(16))), id, NULL, status_id, created_at FROM task;
            """,

            // MARK: How a board presents itself

            "ALTER TABLE board ADD COLUMN swimlane_mode INTEGER NOT NULL DEFAULT 0;",
            "ALTER TABLE board ADD COLUMN card_fields TEXT NOT NULL DEFAULT 'due,labels';",
            "ALTER TABLE board ADD COLUMN color_rule INTEGER NOT NULL DEFAULT 0;",
            "ALTER TABLE board ADD COLUMN color_view_id TEXT REFERENCES saved_view(id) ON DELETE SET NULL;",
            "ALTER TABLE board ADD COLUMN stale_days INTEGER NOT NULL DEFAULT 3;",
            "ALTER TABLE board ADD COLUMN backlog_enabled INTEGER NOT NULL DEFAULT 0;",

            // A board defined by a question rather than by a project. Empty
            // means the ordinary kind; anything else and the board gathers
            // whatever matches, across every project in the workspace.
            "ALTER TABLE board ADD COLUMN filter_query TEXT NOT NULL DEFAULT '';",

            // MARK: Lanes and quick filters

            """
            CREATE TABLE swimlane (
                id         TEXT PRIMARY KEY NOT NULL,
                board_id   TEXT NOT NULL REFERENCES board(id) ON DELETE CASCADE,
                name       TEXT NOT NULL,
                query      TEXT NOT NULL,
                pinned     INTEGER NOT NULL DEFAULT 0,
                sort_order REAL NOT NULL
            );
            """,

            "CREATE INDEX swimlane_by_board ON swimlane (board_id, sort_order);",

            """
            CREATE TABLE quick_filter (
                id         TEXT PRIMARY KEY NOT NULL,
                board_id   TEXT NOT NULL REFERENCES board(id) ON DELETE CASCADE,
                name       TEXT NOT NULL,
                query      TEXT NOT NULL,
                sort_order REAL NOT NULL,
                UNIQUE (board_id, name)
            );
            """,

            "CREATE INDEX quick_filter_by_board ON quick_filter (board_id, sort_order);",

            // The lane every Kanban board has whether or not it has drawn it:
            // the things that jump the queue. Pinned, so it stays at the top
            // under whichever grouping the board is using.
            """
            INSERT INTO swimlane (id, board_id, name, query, pinned, sort_order)
            SELECT lower(hex(randomblob(16))), id, 'Expedite', 'priority >= highest', 1, 100.0
            FROM board;
            """,

            // Four filters worth having on day one. They are rows, not
            // hardcoded buttons, so the first thing anyone learns about them
            // is that they can be edited.
            """
            INSERT INTO quick_filter (id, board_id, name, query, sort_order)
            SELECT lower(hex(randomblob(16))), id, 'My Tasks', 'is:mine', 1000.0 FROM board;
            """,
            """
            INSERT INTO quick_filter (id, board_id, name, query, sort_order)
            SELECT lower(hex(randomblob(16))), id, 'Recently Updated', 'updated >= -3d', 2000.0 FROM board;
            """,
            """
            INSERT INTO quick_filter (id, board_id, name, query, sort_order)
            SELECT lower(hex(randomblob(16))), id, 'Flagged', 'is:flagged', 3000.0 FROM board;
            """,
            """
            INSERT INTO quick_filter (id, board_id, name, query, sort_order)
            SELECT lower(hex(randomblob(16))), id, 'Due This Week', 'due <= +7d is:open', 4000.0 FROM board;
            """,

            // MARK: An optional link to a local checkout

            // Off by default and never created here — a row exists only once
            // someone has picked a folder. The security-scoped bookmark is the
            // sandbox's record of that permission; the path is for showing.
            """
            CREATE TABLE project_repository (
                project_id TEXT PRIMARY KEY NOT NULL REFERENCES project(id) ON DELETE CASCADE,
                path       TEXT NOT NULL,
                bookmark   BLOB,
                linked_at  REAL NOT NULL
            );
            """,
        ]
    )
}
