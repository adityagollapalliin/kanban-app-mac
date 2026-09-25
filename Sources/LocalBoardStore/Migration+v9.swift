import Foundation

// Schema version 9 — the things a project decides for itself.
//
// Four of this app's vocabularies have been fixed since v1: the kinds of card
// (epic, story, task, bug), the five priorities, the five link kinds, and the
// absence of any notion of *why* something was closed. Milestone 8.5 makes all
// four the project's own business.
//
// The shape of the change is the same for each, and it is chosen to be
// additive rather than clever:
//
//   * The card keeps its integer. `task.type` still holds 3 for a bug and
//     `task.priority` still holds 4 for the highest. Every saved filter, every
//     board rule and the whole query compiler compare against those integers
//     already; rewriting the column would mean rewriting all of them in one
//     migration, and the one that was missed would silently match the wrong
//     thing.
//
//   * A table beside it names them, keyed by `(project_id, code)` and seeded
//     with exactly today's values under exactly today's numbers. Renaming a
//     type, giving it an icon, or adding a fifth is then an ordinary row
//     operation that nothing else has to know about.
//
// What this deliberately does *not* do is change how `priority >= high`
// compiles. Ordering by a user-defined rank is a change to the query compiler,
// and the query language is frozen until its regression baseline says
// otherwise. Until then the seeded ranks equal the seeded codes, so the two
// agree and nothing moves.
extension Migration {
    static let v9Vocabulary = Migration(
        version: 9,
        name: "vocabulary",
        statements: [

            // MARK: Kinds of card

            // `level` is the hierarchy: 0 is ordinary work, 1 is an epic, and
            // anything above is what a project wants to put over the top —
            // an initiative, a theme. Subtasks are not a level here because
            // being a subtask is a fact about a card's parent, not about its
            // kind, and a card can be made a subtask without changing what it
            // is.
            """
            CREATE TABLE issue_type (
                project_id  TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
                code        INTEGER NOT NULL,
                name        TEXT NOT NULL,
                symbol      TEXT NOT NULL DEFAULT '',
                color       TEXT NOT NULL DEFAULT '',
                level       INTEGER NOT NULL DEFAULT 0,
                description_template TEXT NOT NULL DEFAULT '',
                sort_order  REAL NOT NULL,
                PRIMARY KEY (project_id, code)
            );
            """,

            // Today's four, under today's numbers, for every project that
            // exists. A file that never touches this table then behaves
            // exactly as it did.
            """
            INSERT INTO issue_type (project_id, code, name, symbol, level, sort_order)
            SELECT id, 0, 'Epic', 'bolt.fill', 1, 1000.0 FROM project
            UNION ALL SELECT id, 1, 'Story', 'bookmark.fill', 0, 2000.0 FROM project
            UNION ALL SELECT id, 2, 'Task', 'checkmark.square', 0, 3000.0 FROM project
            UNION ALL SELECT id, 3, 'Bug', 'ant.fill', 0, 4000.0 FROM project;
            """,

            // MARK: Priorities

            // `rank` is what an ordering comparison means. It is seeded equal
            // to `code` so that `priority >= high` keeps compiling to the same
            // integer comparison it always has.
            """
            CREATE TABLE priority_value (
                project_id TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
                code       INTEGER NOT NULL,
                name       TEXT NOT NULL,
                rank       INTEGER NOT NULL,
                symbol     TEXT NOT NULL DEFAULT '',
                color      TEXT NOT NULL DEFAULT '',
                sort_order REAL NOT NULL,
                PRIMARY KEY (project_id, code)
            );
            """,

            """
            INSERT INTO priority_value (project_id, code, name, rank, symbol, color, sort_order)
            SELECT id, 0, 'Lowest',  0, 'chevron.down.2', 'secondary', 1000.0 FROM project
            UNION ALL SELECT id, 1, 'Low',     1, 'chevron.down',   'secondary', 2000.0 FROM project
            UNION ALL SELECT id, 2, 'Normal',  2, 'minus',          'secondary', 3000.0 FROM project
            UNION ALL SELECT id, 3, 'High',    3, 'chevron.up',     'orange',    4000.0 FROM project
            UNION ALL SELECT id, 4, 'Highest', 4, 'chevron.up.2',   'red',       5000.0 FROM project;
            """,

            // MARK: Link types

            // Stored as the pair it is. A link has one row here and two
            // readings — `outward` from the card that made it, `inward` from
            // the card on the other end — which is why "blocks" and "is
            // blocked by" have never been two separate things worth
            // configuring separately.
            //
            // The `code` matches today's LinkKind, and the two inverse-only
            // spellings it used (1 and 4) become the inward halves of their
            // pairs rather than rows of their own.
            """
            CREATE TABLE link_type (
                project_id TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
                code       INTEGER NOT NULL,
                outward    TEXT NOT NULL,
                inward     TEXT NOT NULL,
                symbol     TEXT NOT NULL DEFAULT '',
                sort_order REAL NOT NULL,
                PRIMARY KEY (project_id, code)
            );
            """,

            """
            INSERT INTO link_type (project_id, code, outward, inward, symbol, sort_order)
            SELECT id, 0, 'Blocks', 'Is blocked by', 'hand.raised.fill', 1000.0 FROM project
            UNION ALL SELECT id, 2, 'Relates to', 'Relates to', 'link', 2000.0 FROM project
            UNION ALL SELECT id, 3, 'Duplicates', 'Is duplicated by', 'doc.on.doc', 3000.0 FROM project;
            """,

            // MARK: Resolutions

            // Why something was closed, which "Done" alone cannot say. A card
            // that was closed as a duplicate and one that was finished are
            // both out of the column and mean entirely different things.
            """
            CREATE TABLE resolution (
                id         TEXT PRIMARY KEY NOT NULL,
                project_id TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
                name       TEXT NOT NULL,
                is_default INTEGER NOT NULL DEFAULT 0,
                sort_order REAL NOT NULL,
                created_at REAL NOT NULL,
                UNIQUE (project_id, name)
            );
            """,

            """
            INSERT INTO resolution (id, project_id, name, is_default, sort_order, created_at)
            SELECT lower(hex(randomblob(16))), id, 'Done', 1, 1000.0, created_at FROM project
            UNION ALL SELECT lower(hex(randomblob(16))), id, 'Won''t Do', 0, 2000.0, created_at FROM project
            UNION ALL SELECT lower(hex(randomblob(16))), id, 'Duplicate', 0, 3000.0, created_at FROM project
            UNION ALL SELECT lower(hex(randomblob(16))), id, 'Cannot Reproduce', 0, 4000.0, created_at FROM project;
            """,

            "ALTER TABLE task ADD COLUMN resolution_id TEXT REFERENCES resolution(id) ON DELETE SET NULL;",
            "ALTER TABLE task ADD COLUMN resolved_at REAL;",

            // Cards already finished are given the default resolution and the
            // date they were finished.
            //
            // This is an *interpretation* of existing data rather than a copy
            // of it: nobody said these were resolved as "Done" — nobody was
            // ever asked. It is the only defensible reading of a finished
            // card, and it is recorded in the changelog as a reading rather
            // than a fact.
            """
            UPDATE task SET
                resolved_at = completed_at,
                resolution_id = (
                    SELECT resolution.id FROM resolution
                    WHERE resolution.project_id = task.project_id AND resolution.is_default = 1
                    LIMIT 1
                )
            WHERE completed_at IS NOT NULL;
            """,

            "CREATE INDEX task_by_resolution ON task (resolution_id);",

            // MARK: Components

            // A part of the thing being built, with somebody who looks after
            // it. The default assignee is the point: work filed against a
            // component lands on the right person without anybody choosing.
            """
            CREATE TABLE component (
                id                TEXT PRIMARY KEY NOT NULL,
                project_id        TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
                name              TEXT NOT NULL,
                description       TEXT NOT NULL DEFAULT '',
                default_assignee_id TEXT REFERENCES person(id) ON DELETE SET NULL,
                sort_order        REAL NOT NULL,
                created_at        REAL NOT NULL,
                UNIQUE (project_id, name)
            );
            """,

            "CREATE INDEX component_by_project ON component (project_id, sort_order);",

            // A card can be in several components, so this is a join rather
            // than a column.
            """
            CREATE TABLE task_component (
                task_id      TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
                component_id TEXT NOT NULL REFERENCES component(id) ON DELETE CASCADE,
                PRIMARY KEY (task_id, component_id)
            );
            """,

            "CREATE INDEX task_component_by_component ON task_component (component_id);",

            // MARK: Versions a card affects, and versions that fix it

            // `task.version_id` has meant "fix version" since v3 and goes on
            // meaning it: it is the *first* fix version, exactly as
            // `assignee_id` became the first assignee in v6. This table is
            // where the rest live, plus the versions a bug was found in.
            //
            // kind: 0 fix, 1 affects.
            """
            CREATE TABLE task_version (
                task_id    TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
                version_id TEXT NOT NULL REFERENCES version(id) ON DELETE CASCADE,
                kind       INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (task_id, version_id, kind)
            );
            """,

            "CREATE INDEX task_version_by_version ON task_version (version_id, kind);",

            """
            INSERT INTO task_version (task_id, version_id, kind)
            SELECT id, version_id, 0 FROM task WHERE version_id IS NOT NULL;
            """,

            // MARK: Environment

            // Free text on purpose. "Safari 18 on an M1, only on the staging
            // database" is not a field anybody can enumerate in advance.
            "ALTER TABLE task ADD COLUMN environment TEXT NOT NULL DEFAULT '';",
        ]
    )
}
