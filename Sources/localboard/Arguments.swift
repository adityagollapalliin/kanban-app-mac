import Foundation

/// A tiny, dependency-free argument parser.
///
/// Deliberately not `swift-argument-parser`: the brief allows zero third-party
/// dependencies, and the surface here is small enough that hand-parsing is
/// cheaper than the justification would be.
struct Arguments {
    private(set) var positional: [String] = []
    private var options: [String: String] = [:]
    private var flags: Set<String> = []

    init(_ raw: [String]) {
        var index = 0
        while index < raw.count {
            let argument = raw[index]
            if argument.hasPrefix("--") {
                let name = String(argument.dropFirst(2))
                // `--key value` and `--key=value` both work.
                if let equals = name.firstIndex(of: "=") {
                    options[String(name[name.startIndex..<equals])] = String(name[name.index(after: equals)...])
                } else if index + 1 < raw.count, !raw[index + 1].hasPrefix("--") {
                    options[name] = raw[index + 1]
                    index += 1
                } else {
                    flags.insert(name)
                }
            } else {
                positional.append(argument)
            }
            index += 1
        }
    }

    func option(_ name: String) -> String? { options[name] }
    func flag(_ name: String) -> Bool { flags.contains(name) }

    var subcommand: String? { positional.first }
    var remainder: [String] { Array(positional.dropFirst()) }
}
