import Foundation
import LocalBoardCore
import LocalBoardStore

/// Milestone 8: goals, dashboards, the fields that work themselves out, and
/// the two reports that read the time log rather than adding to it.
extension BoardViewModel {

    // MARK: - Goals

    public func goals(inFolder folderID: String?) -> [Goal] {
        goals.filter { $0.folderID == folderID }
    }

    public func goalFolder(named id: String?) -> GoalFolder? {
        guard let id else { return nil }
        return goalFolders.first { $0.id == id }
    }

    public func createGoal(
        named name: String,
        kind: GoalKind,
        target: Double,
        start: Double = 0,
        currency: String = "USD",
        query: String = "",
        listID: String? = nil,
        folderID: String? = nil,
        dueAt: Date? = nil,
        notes: String = ""
    ) {
        guard let projectID = currentProjectID else { return }
        perform {
            try goalRepository.create(
                inProject: projectID, name: name, kind: kind, target: target, start: start,
                currency: currency, query: query, listID: listID, folderID: folderID,
                dueAt: dueAt, notes: notes
            )
            reloadSnapshot()
        }
    }

    public func updateGoal(_ goal: Goal) {
        perform {
            try goalRepository.update(goal)
            if goal.kind.isAutomatic { try goalRepository.refresh(goal.id) }
            reloadSnapshot()
        }
    }

    public func setGoalCurrent(_ value: Double, for goalID: String) {
        perform {
            try goalRepository.setCurrent(value, for: goalID)
            reloadSnapshot()
        }
    }

    public func setGoalFolder(_ folderID: String?, for goalID: String) {
        perform {
            try goalRepository.setFolder(folderID, for: goalID)
            reloadSnapshot()
        }
    }

    public func archiveGoal(_ goalID: String, archived: Bool = true) {
        perform {
            try goalRepository.setArchived(archived, for: goalID)
            reloadSnapshot()
        }
    }

    public func deleteGoal(_ goalID: String) {
        perform {
            try goalRepository.delete(goalID)
            reloadSnapshot()
        }
    }

    public func createGoalFolder(named name: String) {
        guard let projectID = currentProjectID else { return }
        perform {
            try goalRepository.createFolder(inProject: projectID, named: name)
            reloadSnapshot()
        }
    }

    public func deleteGoalFolder(_ folderID: String) {
        perform {
            try goalRepository.deleteFolder(folderID)
            reloadSnapshot()
        }
    }

    /// Recounts the goals that count their own cards.
    ///
    /// Called when the Goals screen is opened rather than on every card move:
    /// a goal that is a few seconds behind is a better trade than every drag
    /// on the board going looking for goals that might care.
    public func refreshGoals() {
        guard let projectID = currentProjectID else { return }
        perform {
            try goalRepository.refreshAll(inProject: projectID)
            goals = try goalRepository.goals(inProject: projectID)
        }
    }

    // MARK: - Dashboards

    public func widgets(on dashboardID: String) -> [DashboardWidget] {
        (try? dashboardRepository.widgets(on: dashboardID)) ?? []
    }

    public func widgetData(_ widget: DashboardWidget) -> WidgetData {
        guard let projectID = currentProjectID else {
            return .unavailable("No space is open.")
        }
        return (try? dashboardDataRepository.data(for: widget, inProject: projectID))
            ?? .unavailable("That widget could not be read.")
    }

    @discardableResult
    public func createDashboard(named name: String, withStarterWidgets starter: Bool = true) -> String? {
        guard let projectID = currentProjectID else { return nil }
        var created: String?
        perform {
            let dashboard = starter
                ? try dashboardRepository.createStarter(inProject: projectID, named: name)
                : try dashboardRepository.create(inProject: projectID, named: name)
            created = dashboard.id
            reloadSnapshot()
        }
        return created
    }

    public func renameDashboard(_ dashboardID: String, to name: String) {
        perform {
            try dashboardRepository.rename(dashboardID, to: name)
            reloadSnapshot()
        }
    }

    public func deleteDashboard(_ dashboardID: String) {
        perform {
            try dashboardRepository.delete(dashboardID)
            reloadSnapshot()
        }
    }

    public func addWidget(
        _ kind: DashboardWidgetKind,
        to dashboardID: String,
        title: String = "",
        query: String = "",
        config: DashboardWidgetConfig = DashboardWidgetConfig()
    ) {
        perform {
            try dashboardRepository.addWidget(
                to: dashboardID, kind: kind, title: title, query: query, config: config
            )
            dashboardRevision += 1
        }
    }

    public func updateWidget(_ widget: DashboardWidget) {
        perform {
            try dashboardRepository.update(widget)
            dashboardRevision += 1
        }
    }

    public func removeWidget(_ widgetID: String) {
        perform {
            try dashboardRepository.removeWidget(widgetID)
            dashboardRevision += 1
        }
    }

    /// Saves the arrangement after a drag.
    public func moveWidget(on dashboardID: String, from source: Int, to destination: Int, columns: Int) {
        perform {
            let current = try dashboardRepository.widgets(on: dashboardID)
            let reordered = DashboardLayout.reorder(current, from: source, to: destination)
            try dashboardRepository.saveLayout(reordered, columns: columns)
            dashboardRevision += 1
        }
    }

    public func resizeWidget(_ widget: DashboardWidget, on dashboardID: String, width: Int, height: Int, columns: Int) {
        perform {
            var widgets = try dashboardRepository.widgets(on: dashboardID)
            guard let index = widgets.firstIndex(where: { $0.id == widget.id }) else { return }
            widgets[index].width = max(1, width)
            widgets[index].height = max(1, height)
            try dashboardRepository.update(widgets[index])
            try dashboardRepository.saveLayout(widgets, columns: columns)
            dashboardRevision += 1
        }
    }

    // MARK: - The fields that work themselves out

    public func computedValue(_ fieldID: String, for taskID: String) -> FormulaValue {
        computedValues[taskID]?[fieldID] ?? .empty
    }

    /// How a field reads on a card, whichever kind it is.
    ///
    /// One place rather than one per view, because a money field shown with
    /// its currency on the card and without it in the table is a bug nobody
    /// notices until they are reconciling the two.
    public func display(_ field: CustomField, for task: BoardTask) -> String {
        if field.kind.isComputed || (field.kind == .progress && field.progressMode != .manual) {
            let value = computedValue(field.id, for: task.id)
            if case .number(let number) = value, field.kind == .progress {
                return "\(Int(number.rounded()))%"
            }
            return value.display(currency: field.kind == .money ? field.currency : "")
        }

        guard let value = customValues(for: task)[field.id] else { return "" }
        switch field.kind {
        case .money:
            guard case .number(let amount) = value else { return "" }
            return FormulaValue.number(amount).display(currency: field.currency)
        case .rating:
            guard case .number(let stars) = value else { return "" }
            return String(repeating: "★", count: min(max(Int(stars), 0), 5))
        case .progress:
            guard case .number(let percent) = value else { return "" }
            return "\(Int(percent.rounded()))%"
        case .relationship:
            let ids = RelationshipValue.ids(from: value)
            return ids.count == 1 ? "1 card" : "\(ids.count) cards"
        default:
            return value.display()
        }
    }

    /// The cards a relationship field points at, as cards rather than ids.
    public func relatedTasks(_ field: CustomField, for task: BoardTask) -> [BoardTask] {
        let ids = RelationshipValue.ids(from: customValues(for: task)[field.id])
        guard !ids.isEmpty else { return [] }
        return ids.compactMap { id in try? taskRepository.task(id: id) }
    }

    /// The cards a relationship field is allowed to point at.
    public func relationshipChoices(for field: CustomField) -> [BoardTask] {
        guard let projectID = currentProjectID else { return [] }
        let all = (try? taskRepository.tasks(matching: "not is:trashed", inProject: projectID)) ?? []
        guard let listID = field.targetListID else { return all }
        return all.filter { $0.listID == listID }
    }

    public func setRelated(_ ids: [String], field: CustomField, on taskID: String) {
        perform {
            try customFieldRepository.setValue(
                RelationshipValue.stored(ids), forField: field.id, onTask: taskID
            )
            reloadSnapshot()
        }
    }

    public func createCustomField(
        named name: String,
        kind: CustomFieldKind,
        options: [String] = [],
        currency: String,
        progressMode: ProgressMode,
        targetListID: String?,
        formula: String,
        rollupSource: RollupSource,
        rollupLinkID: String?,
        rollupFieldID: String?,
        rollupFunction: RollupFunction
    ) {
        guard let projectID = currentProjectID else { return }
        perform {
            try customFieldRepository.create(
                inProject: projectID, name: name, kind: kind, options: options,
                currency: currency, progressMode: progressMode, targetListID: targetListID,
                formula: formula, rollupSource: rollupSource, rollupLinkID: rollupLinkID,
                rollupFieldID: rollupFieldID, rollupFunction: rollupFunction
            )
            reloadSnapshot()
        }
    }

    public func setFormula(_ formula: String, for fieldID: String) {
        perform {
            try customFieldRepository.setFormula(formula, for: fieldID)
            reloadSnapshot()
        }
    }

    /// Tries a formula against a real card before it is saved.
    public func previewFormula(_ formula: String, on taskID: String) -> String {
        guard let projectID = currentProjectID else { return "" }
        guard let result = try? computedFieldRepository.preview(
            formula: formula, forTask: taskID, inProject: projectID
        ) else { return "" }

        switch result {
        case .success(let value):
            return value.isEmpty ? "blank" : value.display()
        case .failure(let error):
            return error.message
        }
    }

    // MARK: - Time

    public func timesheet(for week: TimesheetWeek, personID: String? = nil) -> Timesheet {
        guard let projectID = currentProjectID else {
            return Timesheet(week: week, rows: [])
        }
        return (try? timeRepository.timesheet(inProject: projectID, week: week, personID: personID))
            ?? Timesheet(week: week, rows: [])
    }

    public func setTimesheetCell(_ minutes: Int, task taskID: String, day: Date, personID: String?) {
        perform {
            try timeRepository.setMinutes(minutes, onTask: taskID, day: day, personID: personID)
            timeRevision += 1
            loadSelectionDetails()
        }
    }

    public func setBillable(_ billable: Bool, entry entryID: String) {
        perform {
            try timeRepository.setBillable(billable, for: entryID)
            timeRevision += 1
            loadSelectionDetails()
        }
    }

    public func timeInStatus(forTask taskID: String) -> [TimeInStatus] {
        (try? timeRepository.timeInStatus(forTask: taskID)) ?? []
    }

    public func timeInStatusReport() -> [TimeInStatusSummary] {
        guard let projectID = currentProjectID else { return [] }
        return (try? timeRepository.timeInStatus(inProject: projectID)) ?? []
    }

    /// A status's name, for the report. A column that has since been deleted
    /// still has time against it, and saying so beats a blank row.
    public func statusName(id: String) -> String {
        if let column = snapshot?.columns.first(where: { $0.status.id == id }) {
            return column.status.name
        }
        return "A column since removed"
    }
}
