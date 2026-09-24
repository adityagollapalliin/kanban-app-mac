import Foundation

// Schema version 4 — everything else a card accumulates.
//
// Four tables, one idea: a card is not only its fields. It collects a
// conversation, the files people needed to have it, its relationships to other
// work, and the hours that went into it. None of those fit in a column on
// `task`, and all four are things you go looking for on the card itself.
//
// The shape each one takes is decided by what it is:
//
//  * **Comments** are append-mostly and ordered by time. Editing one records
//    that it was edited rather than pretending it always said that.
//  * **Attachments** store a *relative* path inside the app's own attachments
//    folder, never an absolute one. The container's absolute path changes
//    between machines and between sandboxed and unsandboxed access; a path
//    relative to it does not, which is what lets the CLI and the app both
//    find the same file.
//  * **Links** are stored once, in the direction they were made. The inverse
//    is derived when a card is read, so "A blocks B" and "B is blocked by A"
//    cannot drift into disagreeing.
//  * **Work log** entries carry the day the work happened, which is not the
//    day it was written down — those differ constantly, and only one of them
//    is any use for a report.
extension Migration {
    static let v4CardDetail = Migration(
        version: 4,
        name: "card-detail",
        statements: [

            """
            CREATE TABLE comment (
                id         TEXT PRIMARY KEY NOT NULL,
                task_id    TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
                author_id  TEXT REFERENCES person(id) ON DELETE SET NULL,
                body_md    TEXT NOT NULL,
                created_at REAL NOT NULL,
                edited_at  REAL
            );
            """,

            "CREATE INDEX comment_by_task ON comment (task_id, created_at);",

            """
            CREATE TABLE attachment (
                id            TEXT PRIMARY KEY NOT NULL,
                task_id       TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
                filename      TEXT NOT NULL,
                relative_path TEXT NOT NULL,
                byte_size     INTEGER NOT NULL DEFAULT 0,
                added_at      REAL NOT NULL
            );
            """,

            "CREATE INDEX attachment_by_task ON attachment (task_id, added_at);",

            // `kind` is stored as INTEGER for the same reason every other
            // vocabulary is: it is a fixed set with an order, and the raw
            // values are part of the on-disk format.
            """
            CREATE TABLE task_link (
                id            TEXT PRIMARY KEY NOT NULL,
                task_id       TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
                other_task_id TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
                kind          INTEGER NOT NULL,
                created_at    REAL NOT NULL,
                UNIQUE (task_id, other_task_id, kind)
            );
            """,

            "CREATE INDEX link_by_task ON task_link (task_id);",
            "CREATE INDEX link_by_other ON task_link (other_task_id);",

            """
            CREATE TABLE work_log (
                id         TEXT PRIMARY KEY NOT NULL,
                task_id    TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
                person_id  TEXT REFERENCES person(id) ON DELETE SET NULL,
                minutes    INTEGER NOT NULL,
                note       TEXT NOT NULL DEFAULT '',
                worked_on  REAL NOT NULL,
                created_at REAL NOT NULL
            );
            """,

            "CREATE INDEX work_log_by_task ON work_log (task_id, worked_on);",
            "CREATE INDEX work_log_by_day ON work_log (worked_on);",
        ]
    )
}
