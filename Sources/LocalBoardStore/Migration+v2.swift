import Foundation

// Schema version 2 — saved views.
//
// A query language you cannot keep an answer from is a toy. This stores the
// query text rather than a compiled result, so a view means the same thing it
// meant when it was written: `due < +7d` saved in March still says "within a
// week" in December.
extension Migration {
    static let v2SavedViews = Migration(
        version: 2,
        name: "saved-views",
        statements: [
            """
            CREATE TABLE saved_view (
                id         TEXT PRIMARY KEY NOT NULL,
                project_id TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
                name       TEXT NOT NULL,
                query      TEXT NOT NULL,
                sort_order REAL NOT NULL,
                created_at REAL NOT NULL,
                UNIQUE (project_id, name)
            );
            """,

            "CREATE INDEX view_by_project ON saved_view (project_id, sort_order);",
        ]
    )
}
