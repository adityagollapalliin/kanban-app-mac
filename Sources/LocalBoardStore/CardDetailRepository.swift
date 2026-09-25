import Foundation
import LocalBoardCore

/// Comments, attachments, links and the work log.
///
/// One type for four tables because they are one question — "what else does
/// this card carry" — and the inspector asks all four together. Keeping them
/// apart would mean four handles for one screen.
public struct CardDetailRepository {

    let database: Database
    let clock: any ClockProvider
    private let paths: ContainerPaths?

    /// `paths` is only needed for attachments, which have to live somewhere on
    /// disk. Everything else here works without it, which is why it is
    /// optional rather than required by the initialiser.
    public init(
        database: Database,
        clock: any ClockProvider = SystemClock(),
        paths: ContainerPaths? = nil
    ) {
        self.database = database
        self.clock = clock
        self.paths = paths
    }

    // MARK: - Comments

    public func comments(forTask taskID: String) throws -> [Comment] {
        try database.query(
            "SELECT * FROM comment WHERE task_id = ? ORDER BY created_at;", [taskID]
        ).map(Comment.init(row:))
    }

    @discardableResult
    public func addComment(
        toTask taskID: String,
        body: String,
        authorID: String? = nil
    ) throws -> Comment {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalBoardError.invalidInput(field: "comment", detail: "A comment needs something in it.")
        }

        let id = UUID().uuidString
        try database.execute(
            """
            INSERT INTO comment (id, task_id, author_id, body_md, created_at)
            VALUES (?, ?, ?, ?, ?);
            """,
            [id, taskID, authorID.sqlValue, trimmed, clock.now]
        )
        guard let row = try database.queryOne("SELECT * FROM comment WHERE id = ?;", [id]) else {
            throw LocalBoardError.databaseQueryFailed(detail: "The comment was not written.")
        }
        return try Comment(row: row)
    }

    /// Changing a comment stamps `edited_at`, so the card is honest about the
    /// fact that this is not what was originally said.
    public func editComment(_ commentID: String, body: String) throws {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalBoardError.invalidInput(field: "comment", detail: "A comment needs something in it.")
        }
        let changed = try database.execute(
            "UPDATE comment SET body_md = ?, edited_at = ? WHERE id = ?;",
            [trimmed, clock.now, commentID]
        )
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "comment \(commentID)") }
    }

    public func deleteComment(_ commentID: String) throws {
        let changed = try database.execute("DELETE FROM comment WHERE id = ?;", [commentID])
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "comment \(commentID)") }
    }

    // MARK: - Attachments

    public func attachments(forTask taskID: String) throws -> [Attachment] {
        try database.query(
            "SELECT * FROM attachment WHERE task_id = ? ORDER BY added_at;", [taskID]
        ).map(Attachment.init(row:))
    }

    /// Copies a file into the app's attachments folder and records it.
    ///
    /// A copy, not a reference. A card pointing at a file somewhere on the
    /// user's disk is a card that breaks the first time that file is moved,
    /// and the sandbox would not let the app open it again anyway.
    @discardableResult
    public func attach(_ source: URL, toTask taskID: String) throws -> Attachment {
        guard let paths else {
            throw LocalBoardError.containerUnavailable(
                reason: "The attachments folder is not available."
            )
        }

        let manager = FileManager.default
        let directory = paths.attachmentsDirectory.appending(path: taskID, directoryHint: .isDirectory)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)

        // The stored name is prefixed with a fresh id so two files called
        // `screenshot.png` can both be attached to one card. The name shown to
        // the user is still the one they chose.
        let id = UUID().uuidString
        let filename = source.lastPathComponent
        let storedName = "\(id)-\(filename)"
        let destination = directory.appending(path: storedName)

        do {
            try manager.copyItem(at: source, to: destination)
        } catch {
            throw LocalBoardError.invalidInput(
                field: "attachment",
                detail: "\(filename) could not be copied: \(error.localizedDescription)"
            )
        }

        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let relative = "\(taskID)/\(storedName)"

        do {
            try database.execute(
                """
                INSERT INTO attachment (id, task_id, filename, relative_path, byte_size, added_at)
                VALUES (?, ?, ?, ?, ?, ?);
                """,
                [id, taskID, filename, relative, size, clock.now]
            )
        } catch {
            // The row is the record; a file on disk with nothing pointing at
            // it is litter. Undo the copy rather than leave it behind.
            try? manager.removeItem(at: destination)
            throw error
        }

        guard let row = try database.queryOne("SELECT * FROM attachment WHERE id = ?;", [id]) else {
            throw LocalBoardError.databaseQueryFailed(detail: "The attachment was not recorded.")
        }
        return try Attachment(row: row)
    }

    /// Where an attachment actually is, resolved against this process's view
    /// of the container.
    public func url(of attachment: Attachment) -> URL? {
        paths?.attachmentsDirectory.appending(path: attachment.relativePath)
    }

    /// Removes the record and the file together.
    ///
    /// The row goes first. If the file has already been deleted by hand, the
    /// card should still stop claiming to have it.
    public func removeAttachment(_ attachmentID: String) throws {
        let existing = try database.queryOne(
            "SELECT * FROM attachment WHERE id = ?;", [attachmentID]
        ).map(Attachment.init(row:))

        let changed = try database.execute("DELETE FROM attachment WHERE id = ?;", [attachmentID])
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "attachment \(attachmentID)") }

        if let existing, let url = url(of: existing) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Links

    /// Every link touching this card, in the direction this card sees them.
    ///
    /// A link is stored once, as it was made. Reading it from the other end
    /// flips it to its inverse — which is why "A blocks B" and "B is blocked
    /// by A" can never drift into disagreeing: there is only one row.
    public func links(forTask taskID: String) throws -> [(link: TaskLink, kind: LinkKind, otherID: String)] {
        var found: [(TaskLink, LinkKind, String)] = []

        for row in try database.query("SELECT * FROM task_link WHERE task_id = ?;", [taskID]) {
            let link = try TaskLink(row: row)
            found.append((link, link.kind, link.otherTaskID))
        }
        for row in try database.query("SELECT * FROM task_link WHERE other_task_id = ?;", [taskID]) {
            let link = try TaskLink(row: row)
            found.append((link, link.kind.inverse, link.taskID))
        }

        return found.sorted { $0.1.rawValue < $1.1.rawValue }
    }

    /// Every link in a project, keyed by the card each one is read from.
    ///
    /// One query rather than one per card. The timeline draws an arrow for
    /// every dependency on screen, and asking the store per card per redraw is
    /// how a chart of two hundred cards becomes a chart that stutters.
    public func linksByTask(inProject projectID: String) throws
        -> [String: [(link: TaskLink, kind: LinkKind, otherID: String)]] {
        var found: [String: [(TaskLink, LinkKind, String)]] = [:]

        try database.forEachRow(
            """
            SELECT task_link.* FROM task_link
            JOIN task ON task.id = task_link.task_id
            WHERE task.project_id = ?;
            """,
            [projectID]
        ) { row in
            let link = try TaskLink(row: row)
            // Both ends, each seeing the link the way round it applies to them.
            found[link.taskID, default: []].append((link, link.kind, link.otherTaskID))
            found[link.otherTaskID, default: []].append((link, link.kind.inverse, link.taskID))
        }

        return found
    }

    @discardableResult
    public func link(_ taskID: String, _ kind: LinkKind, to otherID: String) throws -> TaskLink {
        guard taskID != otherID else {
            throw LocalBoardError.invalidInput(
                field: "link", detail: "A card cannot be linked to itself."
            )
        }

        let id = UUID().uuidString
        try database.execute(
            """
            INSERT INTO task_link (id, task_id, other_task_id, kind, created_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (task_id, other_task_id, kind) DO NOTHING;
            """,
            [id, taskID, otherID, kind.rawValue, clock.now]
        )

        guard let row = try database.queryOne(
            "SELECT * FROM task_link WHERE task_id = ? AND other_task_id = ? AND kind = ?;",
            [taskID, otherID, kind.rawValue]
        ) else {
            throw LocalBoardError.databaseQueryFailed(detail: "The link was not written.")
        }
        return try TaskLink(row: row)
    }

    public func unlink(_ linkID: String) throws {
        let changed = try database.execute("DELETE FROM task_link WHERE id = ?;", [linkID])
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "link \(linkID)") }
    }

    // MARK: - Work log

    public func workLog(forTask taskID: String) throws -> [WorkLogEntry] {
        try database.query(
            "SELECT * FROM work_log WHERE task_id = ? ORDER BY worked_on DESC, created_at DESC;",
            [taskID]
        ).map(WorkLogEntry.init(row:))
    }

    @discardableResult
    public func logWork(
        onTask taskID: String,
        minutes: Int,
        note: String = "",
        personID: String? = nil,
        workedOn: Date? = nil,
        billable: Bool = false
    ) throws -> WorkLogEntry {
        guard minutes > 0 else {
            throw LocalBoardError.invalidInput(
                field: "minutes", detail: "Logged work has to be more than no time at all."
            )
        }

        let id = UUID().uuidString
        let now = clock.now
        try database.execute(
            """
            INSERT INTO work_log (id, task_id, person_id, minutes, note, worked_on, billable, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [id, taskID, personID.sqlValue, minutes, note, workedOn ?? now, billable ? 1 : 0, now]
        )

        guard let row = try database.queryOne("SELECT * FROM work_log WHERE id = ?;", [id]) else {
            throw LocalBoardError.databaseQueryFailed(detail: "The work log entry was not written.")
        }
        return try WorkLogEntry(row: row)
    }

    public func deleteWorkLog(_ entryID: String) throws {
        let changed = try database.execute("DELETE FROM work_log WHERE id = ?;", [entryID])
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "work log entry \(entryID)") }
    }

    /// Total minutes logged against a card.
    public func totalMinutes(forTask taskID: String) throws -> Int {
        try database.count("SELECT COALESCE(SUM(minutes), 0) FROM work_log WHERE task_id = ?;", [taskID])
    }

    /// How many comments and attachments each card in a project carries, for
    /// the board's badges — one query each rather than one per card.
    public func countsByTask(inProject projectID: String) throws -> (comments: [String: Int], attachments: [String: Int]) {
        var comments: [String: Int] = [:]
        var attachments: [String: Int] = [:]

        try database.forEachRow(
            """
            SELECT comment.task_id AS task_id, COUNT(*) AS total FROM comment
            JOIN task ON task.id = comment.task_id
            WHERE task.project_id = ? GROUP BY comment.task_id;
            """,
            [projectID]
        ) { row in
            comments[try row.requiredString("task_id")] = try row.requiredInt("total")
        }

        try database.forEachRow(
            """
            SELECT attachment.task_id AS task_id, COUNT(*) AS total FROM attachment
            JOIN task ON task.id = attachment.task_id
            WHERE task.project_id = ? GROUP BY attachment.task_id;
            """,
            [projectID]
        ) { row in
            attachments[try row.requiredString("task_id")] = try row.requiredInt("total")
        }

        return (comments, attachments)
    }
}

// MARK: - The running timer

extension CardDetailRepository {

    /// The timer that is running, if one is.
    public func runningTimer() throws -> RunningTimer? {
        try database.queryOne("SELECT * FROM running_timer WHERE id = 1;").map(RunningTimer.init(row:))
    }

    /// Starts timing a card.
    ///
    /// One timer runs at a time. Starting a second stops the first and logs
    /// what it measured, because the alternative — two timers running on two
    /// cards — records time that was never spent twice over.
    public func startTimer(onTask taskID: String, personID: String? = nil) throws {
        try database.transaction {
            if let running = try runningTimer() {
                guard running.taskID != taskID else { return }
                try stopTimer(discarding: false)
            }
            try database.execute(
                """
                INSERT INTO running_timer (id, task_id, person_id, started_at) VALUES (1, ?, ?, ?)
                ON CONFLICT (id) DO UPDATE SET task_id = ?, person_id = ?, started_at = ?;
                """,
                [taskID, personID.sqlValue, clock.now, taskID, personID.sqlValue, clock.now]
            )
        }
    }

    /// Stops the timer and writes what it measured into the work log.
    ///
    /// A timer stopped inside a minute logs nothing rather than a zero-minute
    /// entry: the work log refuses no time at all, and a row saying somebody
    /// spent no time on something is noise.
    @discardableResult
    public func stopTimer(discarding: Bool = false) throws -> WorkLogEntry? {
        guard let running = try runningTimer() else { return nil }

        try database.execute("DELETE FROM running_timer WHERE id = 1;")
        guard !discarding else { return nil }

        let minutes = running.minutes(now: clock.now)
        guard minutes > 0 else { return nil }

        return try logWork(
            onTask: running.taskID,
            minutes: minutes,
            note: "",
            personID: running.personID,
            workedOn: running.startedAt
        )
    }
}

// MARK: - Comments that are asking for something

extension CardDetailRepository {

    /// Turns a remark into a request, or back.
    ///
    /// The comment keeps its words either way: an action item is the comment
    /// with somebody's name against it, not a copy of it in a different list.
    /// Un-marking one leaves the remark in the thread, because deleting what
    /// somebody wrote because it stopped being a task would be startling.
    public func setActionItem(
        _ isAction: Bool, assignee personID: String?, for commentID: String
    ) throws {
        let changed = try database.execute(
            """
            UPDATE comment SET action_item = ?, action_assignee_id = ?,
                               action_done = CASE WHEN ? THEN action_done ELSE 0 END,
                               action_done_at = CASE WHEN ? THEN action_done_at ELSE NULL END
            WHERE id = ?;
            """,
            [isAction, personID.sqlValue, isAction, isAction, commentID]
        )
        guard changed > 0 else { throw LocalBoardError.notFound(entity: "comment \(commentID)") }
    }

    public func setActionDone(_ done: Bool, for commentID: String) throws {
        let changed = try database.execute(
            "UPDATE comment SET action_done = ?, action_done_at = ? WHERE id = ? AND action_item = 1;",
            [done, done ? clock.now.sqlValue : SQLValue.null, commentID]
        )
        guard changed > 0 else {
            throw LocalBoardError.notFound(entity: "action item \(commentID)")
        }
    }

    /// Every open action item in a project, for the list that shows what has
    /// been asked of people in passing.
    public func openActionItems(inProject projectID: String) throws -> [Comment] {
        try database.query(
            """
            SELECT comment.* FROM comment
            JOIN task ON task.id = comment.task_id
            WHERE task.project_id = ? AND task.trashed = 0
              AND comment.action_item = 1 AND comment.action_done = 0
            ORDER BY comment.created_at;
            """,
            [projectID]
        ).map(Comment.init(row:))
    }

    /// Action items asked of one person, which is what "my work" shows
    /// alongside their cards.
    public func actionItems(for personID: String, includeDone: Bool = false) throws -> [Comment] {
        let done = includeDone ? "" : " AND comment.action_done = 0"
        return try database.query(
            """
            SELECT comment.* FROM comment
            JOIN task ON task.id = comment.task_id
            WHERE comment.action_item = 1 AND comment.action_assignee_id = ?
              AND task.trashed = 0\(done)
            ORDER BY comment.created_at;
            """,
            [personID]
        ).map(Comment.init(row:))
    }
}
