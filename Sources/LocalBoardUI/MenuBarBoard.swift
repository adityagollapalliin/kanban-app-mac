import SwiftUI
import LocalBoardCore
import LocalBoardStore

/// What is due today, in the menu bar.
///
/// Read-only apart from opening a card. A menu bar extra is glanced at, not
/// worked in, and a control you can hit by accident while reaching for the
/// clock is a control that should not change anything.
struct MenuBarBoard: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openWindow) private var openWindow

    private var model: BoardViewModel? { environment.board }

    var body: some View {
        if let model {
            let due = model.dueToday()

            Group {
                if due.isEmpty {
                    Text("Nothing due today")
                } else {
                    ForEach(due.prefix(12)) { task in
                        Button("\(model.tag(for: task))  \(task.title)") {
                            openWindow(id: TaskWindow.identifier, value: task.id)
                        }
                    }
                    if due.count > 12 {
                        Text("and \(due.count - 12) more")
                    }
                }

                if let timed = model.timedTask {
                    Divider()
                    Text("Timing \(model.tag(for: timed))")
                    Button("Stop Timer") { model.stopTimer() }
                }

                Divider()

                Button("Open \(AppIdentity.displayName)") {
                    NSApp.activate(ignoringOtherApps: true)
                    for window in NSApp.windows where window.canBecomeMain {
                        window.makeKeyAndOrderFront(nil)
                        break
                    }
                }
                Button("Quit") { NSApp.terminate(nil) }
            }
        } else {
            Text("Opening…")
        }
    }
}

/// What the menu bar shows when it is not open: the count, so the icon carries
/// the one number worth knowing without clicking anything.
struct MenuBarLabel: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let count = environment.board?.dueToday().count ?? 0
        Label(count > 0 ? "\(count)" : "", systemImage: "checklist")
            .labelStyle(.titleAndIcon)
    }
}
