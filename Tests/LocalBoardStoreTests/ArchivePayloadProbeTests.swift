import Foundation
import Testing
import LocalBoardCore
@testable import LocalBoardStore

/// Probes every type the export format carries, with only the keys the very
/// first version of that type had.
///
/// The failure mode this exists for has now happened three times: a property
/// is added to a model, its synthesised `Codable` starts demanding the new
/// key, and every file anybody exported becomes unreadable — with an error
/// nobody outside the code can act on. One test per type, so the next one is
/// caught on the day it is written rather than by somebody's lost backup.
@Suite("Every archive payload type survives an older file")
struct ArchivePayloadProbeTests {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test("Person")
    func person() throws {
        let value = try decode(Person.self, #"{"id":"p","name":"Ada","sortOrder":1000,"createdAt":0}"#)
        #expect(value.name == "Ada")
    }

    @Test("CardLabel")
    func label() throws {
        let value = try decode(CardLabel.self, #"{"id":"l","projectID":"p","name":"backend"}"#)
        #expect(value.name == "backend")
    }

    @Test("ChecklistItem")
    func checklistItem() throws {
        let value = try decode(
            ChecklistItem.self,
            #"{"id":"c","taskID":"t","text":"Do it","done":false,"sortOrder":1000}"#
        )
        #expect(value.text == "Do it")
    }

    @Test("Status")
    func status() throws {
        let value = try decode(
            Status.self,
            #"{"id":"s","projectID":"p","name":"To Do","category":0,"sortOrder":1000}"#
        )
        #expect(value.diagramX == 0)
    }

    @Test("SavedView")
    func savedView() throws {
        let value = try decode(
            SavedView.self,
            #"{"id":"v","projectID":"p","name":"Mine","query":"is:mine","sortOrder":1000,"createdAt":0}"#
        )
        #expect(value.syntax == .simple)
    }

    @Test("Project")
    func project() throws {
        let value = try decode(
            Project.self,
            #"{"id":"p","workspaceID":"w","name":"Work","key":"WORK"}"#
        )
        #expect(!value.enforcesWorkflow)
    }

    @Test("BoardTask")
    func boardTask() throws {
        let value = try decode(
            BoardTask.self,
            #"{"id":"t","projectID":"p","statusID":"s","number":1,"title":"A card","sortOrder":1000,"createdAt":0,"updatedAt":0}"#
        )
        #expect(value.typeCode == 2)
    }
}
