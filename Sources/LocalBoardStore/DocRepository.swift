import Foundation
import LocalBoardCore

/// Documents, their nested pages, and the cards they mention.
///
/// The link table is *derived from the text* on every save rather than edited
/// separately. A document that says `@TASK-14` and a backlink table that
/// disagrees is the kind of drift nobody notices until the backlink points at
/// a card that was never mentioned.
public struct DocRepository {

    let database: Database
    private let clock: any ClockProvider

    public init(database: Database, clock: any ClockProvider = SystemClock()) {
        self.database = database
        self.clock = clock
    }

    // MARK: - Reading

    public func docs(inProject projectID: String?, includeArchived: Bool = false) throws -> [Doc] {
        let archived = includeArchived ? "" : " AND archived = 0"
        if let projectID {
            return try database.query(
                "SELECT * FROM doc WHERE project_id = ?\(archived) ORDER BY sort_order;", [projectID]
            ).map(Doc.init(row:))
        }
        return try database.query(
            "SELECT * FROM doc WHERE project_id IS NULL\(archived) ORDER BY sort_order;"
        ).map(Doc.init(row:))
    }

    /// Every document, for the sidebar that shows them as a tree.
    public func allDocs(includeArchived: Bool = false) throws -> [Doc] {
        let archived = includeArchived ? "" : " WHERE archived = 0"
        return try database.query("SELECT * FROM doc\(archived) ORDER BY sort_order;")
            .map(Doc.init(row:))
    }

    public func doc(id: String) throws -> Doc {
        guard let row = try database.queryOne("SELECT * FROM doc WHERE id = ?;", [id]) else {
            throw LocalBoardError.notFound(entity: "document \(id)")
        }
        return try Doc(row: row)
    }

    public func children(of parentID: String?) throws -> [Doc] {
        if let parentID {
            return try database.query(
                "SELECT * FROM doc WHERE parent_id = ? AND archived = 0 ORDER BY sort_order;", [parentID]
            ).map(Doc.init(row:))
        }
        return try database.query(
            "SELECT * FROM doc WHERE parent_id IS NULL AND archived = 0 ORDER BY sort_order;"
        ).map(Doc.init(row:))
    }

    // MARK: - Writing

    @discardableResult
    public func create(
        title: String, inProject projectID: String? = nil, parent parentID: String? = nil,
        body: String = ""
    ) throws -> Doc {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = UUID().uuidString
        let last = try database.queryOne("SELECT MAX(sort_order) AS last FROM doc;")?.double("last")

        try database.execute(
            """
            INSERT INTO doc (id, project_id, parent_id, title, body_md, sort_order, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [
                id, projectID.sqlValue, parentID.sqlValue,
                trimmed.isEmpty ? "Untitled" : trimmed, body,
                SortOrder.between(last, nil), clock.now, clock.now,
            ]
        )
        try relinkTasks(docID: id, body: body)
        return try doc(id: id)
    }

    /// Saves a document and rewrites its links in the same breath, so the two
    /// cannot disagree.
    public func save(_ docID: String, title: String, body: String) throws {
        try database.transaction {
            let changed = try database.execute(
                "UPDATE doc SET title = ?, body_md = ?, updated_at = ? WHERE id = ?;",
                [title.isEmpty ? "Untitled" : title, body, clock.now, docID]
            )
            guard changed > 0 else { throw LocalBoardError.notFound(entity: "document \(docID)") }
            try relinkTasks(docID: docID, body: body)
        }
    }

    public func setIcon(_ icon: String, for docID: String) throws {
        try database.execute("UPDATE doc SET icon = ? WHERE id = ?;", [icon, docID])
    }

    public func setArchived(_ archived: Bool, for docID: String) throws {
        try database.execute("UPDATE doc SET archived = ? WHERE id = ?;", [archived, docID])
    }

    /// Deleting a page deletes the pages under it — they are its contents, not
    /// its neighbours, which is what makes them nested rather than merely
    /// ordered.
    public func delete(_ docID: String) throws {
        let changed = try database.execute("DELETE FROM doc WHERE id = ?;", [docID])
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "document \(docID)") }
    }

    public func move(_ docID: String, under parentID: String?) throws {
        // A page cannot be put inside itself or inside its own descendant:
        // the tree would become a ring, and every walk of it would hang.
        if let parentID {
            guard docID != parentID, try !isDescendant(parentID, of: docID) else {
                throw LocalBoardError.invalidInput(
                    field: "parent", detail: "A page cannot be moved inside itself."
                )
            }
        }
        try database.execute("UPDATE doc SET parent_id = ? WHERE id = ?;", [parentID.sqlValue, docID])
    }

    private func isDescendant(_ candidate: String, of ancestor: String) throws -> Bool {
        var current: String? = candidate
        var guardCount = 0
        while let id = current, guardCount < 100 {
            if id == ancestor { return true }
            current = try database.queryOne("SELECT parent_id FROM doc WHERE id = ?;", [id])?
                .string("parent_id")
            guardCount += 1
        }
        return false
    }

    // MARK: - Links between documents and cards

    /// The cards a document mentions, written as `@KEY-12`.
    public func linkedTasks(ofDoc docID: String) throws -> [BoardTask] {
        try database.query(
            """
            SELECT task.* FROM doc_task_link
            JOIN task ON task.id = doc_task_link.task_id
            WHERE doc_task_link.doc_id = ?
            ORDER BY task.number;
            """,
            [docID]
        ).map(BoardTask.init(row:))
    }

    /// The documents that mention a card — the backlinks shown on the card.
    public func backlinks(ofTask taskID: String) throws -> [Doc] {
        try database.query(
            """
            SELECT doc.* FROM doc_task_link
            JOIN doc ON doc.id = doc_task_link.doc_id
            WHERE doc_task_link.task_id = ? AND doc.archived = 0
            ORDER BY doc.updated_at DESC;
            """,
            [taskID]
        ).map(Doc.init(row:))
    }

    /// Rewrites a document's links from what it actually says.
    ///
    /// Wholesale rather than incremental: working out which mentions were
    /// added and removed since the last save is a diff nobody needs, and a
    /// document has at most a handful of them.
    func relinkTasks(docID: String, body: String) throws {
        try database.execute("DELETE FROM doc_task_link WHERE doc_id = ?;", [docID])

        for key in Self.mentionedKeys(in: body) {
            guard let task = try task(forKey: key) else { continue }
            try database.execute(
                "INSERT OR IGNORE INTO doc_task_link (doc_id, task_id) VALUES (?, ?);",
                [docID, task]
            )
        }
    }

    /// `@WORK-14` mentions card 14 of project WORK.
    ///
    /// Deliberately strict: a mention is the project's own key, a hyphen and
    /// digits. Loosening it to catch `@work 14` would also catch every email
    /// address and every `@mention` of a person.
    static func mentionedKeys(in body: String) -> [String] {
        var found: [String] = []
        var current = ""
        var collecting = false

        for character in body {
            if character == "@" {
                collecting = true
                current = ""
                continue
            }
            guard collecting else { continue }

            if character.isLetter || character.isNumber || character == "-" {
                current.append(character)
            } else {
                if current.contains("-") { found.append(current) }
                collecting = false
                current = ""
            }
        }
        if collecting, current.contains("-") { found.append(current) }
        return found
    }

    private func task(forKey key: String) throws -> String? {
        let parts = key.split(separator: "-")
        guard parts.count == 2, let number = Int(parts[1]) else { return nil }

        return try database.queryOne(
            """
            SELECT task.id AS id FROM task
            JOIN project ON project.id = task.project_id
            WHERE project.key = ? COLLATE NOCASE AND task.number = ?;
            """,
            [String(parts[0]), number]
        )?.string("id")
    }
}
