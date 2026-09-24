import Foundation

/// stdout/stderr helpers. Nothing here writes to the diagnostics folder — the
/// CLI's own output is the user's terminal, not a log file.
enum Output {
    static func line(_ text: String = "") {
        print(text)
    }

    static func error(_ text: String) {
        FileHandle.standardError.write(Data("localboard: \(text)\n".utf8))
    }

    /// Renders rows as an aligned table. Used by `localboard list`.
    static func table(headers: [String], rows: [[String]]) {
        guard !rows.isEmpty else { return }
        let columnCount = headers.count
        var widths = headers.map { $0.count }

        for row in rows {
            for index in 0..<min(columnCount, row.count) {
                widths[index] = max(widths[index], row[index].count)
            }
        }

        func render(_ cells: [String]) -> String {
            (0..<columnCount).map { index in
                let cell = index < cells.count ? cells[index] : ""
                let padding = max(0, widths[index] - cell.count)
                return index == columnCount - 1 ? cell : cell + String(repeating: " ", count: padding)
            }
            .joined(separator: "  ")
        }

        line(render(headers))
        line((0..<columnCount).map { String(repeating: "-", count: widths[$0]) }.joined(separator: "  "))
        for row in rows { line(render(row)) }
    }
}

enum ExitStatus {
    static let success: Int32 = 0
    static let failure: Int32 = 1
    static let usage: Int32 = 2
}
