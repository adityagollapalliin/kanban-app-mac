import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// The project's releases and how far through each one is.
///
/// Progress is reported two ways because the two disagree, and which of them a
/// team believes is not something this can decide for them: half the cards
/// done can easily be a quarter of the work.
struct ReleasesView: View {

    let model: BoardViewModel

    @State private var isAdding = false
    @State private var newName = ""
    @State private var newDate = Date()
    @State private var hasDate = false

    var body: some View {
        VStack(spacing: 0) {
            header

            if model.versions.isEmpty {
                ContentUnavailableView(
                    "No releases yet",
                    systemImage: "shippingbox",
                    description: Text("A release is a name to ship work under, and a date to ship it on.")
                )
            } else {
                List {
                    ForEach(model.versions) { version in
                        row(version)
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Releases")
        .sheet(isPresented: $isAdding) { addSheet }
    }

    private var header: some View {
        HStack {
            Text("Releases")
                .font(.headline)
            Spacer()
            Button("New Release…", systemImage: "plus") {
                newName = ""
                hasDate = false
                newDate = Date()
                isAdding = true
            }
            .buttonStyle(.link)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func row(_ version: Version) -> some View {
        let progress = model.progress(ofVersion: version.id)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: version.released ? "shippingbox.fill" : "shippingbox")
                    .foregroundStyle(version.released ? .green : .secondary)

                Text(version.name)
                    .font(.headline)

                if version.released {
                    Text("Released")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.green.opacity(0.18), in: Capsule())
                }

                Spacer()

                if let date = version.releaseDate {
                    Label(date.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(isLate(version) ? .red : .secondary)
                }
            }

            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)

            HStack(spacing: 12) {
                Text("\(progress.done) of \(progress.total) cards")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                if progress.points > 0 {
                    Text(pointsSummary(progress))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                // The thing worth noticing about a shipped release.
                if version.released, progress.remaining > 0 {
                    Label("\(progress.remaining) unfinished", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("Released with work still open. That is a fact worth seeing, not an error.")
                }

                Spacer()
            }
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button(version.released ? "Mark as Unreleased" : "Mark as Released") {
                model.setVersionReleased(!version.released, for: version.id)
            }
            Button("Filter the Board by This") {
                model.queryText = "version = \"\(version.name)\""
            }
            Divider()
            Button("Delete Release", systemImage: "trash", role: .destructive) {
                model.deleteVersion(version.id)
            }
        }
    }

    private func pointsSummary(_ progress: ReleaseProgress) -> String {
        let format = FloatingPointFormatStyle<Double>().precision(.fractionLength(0...1))
        return "\(progress.donePoints.formatted(format)) of \(progress.points.formatted(format)) points"
    }

    private func isLate(_ version: Version) -> Bool {
        guard let date = version.releaseDate, !version.released else { return false }
        return date < Date()
    }

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New release")
                .font(.headline)

            TextField("Name, like 1.0", text: $newName)
                .textFieldStyle(.roundedBorder)

            Toggle("Release date", isOn: $hasDate)
            if hasDate {
                DatePicker("Ship on", selection: $newDate, displayedComponents: .date)
                    .datePickerStyle(.field)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { isAdding = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    model.createVersion(named: newName, releaseDate: hasDate ? newDate : nil)
                    isAdding = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
