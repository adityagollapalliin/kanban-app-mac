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
        case density
        case accent
        case dueReminders = "due_reminders"
        case menuBar = "menu_bar"
    }

    let database: Database

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

// MARK: - How the app looks

extension AppSettings {

    /// How much room the board gives each card.
    ///
    /// Kept with the file rather than in user defaults, alongside everything
    /// else about how a board looks: a board that changes shape depending on
    /// which Mac opened it would be two boards.
    public var density: Density {
        get throws {
            guard let raw = try value(for: .density), let number = Int(raw),
                  let density = Density(rawValue: number) else { return .comfortable }
            return density
        }
    }

    public func setDensity(_ density: Density) throws {
        try setValue(String(density.rawValue), for: .density)
    }

    /// The palette colour the app draws its accents in, or nil for the one the
    /// user chose in System Settings.
    public var accent: String? {
        get throws { try value(for: .accent) }
    }

    public func setAccent(_ name: String?) throws {
        try setValue(name, for: .accent)
    }

    /// Whether due-date reminders are wanted at all. Off until asked for,
    /// because a notification nobody agreed to is an interruption.
    public var remindsAboutDueDates: Bool {
        get throws { try value(for: .dueReminders) == "1" }
    }

    public func setRemindsAboutDueDates(_ on: Bool) throws {
        try setValue(on ? "1" : nil, for: .dueReminders)
    }

    /// Whether the menu bar item is shown. Off unless asked for: the menu bar
    /// is the one strip of screen everything competes for.
    public var showsMenuBarExtra: Bool {
        get throws { try value(for: .menuBar) == "1" }
    }

    public func setShowsMenuBarExtra(_ on: Bool) throws {
        try setValue(on ? "1" : nil, for: .menuBar)
    }

    private func value(for key: Key) throws -> String? {
        try database.queryOne("SELECT value FROM app_meta WHERE key = ?;", [key.rawValue])?
            .string("value")
    }

    private func setValue(_ value: String?, for key: Key) throws {
        guard let value else {
            try database.execute("DELETE FROM app_meta WHERE key = ?;", [key.rawValue])
            return
        }
        try database.execute(
            "INSERT INTO app_meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = ?;",
            [key.rawValue, value, value]
        )
    }
}
