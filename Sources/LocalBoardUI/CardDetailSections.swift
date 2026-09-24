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
                Spacer(minLength: 0)
            }

            Text(comment.bodyMarkdown)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .contextMenu {
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

            if let person = model.person(id: entry.personID) {
                Text(CardAppearance.initials(of: person.name))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(person.name)
            }
        }
        .contextMenu {
            Button("Delete", systemImage: "trash", role: .destructive) {
                model.deleteWorkLog(entry.id)
            }
        }
    }

    private func log() {
        guard let minutes = WorkLogSection.minutes(from: amount) else { return }
        model.logWork(minutes: minutes, note: note, on: day, taskID: task.id)
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
