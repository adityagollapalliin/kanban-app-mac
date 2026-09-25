import Foundation

// Schema version 7 — the day in front of you, and the things written beside
// the work.
//
// Two groups, and they are different in kind.
//
// The first is about *now*: what is due today, what slipped, what you have
// decided to do today, and what should stop asking until Thursday. Those are
// columns on `task`, because they are facts about a card rather than new
// things — and a card that has never been snoozed or planned reads exactly as
// it did before.
//
// The second is the material around the work: standalone reminders, a
// notepad, documents, whiteboards. Those are new tables, all empty after the
// migration. Nothing here changes what an existing file does.
extension Migration {
    static let v7Personal = Migration(
        version: 7,
        name: "personal",
        statements: [

            // MARK: The day in front of you

            // Snoozing is not the same as changing a due date. The date is a
            // promise to other people; a snooze is "stop asking me until
            // Thursday", and conflating them quietly rewrites the plan every
            // time somebody wants five minutes' peace.
            "ALTER TABLE task ADD COLUMN snoozed_until REAL;",

            // What you have decided to do today. Also not a due date: a card
            // due next week that you have chosen to start today belongs in
            // today's list without its deadline moving.
            "ALTER TABLE task ADD COLUMN planned_for REAL;",

            "CREATE INDEX task_planned ON task (planned_for, trashed);",

            // MARK: Reminders that are not tasks

            // Deliberately not a card. A reminder has no column, no assignee,
            // no estimate and no place on a board — making it a task would put
            // "ring the dentist" in the project's cycle-time statistics.
            """
            CREATE TABLE reminder (
                id             TEXT PRIMARY KEY NOT NULL,
                title          TEXT NOT NULL,
                notes          TEXT NOT NULL DEFAULT '',
                due_at         REAL,
                snoozed_until  REAL,
                completed_at   REAL,
                sort_order     REAL NOT NULL,
                created_at     REAL NOT NULL
            );
            """,

            "CREATE INDEX reminder_by_due ON reminder (completed_at, due_at);",

            // MARK: The notepad

            // One pad, not many. A scratch pad you have to name and file is a
            // document; the point of this one is that it is always the same
            // one and needs no decision to start writing in.
            """
            CREATE TABLE notepad (
                id         INTEGER PRIMARY KEY CHECK (id = 1),
                body_md    TEXT NOT NULL DEFAULT '',
                updated_at REAL NOT NULL
            );
            """,

            // MARK: Documents

            // `parent_id` makes pages nest; `project_id` is nullable because a
            // document can belong to a space or to nobody in particular, and
            // forcing every note into a project is how people stop writing
            // them.
            """
            CREATE TABLE doc (
                id         TEXT PRIMARY KEY NOT NULL,
                project_id TEXT REFERENCES project(id) ON DELETE SET NULL,
                parent_id  TEXT REFERENCES doc(id) ON DELETE CASCADE,
                title      TEXT NOT NULL,
                icon       TEXT NOT NULL DEFAULT '',
                body_md    TEXT NOT NULL DEFAULT '',
                archived   INTEGER NOT NULL DEFAULT 0,
                sort_order REAL NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            """,

            "CREATE INDEX doc_by_parent ON doc (parent_id, sort_order);",
            "CREATE INDEX doc_by_project ON doc (project_id, sort_order);",

            // Which documents mention which cards. Rewritten from the text
            // whenever a document is saved rather than edited by hand, so the
            // backlinks on a card cannot drift from what the document
            // actually says.
            """
            CREATE TABLE doc_task_link (
                doc_id  TEXT NOT NULL REFERENCES doc(id) ON DELETE CASCADE,
                task_id TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
                PRIMARY KEY (doc_id, task_id)
            );
            """,

            "CREATE INDEX doc_link_by_task ON doc_task_link (task_id);",

            // MARK: Whiteboards

            """
            CREATE TABLE whiteboard (
                id         TEXT PRIMARY KEY NOT NULL,
                project_id TEXT REFERENCES project(id) ON DELETE SET NULL,
                name       TEXT NOT NULL,
                sort_order REAL NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            """,

            // One table for stickies, shapes, text, ink and connectors. They
            // differ in what they draw, not in what they are: a thing on a
            // canvas at a position. Five tables would be five places for the
            // selection, the z-order and the delete to drift apart.
            //
            // `points` carries a freehand stroke as text, and `from_item` and
            // `to_item` carry a connector's ends. Each is null for the kinds
            // that have no use for it.
            """
            CREATE TABLE whiteboard_item (
                id           TEXT PRIMARY KEY NOT NULL,
                board_id     TEXT NOT NULL REFERENCES whiteboard(id) ON DELETE CASCADE,
                kind         INTEGER NOT NULL,   -- 0 sticky, 1 shape, 2 text, 3 ink, 4 connector
                x            REAL NOT NULL DEFAULT 0,
                y            REAL NOT NULL DEFAULT 0,
                width        REAL NOT NULL DEFAULT 140,
                height       REAL NOT NULL DEFAULT 100,
                text         TEXT NOT NULL DEFAULT '',
                color        TEXT NOT NULL DEFAULT 'yellow',
                shape        INTEGER NOT NULL DEFAULT 0,  -- 0 rectangle, 1 ellipse, 2 diamond
                points       TEXT NOT NULL DEFAULT '',
                from_item    TEXT REFERENCES whiteboard_item(id) ON DELETE CASCADE,
                to_item      TEXT REFERENCES whiteboard_item(id) ON DELETE CASCADE,
                -- Set when a sticky has been turned into a card, so the canvas
                -- can show that it became one rather than offering again.
                task_id      TEXT REFERENCES task(id) ON DELETE SET NULL,
                sort_order   REAL NOT NULL,
                created_at   REAL NOT NULL
            );
            """,

            "CREATE INDEX whiteboard_item_by_board ON whiteboard_item (board_id, sort_order);",

            // MARK: Comments that are asking for something

            // A remark and a request look the same in a comment thread until
            // somebody has to act on one. These columns are what tell them
            // apart — and they are on `comment` rather than in a new table
            // because an action item *is* the comment, not a thing attached
            // to it.
            "ALTER TABLE comment ADD COLUMN action_item INTEGER NOT NULL DEFAULT 0;",
            "ALTER TABLE comment ADD COLUMN action_assignee_id TEXT REFERENCES person(id) ON DELETE SET NULL;",
            "ALTER TABLE comment ADD COLUMN action_done INTEGER NOT NULL DEFAULT 0;",
            "ALTER TABLE comment ADD COLUMN action_done_at REAL;",
        ]
    )
}
