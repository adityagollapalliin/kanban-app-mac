import Foundation
import Testing
import LocalBoardCore
@testable import LocalBoardStore

@Suite("An archive written by an older build still opens")
struct ArchiveCompatibilityTests {

    /// A card exactly as an archive written before schema 9 spells one: no
    /// `typeCode`, no `resolutionID`, no `environment`.
    ///
    /// Adding a non-optional property to a `Codable` type is the quiet way to
    /// make every file anybody exported unreadable, which is why this is
    /// asserted rather than assumed.
    @Test("A card from before the vocabulary fields decodes")
    func oldCardDecodes() throws {
        let json = """
        {
          "id": "t1", "projectID": "p1", "statusID": "s1", "number": 1,
          "type": 2, "title": "Old card", "descriptionMarkdown": "",
          "priority": 2, "sortOrder": 1000, "trashed": false,
          "createdAt": 0, "updatedAt": 0, "flagged": false, "flagReason": "",
          "isMilestone": false
        }
        """
        let task = try JSONDecoder().decode(BoardTask.self, from: Data(json.utf8))
        #expect(task.title == "Old card")
        #expect(task.type == .task)
        // The raw code falls back to the enumeration's, which is what it was.
        #expect(task.typeCode == 2)
        #expect(task.environment.isEmpty)
        #expect(task.resolutionID == nil)
    }

    @Test("A filter round-trips with the language it is written in")
    func savedViewSyntaxRoundTrips() throws {
        let clock = StoppedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()
        let views = SavedViewRepository(database: database, clock: clock)

        try views.create(inProject: ids.project, name: "Basic", query: "ORDER BY due")
        try views.create(
            inProject: ids.project, name: "Advanced", query: "priority IN (high)", syntax: .jql
        )

        let archive = try ProjectArchive.export(projectID: ids.project, from: database, now: clock.now)
        let data = try JSONEncoder().encode(archive)
        let decoded = try JSONDecoder().decode(ProjectArchive.self, from: data)

        let restored = try decoded.restore(into: database, now: clock.now)
        let back = try views.views(inProject: restored.project.id)

        #expect(back.count == 2)
        #expect(back.first { $0.name == "Basic" }?.syntax == .simple)
        #expect(back.first { $0.name == "Advanced" }?.syntax == .jql)
    }

    @Test("A backup with no syntax on its filters treats every one as basic")
    func archiveWithoutSyntax() throws {
        let clock = StoppedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let database = try Database.inMemoryMigrated()
        let ids = try database.seedBoardProject()

        // Exactly as an archive written before the column existed spells a
        // filter: a name and a query, and nothing about the language.
        let json = """
        {
          "schemaVersion": 9,
          "exportedAt": 0,
          "project": {"id": "p1", "workspaceID": "w1", "name": "Old", "key": "OLD",
                      "descriptionMarkdown": "", "nextTaskNumber": 1, "archived": false,
                      "sortOrder": 1000, "createdAt": 0, "color": "", "icon": ""},
          "statuses": [
            {"id": "s1", "projectID": "p1", "name": "To Do", "category": 0, "sortOrder": 1000}
          ],
          "tasks": [],
          "savedViews": [
            {"id": "v1", "projectID": "p1", "name": "Words", "query": "ORDER BY due",
             "sortOrder": 1000, "createdAt": 0}
          ]
        }
        """
        let decoded = try JSONDecoder().decode(ProjectArchive.self, from: Data(json.utf8))
        #expect(decoded.savedViews.first?.syntax == .simple)

        let restored = try decoded.restore(into: database, now: clock.now)
        let back = try SavedViewRepository(database: database, clock: clock)
            .views(inProject: restored.project.id)
        // Restored as basic, so it goes on being the text search it was.
        #expect(back.first?.syntax == .simple)
        _ = ids
    }
}
