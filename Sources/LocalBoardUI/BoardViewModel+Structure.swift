import Foundation
import LocalBoardCore
import LocalBoardStore

/// The hierarchy, the people on a card, where a card also lives, what it
/// repeats, and the sidebar's shortcuts.
///
/// Everything here goes through `perform` and `editing` like the rest of the
/// model, so a folder renamed from the sidebar surfaces its failure the same
/// way a mistyped card title does.
@MainActor
extension BoardViewModel {

    // MARK: - Loading

    /// Read with the board: the sidebar has to be right the moment it is
    /// drawn, and all of this is a handful of queries against small tables.
    func loadStructure(projectID: String) throws {
        folders = try structureRepository.folders(inSpace: projectID)
        lists = try structureRepository.lists(inSpace: projectID)
        assigneesByTask = try membershipRepository.assigneesByTask(inProject: projectID)
        extraListsByTask = try membershipRepository.extraListsByTask(inProject: projectID)

        // A list that has been archived or deleted stops narrowing the board,
        // rather than leaving it showing nothing with no way back.
        if let selectedListID, !lists.contains(where: { $0.id == selectedListID }) {
            self.selectedListID = nil
        }

        // Scheduled recurrences catch up here — on open, not on a timer.
        let made = try recurrenceRepository.spawnDue(inProject: projectID)
        if !made.isEmpty {
            Log.ui.info("\(made.count, privacy: .public) recurring cards came due.")
        }
    }

    func loadSidebar() {
        perform {
            favorites = try sidebarRepository.shortcuts(.favorite)
            pinnedViews = try sidebarRepository.shortcuts(.pinnedView)
            recents = try sidebarRepository.shortcuts(.recent)
            trashedTasks = try sidebarRepository.trashed(inProject: currentProjectID)
            let put = try sidebarRepository.archived()
            archivedFolders = put.folders
            archivedLists = put.lists
        }
    }

    /// Removes what has been in the trash past its thirty days. Called on
    /// open: a Mac asleep for a month catches up the moment the file opens.
    func purgeExpiredTrash() {
        perform { _ = try sidebarRepository.purgeExpiredTrash() }
    }

    public var currentProjectID: String? {
        guard let boardID = selectedBoardID else { return nil }
        return boards.first { $0.id == boardID }?.projectID
    }

    public var currentProject: Project? {
        guard let currentProjectID else { return nil }
        return projects.first { $0.id == currentProjectID }
    }

    // MARK: - Spaces

    public func setSpaceAppearance(color: String, icon: String, for spaceID: String) {
        perform {
            try structureRepository.setAppearance(color: color, icon: icon, forSpace: spaceID)
            projects = try workspaces.flatMap { try boardRepository.projects(inWorkspace: $0.id) }
        }
    }

    public func setSpaceArchived(_ archived: Bool, for spaceID: String) {
        perform {
            try boardRepository.setArchived(archived, for: spaceID)
            load()
        }
    }

    // MARK: - Folders

    public func createFolder(named name: String) {
        guard let currentProjectID else { return }
        perform {
            try structureRepository.createFolder(inSpace: currentProjectID, name: name)
            try loadStructure(projectID: currentProjectID)
        }
    }

    public func renameFolder(_ folderID: String, to name: String) {
        withStructure { try structureRepository.renameFolder(folderID, to: name) }
    }

    public func setFolderArchived(_ archived: Bool, for folderID: String) {
        withStructure { try structureRepository.setFolderArchived(archived, for: folderID) }
    }

    public func deleteFolder(_ folderID: String) {
        withStructure {
            try structureRepository.deleteFolder(folderID)
            try sidebarRepository.forget(target: .folder, id: folderID)
        }
    }

    // MARK: - Lists

    public func createList(named name: String, inFolder folderID: String? = nil) {
        guard let currentProjectID else { return }
        perform {
            try structureRepository.createList(inSpace: currentProjectID, folderID: folderID, name: name)
            try loadStructure(projectID: currentProjectID)
        }
    }

    public func renameList(_ listID: String, to name: String) {
        withStructure { try structureRepository.renameList(listID, to: name) }
    }

    public func moveList(_ listID: String, toFolder folderID: String?) {
        withStructure { try structureRepository.moveList(listID, toFolder: folderID) }
    }

    public func setListArchived(_ archived: Bool, for listID: String) {
        withStructure {
            try structureRepository.setListArchived(archived, for: listID)
            if selectedListID == listID { selectedListID = nil }
        }
    }

    /// Deleting a list has to say where its cards go, because a list cannot be
    /// taken out from under them. `nil` trashes them, which is recoverable.
    public func deleteList(_ listID: String, movingCardsTo destination: String?) {
        withStructure {
            try structureRepository.deleteList(listID, movingCardsTo: destination)
            try sidebarRepository.forget(target: .list, id: listID)
            try viewConfigRepository.forget(scope: .list, id: listID)
            if selectedListID == listID { selectedListID = nil }
        }
    }

    public func list(id: String?) -> TaskList? {
        guard let id else { return nil }
        return lists.first { $0.id == id }
    }

    public var selectedList: TaskList? { list(id: selectedListID) }

    public func lists(inFolder folderID: String) -> [TaskList] {
        lists.filter { $0.folderID == folderID }
    }

    /// Lists that sit straight in the space rather than in a folder.
    public var looseLists: [TaskList] {
        lists.filter { $0.folderID == nil }
    }

    public func taskCount(inList listID: String) -> Int {
        visibleTasks.filter { $0.listID == listID }.count
            + visibleTasks.filter { extraListsByTask[$0.id]?.contains { $0.id == listID } == true }.count
    }

    /// A list's own statuses, or its space's. Used when a list is on screen
    /// and the columns have to be its own rather than the board's.
    public func statuses(forList listID: String) -> [Status] {
        (try? structureRepository.statuses(forList: listID)) ?? statuses
    }

    public func overridesStatuses(_ listID: String) -> Bool {
        (try? structureRepository.overridesStatuses(listID)) ?? false
    }

    public func setStatuses(_ statusIDs: [String], forList listID: String) {
        withStructure { try structureRepository.setStatuses(statusIDs, forList: listID) }
    }

    /// What state a card's column counts as. The box view reads it to say
    /// how much of somebody's work has actually started.
    public func category(of task: BoardTask) -> StatusCategory {
        snapshot?.columns.first { $0.status.id == task.statusID }?.status.category
            ?? statuses.first { $0.id == task.statusID }?.category
            ?? .toDo
    }

    // MARK: - Several people on a card

    public func assignees(of task: BoardTask) -> [TaskAssignee] {
        assigneesByTask[task.id] ?? []
    }

    public func people(on task: BoardTask) -> [Person] {
        assignees(of: task).compactMap { assignee in people.first { $0.id == assignee.personID } }
    }

    public func addAssignee(_ personID: String, to taskID: String) {
        editing([taskID], "Add Assignee") {
            try membershipRepository.addAssignee(personID, to: taskID)
        }
    }

    public func removeAssignee(_ personID: String, from taskID: String) {
        editing([taskID], "Remove Assignee") {
            try membershipRepository.removeAssignee(personID, from: taskID)
        }
    }

    public func setAssigneeEstimate(_ estimate: Double?, for personID: String, on taskID: String) {
        editing([taskID], "Change Share") {
            try membershipRepository.setEstimate(estimate, forAssignee: personID, on: taskID)
        }
    }

    // MARK: - A card in several lists

    public func extraLists(of task: BoardTask) -> [TaskList] {
        extraListsByTask[task.id] ?? []
    }

    public func addTask(_ taskID: String, toList listID: String) {
        editing([taskID], "Add to List") {
            try membershipRepository.addTask(taskID, toList: listID)
        }
    }

    public func removeTask(_ taskID: String, fromList listID: String) {
        editing([taskID], "Remove from List") {
            try membershipRepository.removeTask(taskID, fromList: listID)
        }
    }

    public func setHomeList(_ listID: String, forTask taskID: String) {
        editing([taskID], "Move to List") {
            try membershipRepository.setHomeList(listID, forTask: taskID)
        }
    }

    // MARK: - Milestones

    public func setMilestone(_ isMilestone: Bool, for taskID: String) {
        editing([taskID], isMilestone ? "Make a Milestone" : "Stop Being a Milestone") {
            try database.execute(
                "UPDATE task SET is_milestone = ? WHERE id = ?;", [isMilestone, taskID]
            )
        }
    }

    // MARK: - Recurrence

    public func setRecurrence(_ rule: RecurrenceRule, for taskID: String) {
        perform {
            try recurrenceRepository.setRule(rule, forTask: taskID)
            recurrence = try recurrenceRepository.recurrence(ofTask: taskID)
        }
    }

    public func clearRecurrence(for taskID: String) {
        perform {
            try recurrenceRepository.removeRule(fromTask: taskID)
            recurrence = nil
        }
    }

    public func recurrence(of taskID: String) -> Recurrence? {
        (try? recurrenceRepository.recurrence(ofTask: taskID)) ?? nil
    }

    // MARK: - Sidebar shortcuts

    public func toggleFavorite(_ target: ShortcutTarget, id targetID: String, label: String) {
        perform {
            try sidebarRepository.toggleFavorite(target, id: targetID, label: label)
            loadSidebar()
        }
    }

    public func isFavorite(_ target: ShortcutTarget, id targetID: String) -> Bool {
        favorites.contains { $0.target == target && $0.targetID == targetID }
    }

    public func pinView(_ label: String, query: String) {
        perform {
            try sidebarRepository.add(.pinnedView, target: .savedView, id: query, label: label)
            loadSidebar()
        }
    }

    public func unpin(_ shortcut: Shortcut) {
        perform {
            try sidebarRepository.remove(shortcut.kind, target: shortcut.target, id: shortcut.targetID)
            loadSidebar()
        }
    }

    /// Opens whatever a sidebar shortcut points at. A shortcut to something
    /// that has since gone says so rather than doing nothing.
    public func open(_ shortcut: Shortcut) {
        switch shortcut.target {
        case .list:
            guard lists.contains(where: { $0.id == shortcut.targetID }) else {
                failure = .notFound(entity: "the list “\(shortcut.label)”")
                return
            }
            selectedListID = shortcut.targetID

        case .board:
            guard boards.contains(where: { $0.id == shortcut.targetID }) else {
                failure = .notFound(entity: "the board “\(shortcut.label)”")
                return
            }
            selectedBoardID = shortcut.targetID

        case .savedView:
            queryText = shortcut.targetID

        case .task:
            selectedTaskID = shortcut.targetID

        case .space:
            guard let board = boards.first(where: { $0.projectID == shortcut.targetID }) else {
                failure = .notFound(entity: "the space “\(shortcut.label)”")
                return
            }
            selectedBoardID = board.id

        case .folder:
            guard let first = lists.first(where: { $0.folderID == shortcut.targetID }) else { return }
            selectedListID = first.id
        }
    }

    // MARK: - Trash

    public func restoreFromTrash(_ taskID: String) {
        perform {
            try taskRepository.setTrashed(false, for: taskID)
            reloadSnapshot()
        }
    }

    public func emptyTrash() {
        perform {
            try sidebarRepository.emptyTrash(inProject: currentProjectID)
            reloadSnapshot()
        }
    }

    /// How long a trashed card has left, for the line that warns before the
    /// app removes it.
    public func daysLeftInTrash(_ task: BoardTask) -> Int? {
        guard let trashedAt = task.trashedAt else { return nil }
        return TrashPolicy.daysLeft(trashedAt, now: .now)
    }

    // MARK: - View settings

    public func viewConfig(_ kind: ViewKind) -> ViewConfig {
        let scope: (ViewScopeKind, String) = {
            if let selectedListID { return (.list, selectedListID) }
            if let currentProjectID { return (.space, currentProjectID) }
            return (.everything, "")
        }()

        return (try? viewConfigRepository.config(kind, scope: scope.0, id: scope.1))
            ?? ViewConfig(id: UUID().uuidString, scopeKind: scope.0, scopeID: scope.1,
                          viewKind: kind, updatedAt: .now)
    }

    public func save(_ config: ViewConfig) {
        perform { try viewConfigRepository.save(config) }
    }

    // MARK: - The other screens' data

    public func activityFeed(limit: Int = 200) -> [ActivityRepository.Entry] {
        guard let currentProjectID else { return [] }
        return (try? activityRepository.feed(inProject: currentProjectID, limit: limit)) ?? []
    }

    public func workload(from start: Date, days: Int) -> [WorkloadRepository.Load] {
        guard let currentProjectID else { return [] }
        return (try? workloadRepository.loads(inProject: currentProjectID, from: start, days: days)) ?? []
    }

    public func setCapacity(_ amount: Double, unit: CapacityUnit, period: CapacityPeriod, for personID: String) {
        perform {
            try workloadRepository.setCapacity(amount, unit: unit, period: period, for: personID)
            people = try personRepository.people()
        }
    }

    /// Moving a card in the workload view is one action — who it is for and
    /// when it is due — because doing half of it leaves the card where it was
    /// not dropped.
    public func reassign(_ taskID: String, to personID: String?, on day: Date?) {
        editing([taskID], "Rebalance") {
            try workloadRepository.reassign(taskID, to: personID, on: day)
        }
    }

    /// Every card in the file, for the Everything view. The same filters
    /// apply; only the reach is different.
    public func everything() -> [BoardTask] {
        guard let currentProjectID else { return [] }
        let query = effectiveQuery
        return (try? taskRepository.tasks(
            matching: query, inProject: currentProjectID, acrossProjects: true
        )) ?? []
    }

    // MARK: - Helper

    private func withStructure(_ body: () throws -> Void) {
        perform {
            try body()
            if let currentProjectID { try loadStructure(projectID: currentProjectID) }
            loadSidebar()
            reloadSnapshot()
        }
    }
}
