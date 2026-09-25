import Foundation
import LocalBoardCore
import LocalBoardStore

/// Milestone 8.5a: the words a project uses, and the three facts about a card
/// that go with them.
extension BoardViewModel {

    // MARK: - Reading the vocabulary

    /// The kind of card this is, as the project defines it.
    ///
    /// Looked up by the card's raw code rather than by the built-in
    /// enumeration, because a project can define its own kinds and the
    /// enumeration reads those as ordinary work. Showing the enumeration would
    /// call an Initiative a Task.
    public func issueType(for task: BoardTask) -> IssueType? {
        issueTypes.first { $0.code == task.typeCode }
    }

    public func typeName(for task: BoardTask) -> String {
        issueType(for: task)?.name ?? CardAppearance.label(forType: task.type)
    }

    public func typeSymbol(for task: BoardTask) -> String {
        let symbol = issueType(for: task)?.symbol ?? ""
        return symbol.isEmpty ? CardAppearance.symbol(forType: task.type) : symbol
    }

    public func priorityName(for task: BoardTask) -> String {
        priorityValues.first { $0.code == task.priority.rawValue }?.name
            ?? CardAppearance.label(forPriority: task.priority)
    }

    /// How a link reads from the end you are standing on.
    public func linkLabel(_ kind: LinkKind, outward: Bool) -> String {
        // The stored pair, when there is one. Codes 1 and 4 are the old
        // inverse-only spellings, which are the inward halves of their pairs.
        if let pair = linkTypes.first(where: { $0.code == kind.rawValue }) {
            return pair.label(outward: outward)
        }
        if let pair = linkTypes.first(where: { $0.code == kind.inverse.rawValue }) {
            return pair.label(outward: !outward)
        }
        return kind.label
    }

    // MARK: - Editing the vocabulary

    public func addIssueType(named name: String, symbol: String, level: Int) {
        guard let projectID = currentProjectID else { return }
        perform {
            try vocabularyRepository.addIssueType(
                inProject: projectID, name: name, symbol: symbol, level: level
            )
            reloadSnapshot()
        }
    }

    public func updateIssueType(_ type: IssueType) {
        perform {
            try vocabularyRepository.updateIssueType(type)
            reloadSnapshot()
        }
    }

    public func deleteIssueType(_ type: IssueType) {
        guard let projectID = currentProjectID else { return }
        perform {
            try vocabularyRepository.deleteIssueType(code: type.code, inProject: projectID)
            reloadSnapshot()
        }
    }

    public func updatePriority(_ value: PriorityValue) {
        perform {
            try vocabularyRepository.updatePriority(value)
            reloadSnapshot()
        }
    }

    public func addLinkType(outward: String, inward: String) {
        guard let projectID = currentProjectID else { return }
        perform {
            try vocabularyRepository.addLinkType(
                inProject: projectID, outward: outward, inward: inward
            )
            reloadSnapshot()
        }
    }

    public func updateLinkType(_ type: LinkType) {
        perform {
            try vocabularyRepository.updateLinkType(type)
            reloadSnapshot()
        }
    }

    public func addResolution(named name: String) {
        guard let projectID = currentProjectID else { return }
        perform {
            try vocabularyRepository.addResolution(inProject: projectID, name: name)
            reloadSnapshot()
        }
    }

    public func setDefaultResolution(_ resolutionID: String) {
        perform {
            try vocabularyRepository.setDefaultResolution(resolutionID)
            reloadSnapshot()
        }
    }

    public func renameResolution(_ resolutionID: String, to name: String) {
        perform {
            try vocabularyRepository.renameResolution(resolutionID, to: name)
            reloadSnapshot()
        }
    }

    public func deleteResolution(_ resolutionID: String) {
        perform {
            try vocabularyRepository.deleteResolution(resolutionID)
            reloadSnapshot()
        }
    }

    // MARK: - Resolution on a card

    public func resolution(for task: BoardTask) -> Resolution? {
        guard let id = task.resolutionID else { return nil }
        return resolutions.first { $0.id == id }
    }

    public func setResolution(_ resolutionID: String?, on taskID: String) {
        perform {
            try componentRepository.setResolution(resolutionID, forTask: taskID)
            reloadSnapshot()
        }
    }

    // MARK: - Components

    public func components(for task: BoardTask) -> [Component] {
        componentsByTask[task.id] ?? []
    }

    public func createComponent(named name: String, defaultAssigneeID: String?) {
        guard let projectID = currentProjectID else { return }
        perform {
            try componentRepository.create(
                inProject: projectID, name: name, defaultAssigneeID: defaultAssigneeID
            )
            reloadSnapshot()
        }
    }

    public func updateComponent(_ component: Component) {
        perform {
            try componentRepository.update(component)
            reloadSnapshot()
        }
    }

    public func deleteComponent(_ componentID: String) {
        perform {
            try componentRepository.delete(componentID)
            reloadSnapshot()
        }
    }

    public func addComponent(_ componentID: String, to taskID: String) {
        perform {
            try componentRepository.add(componentID, toTask: taskID)
            reloadSnapshot()
        }
    }

    public func removeComponent(_ componentID: String, from taskID: String) {
        perform {
            try componentRepository.remove(componentID, fromTask: taskID)
            reloadSnapshot()
        }
    }

    // MARK: - Versions on a card

    public func versions(for task: BoardTask, role: VersionRole) -> [Version] {
        (try? componentRepository.versions(forTask: task.id, role: role)) ?? []
    }

    public func addVersion(_ versionID: String, to taskID: String, as role: VersionRole) {
        perform {
            try componentRepository.add(versionID, toTask: taskID, as: role)
            reloadSnapshot()
        }
    }

    public func removeVersion(_ versionID: String, from taskID: String, as role: VersionRole) {
        perform {
            try componentRepository.remove(versionID, fromTask: taskID, as: role)
            reloadSnapshot()
        }
    }

    /// Changes what kind of card this is.
    ///
    /// The code is written straight to the column, because that column has
    /// always held a code and a project's own kinds are more codes.
    public func setIssueTypeCode(_ code: Int, on taskID: String) {
        perform {
            try taskRepository.setTypeCode(code, for: taskID)
            reloadSnapshot()
        }
    }

    // MARK: - Environment

    public func setEnvironment(_ text: String, on taskID: String) {
        perform {
            try taskRepository.setEnvironment(text, for: taskID)
            reloadSnapshot()
        }
    }

    // MARK: - Saved filters and their language

    public var starredViews: [SavedView] { savedViews.filter(\.starred) }

    public func setStarred(_ starred: Bool, for viewID: String) {
        perform {
            try savedViewRepository.setStarred(starred, for: viewID)
            reloadSnapshot()
        }
    }

    public func setColumns(_ columns: [String], for viewID: String) {
        perform {
            try savedViewRepository.setColumns(columns, for: viewID)
            reloadSnapshot()
        }
    }

    /// What converting a filter would do — asked before anything is saved.
    public func previewConversion(_ viewID: String, to syntax: QuerySyntax) -> SavedViewRepository.ConversionPreview? {
        try? savedViewRepository.previewConversion(viewID, to: syntax)
    }

    public func convert(_ viewID: String, to syntax: QuerySyntax) {
        perform {
            try savedViewRepository.convert(viewID, to: syntax)
            reloadSnapshot()
        }
    }

    public func createSavedView(named name: String, query: String, syntax: QuerySyntax) {
        guard let projectID = currentProjectID else { return }
        perform {
            try savedViewRepository.create(
                inProject: projectID, name: name, query: query, syntax: syntax
            )
            reloadSnapshot()
        }
    }

    /// The cards a saved filter matches, read in its own language.
    public func tasks(matching view: SavedView) -> [BoardTask] {
        guard let projectID = currentProjectID else { return [] }
        return (try? taskRepository.tasks(
            matching: view.query, inProject: projectID, syntax: view.syntax
        )) ?? []
    }

    /// Checks a query as it is being typed, in the language it will be saved
    /// in. Nil when it reads; the reason when it does not.
    public func problem(with query: String, syntax: QuerySyntax) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            _ = try TaskQueryParser.parse(trimmed, syntax: syntax)
            return nil
        } catch let error as QueryError {
            return error.message
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Workflow rules

    public func updateTransition(
        _ transitionID: String,
        name: String,
        screenTitle: String,
        screenFields: [FieldReference]
    ) {
        perform {
            try workflowRepository.update(
                transitionID, name: name, screenTitle: screenTitle, screenFields: screenFields
            )
            reloadSnapshot()
        }
    }

    public func setDiagramPosition(x: Double, y: Double, forStatus statusID: String) {
        perform {
            try workflowRepository.setDiagramPosition(x: x, y: y, forStatus: statusID)
        }
    }

    public func addTransitionRule(
        _ kind: TransitionRuleKind,
        to transitionID: String,
        target: String,
        value: String,
        query: String,
        syntax: QuerySyntax
    ) {
        perform {
            try transitionRuleRepository.add(
                kind, toTransition: transitionID, target: target,
                value: value, query: query, syntax: syntax
            )
            reloadSnapshot()
        }
    }

    public func removeTransitionRule(_ ruleID: String) {
        perform {
            try transitionRuleRepository.remove(ruleID)
            reloadSnapshot()
        }
    }

    /// Whether a move should be offered for this card, given its conditions.
    public func isOffered(_ transition: WorkflowTransition, for task: BoardTask) -> Bool {
        (try? transitionRuleRepository.isOffered(transition.id, forTask: task.id)) ?? true
    }

    /// Which fields a kind of card insists on and has not got.
    public func missingRequired(for task: BoardTask) -> [String] {
        (try? fieldConfigRepository.missingRequired(forTask: task.id)) ?? []
    }

    public func setFieldConfiguration(
        forType code: Int,
        field: FieldReference,
        shown: Bool,
        required: Bool,
        defaultValue: String
    ) {
        guard let projectID = currentProjectID else { return }
        perform {
            try fieldConfigRepository.set(
                inProject: projectID, forType: code, field: field,
                shown: shown, required: required, defaultValue: defaultValue
            )
            reloadSnapshot()
        }
    }

    public func fieldConfiguration(forType code: Int, field: FieldReference) -> FieldConfiguration? {
        fieldConfigs[code]?.first { $0.field == field }
    }
}
