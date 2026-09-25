import AppKit
import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// The conversation on a card.
///
/// Oldest first, because a thread is read forwards. The box to write in sits
/// at the bottom where the thread ends, rather than at the top where it would
/// push what has already been said out of the way.
struct CommentsSection: View {

    let task: BoardTask
    let model: BoardViewModel

    @State private var draft = ""
    @State private var editingID: String?
    @State private var editingBody = ""

    var body: some View {
        Section("Comments") {
            ForEach(model.comments) { comment in
                if editingID == comment.id {
                    editor(comment)
                } else {
                    row(comment)
                }
            }

            TextField("Add a comment", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .onSubmit(post)

            if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Post", action: post)
            }
        }
    }

    private func row(_ comment: Comment) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                // A request is ticked off where it was made. Moving it
                // somewhere else would separate the ask from what was said
                // around it, which is usually the part that explains it.
                if comment.isActionItem {
                    Button {
                        model.setActionDone(!comment.actionDone, for: comment.id)
                    } label: {
                        Image(systemName: comment.actionDone ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(comment.actionDone ? Color.accentColor : .orange)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(comment.actionDone ? "Mark as not done" : "Mark as done")
                }

                Text(model.person(id: comment.authorID)?.name ?? "Someone")
                    .font(.caption.weight(.medium))
                Text(comment.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                // An edited remark says so rather than quietly appearing
                // always to have said this.
                if comment.editedAt != nil {
                    Text("edited")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if comment.isActionItem, let assignee = model.person(id: comment.actionAssigneeID) {
                    Label(assignee.name, systemImage: "person")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                Spacer(minLength: 0)
            }

            Text(comment.bodyMarkdown)
                .font(.callout)
                .textSelection(.enabled)
                .strikethrough(comment.actionDone)
                .foregroundStyle(comment.actionDone ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .contextMenu {
            if comment.isActionItem {
                Button("Not a Request After All", systemImage: "checkmark.bubble") {
                    model.setActionItem(false, assignee: nil, for: comment.id)
                }
            } else {
                Menu("Make This a Request") {
                    Button("Anybody") { model.setActionItem(true, assignee: nil, for: comment.id) }
                    ForEach(model.people) { person in
                        Button(person.name) {
                            model.setActionItem(true, assignee: person.id, for: comment.id)
                        }
                    }
                }
            }

            Button("Edit…") {
                editingBody = comment.bodyMarkdown
                editingID = comment.id
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                model.deleteComment(comment.id)
            }
        }
    }

    private func editor(_ comment: Comment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Comment", text: $editingBody, axis: .vertical)
                .lineLimit(1...6)

            HStack {
                Spacer()
                Button("Cancel") { editingID = nil }
                Button("Save") {
                    model.editComment(comment.id, body: editingBody)
                    editingID = nil
                }
            }
            .font(.caption)
        }
    }

    private func post() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.addComment(trimmed, to: task.id)
        draft = ""
    }
}

/// Files kept with a card.
struct AttachmentsSection: View {

    let task: BoardTask
    let model: BoardViewModel

    var body: some View {
        Section("Attachments") {
            ForEach(model.attachments) { attachment in
                row(attachment)
            }

            Button("Attach a File…", systemImage: "paperclip") {
                model.attachFile(to: task.id)
            }

            if !model.attachments.isEmpty {
                Text("Copies, not links. Moving or deleting the original afterwards is harmless.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ attachment: Attachment) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(size(attachment.byteSize))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { reveal(attachment) }
        .help("Show in Finder")
        .contextMenu {
            Button("Show in Finder", systemImage: "folder") { reveal(attachment) }
            Button("Remove", systemImage: "trash", role: .destructive) {
                model.removeAttachment(attachment.id)
            }
        }
    }

    /// Revealing rather than opening: the app has no business deciding which
    /// program should handle someone's file.
    private func reveal(_ attachment: Attachment) {
        guard let url = model.url(of: attachment) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// How this card relates to others.
struct LinksSection: View {

    let task: BoardTask
    let model: BoardViewModel

    @State private var kind: LinkKind = .blocks
    @State private var otherID: String?

    var body: some View {
        Section("Links") {
            ForEach(model.links, id: \.link.id) { entry in
                row(entry)
            }

            HStack(spacing: 6) {
                Picker("", selection: $kind) {
                    ForEach(LinkKind.offered, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                .labelsHidden()

                Picker("", selection: $otherID) {
                    Text("Pick a card").tag(String?.none)
                    ForEach(candidates) { candidate in
                        Text(model.tag(for: candidate)).tag(String?.some(candidate.id))
                    }
                }
                .labelsHidden()

                Button("Link") {
                    if let otherID { model.link(task.id, kind, to: otherID) }
                    otherID = nil
                }
                .disabled(otherID == nil)
            }
        }
    }

    private func row(_ entry: (link: TaskLink, kind: LinkKind, otherID: String)) -> some View {
        HStack(spacing: 8) {
            Image(systemName: entry.kind.symbol)
                .font(.caption)
                .foregroundStyle(entry.kind == .blockedBy ? .orange : .secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.kind.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let other = model.task(id: entry.otherID) {
                    Text("\(model.tag(for: other)) \(other.title)")
                        .font(.callout)
                        .lineLimit(1)
                } else {
                    // Linked to something not on this board — another
                    // project's card, or one in the trash.
                    Text("A card not on this board")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if model.task(id: entry.otherID) != nil { model.selectedTaskID = entry.otherID }
        }
        .contextMenu {
            Button("Unlink", systemImage: "link.badge.plus", role: .destructive) {
                model.unlink(entry.link.id)
            }
        }
    }

    /// Everything on the board except this card and the ones already linked,
    /// so the picker never offers a link that already exists.
    private var candidates: [BoardTask] {
        let taken = Set(model.links.map(\.otherID) + [task.id])
        return (model.snapshot?.columns.flatMap(\.tasks) ?? []).filter { !taken.contains($0.id) }
    }
}

/// Time spent on a card.
struct WorkLogSection: View {

    let task: BoardTask
    let model: BoardViewModel

    @State private var amount = ""
    @State private var note = ""
    @State private var day = Date()
    @State private var billable = false

    var body: some View {
        Section("Time") {
            if model.loggedMinutes > 0 {
                LabeledContent("Logged") {
                    Text(WorkLogEntry(
                        id: "", taskID: "", personID: nil,
                        minutes: model.loggedMinutes, workedOn: .now, createdAt: .now
                    ).duration)
                    .monospacedDigit()
                }
                if model.billableMinutes > 0 {
                    LabeledContent("Billable") {
                        Text(DurationFormat.short(model.billableMinutes))
                            .monospacedDigit()
                            .foregroundStyle(.green)
                    }
                }
            }

            ForEach(model.workLog) { entry in
                row(entry)
            }

            HStack(spacing: 6) {
                // `1h 30m`, `90m`, `1.5h` — people write time in whichever of
                // those is in their head, so all three are read.
                TextField("1h 30m", text: $amount)
                    .frame(width: 80)
                DatePicker("", selection: $day, displayedComponents: .date)
                    .labelsHidden()
                Button("Log", action: log)
                    .disabled(WorkLogSection.minutes(from: amount) == nil)
            }

            TextField("What you did (optional)", text: $note)

            // Off by default: time logged before anybody was asked the
            // question is not billable, and a tick nobody chose would put
            // figures on an invoice that nobody stands behind.
            Toggle("Billable", isOn: $billable)
                .toggleStyle(.checkbox)

            TimeInStatusSummarySection(task: task, model: model)
        }
    }

    private func row(_ entry: WorkLogEntry) -> some View {
        HStack(spacing: 8) {
            Text(entry.duration)
                .font(.callout.monospacedDigit())
                .frame(width: 60, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.workedOn.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if !entry.note.isEmpty {
                    Text(entry.note)
                        .font(.caption)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            if entry.billable {
                Image(systemName: "dollarsign.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .help("Billable")
            }

            if let person = model.person(id: entry.personID) {
                Text(CardAppearance.initials(of: person.name))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(person.name)
            }
        }
        .contextMenu {
            Button(entry.billable ? "Not billable" : "Billable") {
                model.setBillable(!entry.billable, entry: entry.id)
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                model.deleteWorkLog(entry.id)
            }
        }
    }

    private func log() {
        guard let minutes = WorkLogSection.minutes(from: amount) else { return }
        model.logWork(minutes: minutes, note: note, on: day, taskID: task.id, billable: billable)
        amount = ""
        note = ""
    }

    /// Reads `1h 30m`, `90m`, `1.5h`, `2h` or a bare number of minutes.
    ///
    /// Bare numbers are minutes rather than hours: `30` far more often means
    /// half an hour than thirty hours, and the ambiguous case is the one worth
    /// getting right.
    static func minutes(from text: String) -> Int? {
        let lowered = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard !lowered.isEmpty else { return nil }

        if let bare = Double(lowered) {
            let rounded = Int(bare.rounded())
            return rounded > 0 ? rounded : nil
        }

        var total = 0.0
        var matched = false
        var number = ""

        for character in lowered {
            if character.isNumber || character == "." {
                number.append(character)
            } else if character == "h", let value = Double(number) {
                total += value * 60
                number = ""
                matched = true
            } else if character == "m", let value = Double(number) {
                total += value
                number = ""
                matched = true
            } else if character.isWhitespace {
                continue
            } else {
                return nil
            }
        }

        // A trailing number with no unit after an hour is minutes: `1h 30`.
        if let leftover = Double(number), matched { total += leftover }

        let rounded = Int(total.rounded())
        return matched && rounded > 0 ? rounded : nil
    }
}


/// How long this card has sat in each column.
///
/// On the card rather than only in the report, because the question "why has
/// this been open for three weeks" is asked about one card at a time.
struct TimeInStatusSummarySection: View {

    let task: BoardTask
    let model: BoardViewModel

    private var report: [TimeInStatus] { model.timeInStatus(forTask: task.id) }

    var body: some View {
        let report = report
        if report.count > 1 {
            DisclosureGroup("Time in each column") {
                ForEach(report) { entry in
                    HStack {
                        Text(model.statusName(id: entry.statusID))
                            .font(.caption)
                        if entry.visits > 1 {
                            // Two visits to the same column is work coming
                            // back, which the total alone would hide.
                            Text("×\(entry.visits)")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .help("Came back here \(entry.visits) times")
                        }
                        Spacer()
                        Text(entry.description)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
