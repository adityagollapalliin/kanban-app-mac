import Foundation
import LocalBoardCore

/// The handful of settings that belong to the file rather than to the Mac.
///
/// `app_meta` has existed since v1 and has been empty since v1. It earns its
/// keep now: `is:mine` needs to know who "me" is, and that answer belongs
/// beside the data it is about — a saved view reading `is:mine` then means
/// the right thing whichever copy of the app opens the file, rather than
/// depending on a preference the file knows nothing about.
public struct AppSettings {

    /// Keys are strings in one place, here, so a typo is a compile error
    /// everywhere else.
    enum Key: String {
        case currentPerson = "current_person_id"
    }

    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    // MARK: - Who "me" is

    public var currentPersonID: String? {
        get throws {
            // A person who has since been deleted is nobody, not a dangling
            // id: the join is what keeps `is:mine` honest after a tidy-up.
            try database.queryOne(
                """
                SELECT person.id AS id FROM app_meta
                JOIN person ON person.id = app_meta.value
                WHERE app_meta.key = ?;
                """,
                [Key.currentPerson.rawValue]
            )?.string("id")
        }
    }

    public func setCurrentPerson(_ personID: String?) throws {
        guard let personID else {
            try database.execute("DELETE FROM app_meta WHERE key = ?;", [Key.currentPerson.rawValue])
            return
        }
        try database.execute(
            "INSERT INTO app_meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = ?;",
            [Key.currentPerson.rawValue, personID, personID]
        )
    }
}
