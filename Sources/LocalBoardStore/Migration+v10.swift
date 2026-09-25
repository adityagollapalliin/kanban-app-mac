import Foundation

// Schema version 10 — every stored query says which language it is in.
//
// Milestone 8.5b extends the filter language towards JQL, and the promise
// attached to that was a strict superset: every filter anybody has already
// saved must still parse and still return the same cards.
//
// That promise cannot be kept by one grammar. Six JQL-shaped strings already
// compile in the original language — as full-text searches, because an
// unrecognised word is a search term there. `ORDER BY due` means "find cards
// mentioning order, by and due". Giving those words their JQL meanings would
// change what such a filter returns.
//
// So: every column holding query text gains a column saying which language it
// is written in, defaulting to `simple`. A filter written before today is
// thereby *declared* to be in the old language and goes on being parsed by the
// old parser. Its meaning cannot change, because the code that reads it does
// not change. The promise holds by construction rather than by care.
//
// The audit behind this — which places store query text, and which of the
// eleven named in the brief actually exist — is Appendix A of IMPACT-8.5.md.
extension Migration {
    static let v10QuerySyntax = Migration(
        version: 10,
        name: "query syntax",
        statements: [

            // MARK: The six that were named, and the one that was not

            "ALTER TABLE saved_view ADD COLUMN syntax TEXT NOT NULL DEFAULT 'simple';",
            "ALTER TABLE quick_filter ADD COLUMN syntax TEXT NOT NULL DEFAULT 'simple';",
            "ALTER TABLE swimlane ADD COLUMN syntax TEXT NOT NULL DEFAULT 'simple';",
            "ALTER TABLE goal ADD COLUMN syntax TEXT NOT NULL DEFAULT 'simple';",
            "ALTER TABLE dashboard_widget ADD COLUMN syntax TEXT NOT NULL DEFAULT 'simple';",
            "ALTER TABLE view_config ADD COLUMN syntax TEXT NOT NULL DEFAULT 'simple';",

            // The board's own query has a longer name, because `board` may one
            // day hold a second one and `syntax` alone would not say which.
            "ALTER TABLE board ADD COLUMN filter_syntax TEXT NOT NULL DEFAULT 'simple';",

            // Card colour rules are not on this list on purpose: a colour rule
            // points at a saved view rather than holding a query of its own,
            // so it inherits that view's syntax. Automations, SLA queues and
            // filter digests are not here either — they do not exist yet, and
            // each will be born with a syntax column in 8.5f.

            // MARK: Filters you keep to hand

            "ALTER TABLE saved_view ADD COLUMN starred INTEGER NOT NULL DEFAULT 0;",

            // Which columns the navigator shows for this filter, newline
            // separated. Empty means the default set, so an existing filter
            // opens looking exactly as it does today.
            "ALTER TABLE saved_view ADD COLUMN columns TEXT NOT NULL DEFAULT '';",

            "CREATE INDEX saved_view_starred ON saved_view (starred, sort_order);",
        ]
    )
}
