import Foundation
import LocalBoardCore
@testable import LocalBoardStore

/// The contract the query language has to keep.
///
/// Milestone 8.5 extends the language towards JQL. The brief's requirement is
/// that the new grammar be a *strict superset*: every filter anybody has
/// already saved must still parse, and must still return the same cards.
///
/// This file is the evidence for that. It holds every query string the app can
/// be carrying — read out of the live database, taken from the existing tests,
/// and written by hand to cover the corners of the grammar — and
/// `QueryCompatibilityTests` compiles each one against a fixed database and a
/// stopped clock, comparing the SQL and the bound values against a baseline
/// recorded before the language was touched.
///
/// **How to change the language.** A query that compiles today must compile to
/// the same SQL tomorrow; if the baseline changes, the test fails and names
/// the query. A query that is *rejected* today may legitimately start being
/// accepted — that is what "superset" means — but doing so requires moving its
/// baseline entry by hand in the same commit, so every extension leaves a
/// visible record of exactly which previously-invalid text became valid.
///
/// ## The baseline has been re-recorded once
///
/// **Milestone 8.5c, priority ranks.** `priority >= high` compiled to
/// `task.priority >= 3` — a comparison against the stored code. That is only
/// correct while every rank equals its code, which is true of every scale the
/// app seeds and stops being true the moment a project inserts a step in the
/// middle: code 5 ranked 3 would have sorted above Highest.
///
/// It now asks the project's scale. Six of the 101 entries changed SQL and
/// every one is a priority comparison; the other 95 are untouched. That the
/// *results* are unchanged for a seeded scale is asserted card by card in
/// `PriorityRankTests`, which was written before the baseline was moved.
enum QueryCorpus {

    /// Where the corpus came from, so a reader can tell a real saved filter
    /// from one written to cover a corner.
    enum Source: String {
        /// Read out of the user's own board.sqlite on 2026-09-25.
        case live
        /// Created by the app itself for every new board.
        case starter
        /// Already asserted somewhere in the existing suite.
        case tests
        /// Written here to cover a part of the grammar nothing else reaches.
        case coverage
        /// Written in source as a literal — the app asks these itself.
        case builtIn
        /// Rejected by today's parser. Recorded so that a query the new
        /// grammar legitimately starts accepting shows up as a deliberate
        /// change to the baseline rather than passing unnoticed.
        case rejectedToday
        /// JQL-shaped text that today's parser already accepts — as a
        /// full-text search, because an unrecognised word is a search term
        /// here. These are the collision: they are not invalid strings
        /// waiting to be given a meaning, they are valid strings that already
        /// have one.
        case textSearchToday
    }

    struct Entry {
        let query: String
        let source: Source
    }

    static let all: [Entry] = live + starter + fromTests + builtIn + coverage + rejectedToday + textSearchToday

    // MARK: Read out of the live database

    static let live: [Entry] = [
        Entry(query: "due < +7d", source: .live),
        Entry(query: "assignee = \"Ada Lovelace\"", source: .live),
        Entry(query: "is:overdue", source: .live),
        Entry(query: "priority >= highest", source: .live),
    ].map { $0 }

    // MARK: What every new board is given

    static let starter: [Entry] = [
        "is:mine",
        "updated >= -3d",
        "is:flagged",
        "due <= +7d is:open",
    ].map { Entry(query: $0, source: .starter) }

    // MARK: Asked by the app itself, in source

    static let builtIn: [Entry] = [
        "not is:trashed",
        "is:flagged",
        "is:open",
        "is:overdue",
    ].map { Entry(query: $0, source: .builtIn) }

    // MARK: Already asserted somewhere in the suite

    static let fromTests: [Entry] = [
        "is:done",
        "is:open and is:overdue",
        "is:open is:overdue",
        "is:open is:overdue or is:done",
        "is:done or is:trashed",
        "(is:done or is:trashed) is:overdue",
        "not is:done",
        "due < -2w",
        "due = today",
        "due = tomorrow",
        "due = yesterday",
        "due = none",
        "created > 2026-10-01",
        "assignee != none",
        "priority >= high",
        "type = bug",
        "type != bug",
        "priority:highest",
        "type:bug",
        "is:UNASSIGNED",
    ].map { Entry(query: $0, source: .tests) }

    // MARK: Corners of the grammar nothing else reaches

    static let coverage: [Entry] = [
        // Every field, at least once.
        "due <= 2026-12-25",
        "start > -1w",
        "updated < +2d",
        "completed >= -30d",
        "created <= today",
        "title = login",
        "status = \"In Progress\"",
        "label = backend",
        "key = WORK-1",
        "version = \"1.0\"",
        "epic = WORK-1",
        "sprint = \"Sprint 1\"",
        "points >= 3",
        "points < 8",
        "days >= 5",
        "flag = 1",

        // Every flag.
        "is:done", "is:open", "is:overdue", "is:trashed", "is:assigned",
        "is:unassigned", "is:subtask", "is:labelled", "is:flagged",
        "is:mine", "is:epic", "is:released", "is:backlog",

        // Every comparison, on a field that supports each.
        "points > 1", "points >= 1", "points < 9", "points <= 9",
        "points = 5", "points != 5",

        // Custom fields, one per storage kind.
        "cf:Size = 3",
        "cf:Notes = urgent",
        "cf:Signed = yes",
        "cf:Reviewed = 2026-01-01",
        "cf:Stage = Beta",
        "cf:Size > 2",
        "cf:Size = none",

        // Bare text, which is a text search here and a syntax error in JQL.
        // This is the divergence most likely to be broken by accident.
        "login",
        "login screen",
        "\"exact phrase\"",
        "login is:open",

        // Combination and precedence.
        "is:open or is:done and is:flagged",
        "not (is:done or is:trashed)",
        "not is:done not is:trashed",
        "(due < today) (priority >= high)",
        "is:open (type = bug or type = story)",

        // Case and spacing, which people get wrong.
        "IS:OPEN",
        "Priority >= High",
        "  is:open  ",
        "due<+7d",
        "priority>=high",

        // Empty, which every caller treats as "everything".
        "",
        "   ",
    ].map { Entry(query: $0, source: .coverage) }

    // MARK: Rejected by today's parser

    /// These are the boundary of the language. JQL may legitimately accept
    /// some of them — `ORDER BY` certainly will — and when it does, moving the
    /// entry's baseline from rejected to compiling is the visible record of
    /// the grammar growing.
    static let rejectedToday: [Entry] = [
        "due < banana",
        "priority = urgentish",
        "is:sideways",
        "type = wombat",
        "due <",
        "(is:done",
        "is:done)",
        "points > ",
        "cf:Size > banana",
        "cf:Nonexistent = 3",
        "assignee = currentUser()",
        "due >= startOfWeek()",
    ].map { Entry(query: $0, source: .rejectedToday) }

    // MARK: JQL-shaped, and already meaningful

    /// The collision at the heart of extending this language towards JQL.
    ///
    /// Every one of these compiles **today** — as a full-text search, because
    /// an unrecognised word is a search term in this grammar. If 8.5 gives
    /// `ORDER BY`, `IN`, `~`, `WAS` and `CHANGED` their JQL meanings in the
    /// same grammar, these strings stop being searches and start being
    /// clauses. That is a change of meaning for text somebody may have saved,
    /// which is precisely what "strict superset" forbids.
    ///
    /// They are recorded here so the collision is a failing test rather than a
    /// discovery made afterwards. See IMPACT-8.5.md §2.
    static let textSearchToday: [Entry] = [
        "ORDER BY due",
        "priority IN (high, highest)",
        "summary ~ login",
        "status WAS \"In Progress\"",
        "status CHANGED FROM \"To Do\" TO \"Done\"",
        // Not JQL, but the same shape of surprise: a status name that does not
        // exist compiles fine and simply matches nothing.
        "status = \"No Such Column\"",
    ].map { Entry(query: $0, source: .textSearchToday) }
}