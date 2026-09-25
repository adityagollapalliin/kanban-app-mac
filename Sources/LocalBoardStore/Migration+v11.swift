import Foundation

// Schema version 11 — what a move has to satisfy, and what each kind of card
// asks for.
//
// Since v5 a workflow has been a set of allowed moves and nothing else: a
// from/to pair, present or absent. That answers "may this card go there" and
// no other question. Milestone 8.5c adds the three that matter in practice:
//
//   * a **condition** — whether the move is offered at all, which is about the
//     card rather than about the person;
//   * a **validator** — what must be true before it completes, which is where
//     "you cannot close this without saying why" lives;
//   * a **post-function** — what happens afterwards, so the board does the
//     tidying rather than the person remembering to.
//
// All three are rows in one table because they are one idea at three moments,
// and separating them into three tables would mean three joins to answer one
// question about one transition.
//
// The second half is field configuration: which fields a *kind* of card shows,
// which it insists on, and what they start as. A bug that always asks for an
// environment and a chore that never does are the same card table with
// different questions asked of it.
extension Migration {
    static let v11Workflow = Migration(
        version: 11,
        name: "workflow rules",
        statements: [

            // MARK: A transition becomes a thing with a name

            // Named, because a button saying "Start work" is worth more than
            // one saying "In Progress" — and because a transition with rules
            // on it is something you refer to.
            "ALTER TABLE workflow_transition ADD COLUMN name TEXT NOT NULL DEFAULT '';",
            "ALTER TABLE workflow_transition ADD COLUMN sort_order REAL NOT NULL DEFAULT 1000;",

            // The fields to prompt for when the move is made, one reference
            // per line — `due`, `assignee`, `cf:<id>`. Empty means no prompt,
            // which is what every transition does today.
            "ALTER TABLE workflow_transition ADD COLUMN screen_fields TEXT NOT NULL DEFAULT '';",
            "ALTER TABLE workflow_transition ADD COLUMN screen_title TEXT NOT NULL DEFAULT '';",

            // MARK: Conditions, validators and post-functions

            // `phase` says when the rule is consulted: 0 before the move is
            // offered, 1 before it completes, 2 after it has. `kind` says which
            // rule, and its meaning depends on the phase — a table per phase
            // would be three joins to answer one question about one move.
            //
            // A query here carries its own syntax, as every stored query must
            // since schema 10.
            """
            CREATE TABLE transition_rule (
                id            TEXT PRIMARY KEY NOT NULL,
                transition_id TEXT NOT NULL REFERENCES workflow_transition(id) ON DELETE CASCADE,
                phase         INTEGER NOT NULL,
                kind          INTEGER NOT NULL,
                target        TEXT NOT NULL DEFAULT '',
                value         TEXT NOT NULL DEFAULT '',
                query         TEXT NOT NULL DEFAULT '',
                syntax        TEXT NOT NULL DEFAULT 'simple',
                sort_order    REAL NOT NULL,
                created_at    REAL NOT NULL
            );
            """,

            "CREATE INDEX transition_rule_by_transition ON transition_rule (transition_id, phase, sort_order);",

            // MARK: What each kind of card asks for

            // `field_ref` is a built-in field's name or `cf:<id>` for one the
            // project invented — the same spelling the transition screens use,
            // so one reader understands both.
            //
            // A row here is a *departure* from the default. No rows means every
            // field shows and none is required, which is exactly how the app
            // behaves today.
            """
            CREATE TABLE field_config (
                id              TEXT PRIMARY KEY NOT NULL,
                project_id      TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
                issue_type_code INTEGER NOT NULL,
                field_ref       TEXT NOT NULL,
                shown           INTEGER NOT NULL DEFAULT 1,
                required        INTEGER NOT NULL DEFAULT 0,
                default_value   TEXT NOT NULL DEFAULT '',
                sort_order      REAL NOT NULL,
                UNIQUE (project_id, issue_type_code, field_ref)
            );
            """,

            "CREATE INDEX field_config_by_type ON field_config (project_id, issue_type_code, sort_order);",

            // MARK: Where a card is drawn on the workflow diagram
            //
            // Laid out by hand and remembered, because an automatic layout of
            // the same graph moves everything whenever one status is added,
            // and a diagram that rearranges itself is one nobody can learn.
            // Both zero means "never positioned", and the editor lays those
            // out in a row.
            "ALTER TABLE status ADD COLUMN diagram_x REAL NOT NULL DEFAULT 0;",
            "ALTER TABLE status ADD COLUMN diagram_y REAL NOT NULL DEFAULT 0;",
        ]
    )
}
