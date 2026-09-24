import Foundation
import LocalBoardCore

/// A project's optional link to a checkout on this Mac.
///
/// Three constraints shape everything here, and they are not negotiable:
///
///  * **No network.** Nothing is fetched. What is shown is what is already on
///    disk, which means the branches this Mac knows about and the commits it
///    has already made.
///  * **No subprocess.** `Scripts/verify-no-network.sh` bans `Process(`
///    outright, so `git` is never run. The files are read directly.
///  * **Read only.** Nothing here writes into the repository, ever.
///
/// That rules out reading commit objects, which are zlib-compressed and would
/// need a decompressor and a pack-file reader to walk properly. What it leaves
/// is genuinely useful and completely honest: branch names, which live as
/// plain text in `refs/heads` and `packed-refs`, and recent commit subjects,
/// which the reflog records in plain text in `logs/HEAD`. A card's key found
/// in either is a real reference to it.
public struct RepositoryLinkRepository {

    let database: Database
    private let clock: any ClockProvider

    public init(database: Database, clock: any ClockProvider = SystemClock()) {
        self.database = database
        self.clock = clock
    }

    public func link(forProject projectID: String) throws -> RepositoryLink? {
        try database.queryOne(
            "SELECT * FROM project_repository WHERE project_id = ?;", [projectID]
        ).map(RepositoryLink.init(row:))
    }

    /// Records the folder the user chose, with the bookmark that is the
    /// sandbox's record of them having chosen it. Without the bookmark the
    /// path is a string the app has no right to open, so it is stored too.
    public func setLink(projectID: String, path: String, bookmark: Data?) throws {
        try database.execute(
            """
            INSERT INTO project_repository (project_id, path, bookmark, linked_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT (project_id) DO UPDATE SET path = ?, bookmark = ?, linked_at = ?;
            """,
            [projectID, path, bookmark.sqlValue, clock.now, path, bookmark.sqlValue, clock.now]
        )
    }

    public func removeLink(forProject projectID: String) throws {
        try database.execute("DELETE FROM project_repository WHERE project_id = ?;", [projectID])
    }
}

/// What a checkout can be asked, without running anything.
public enum GitReferences {

    /// A branch or commit that names a card.
    public struct Reference: Sendable, Equatable, Identifiable, Hashable {
        public enum Kind: String, Sendable, Codable { case branch, commit }

        public let kind: Kind
        /// The branch name, or the commit's subject line.
        public let text: String
        public let key: String

        public var id: String { "\(kind.rawValue):\(text)" }

        public init(kind: Kind, text: String, key: String) {
            self.kind = kind
            self.text = text
            self.key = key
        }
    }

    /// Everything in the checkout that mentions one of `keys`.
    ///
    /// `url` must already be accessible — the caller starts and stops the
    /// security-scoped access around this, because only the caller knows how
    /// long it needs it for.
    public static func references(in url: URL, matching keys: [String]) -> [Reference] {
        guard !keys.isEmpty else { return [] }
        let git = gitDirectory(for: url)

        var found: [Reference] = []
        var seen: Set<String> = []

        func note(_ kind: Reference.Kind, _ text: String) {
            guard let key = firstKey(in: text, from: keys) else { return }
            let reference = Reference(kind: kind, text: text, key: key)
            if seen.insert(reference.id).inserted { found.append(reference) }
        }

        for branch in branches(in: git) { note(.branch, branch) }
        for subject in recentCommitSubjects(in: git) { note(.commit, subject) }

        return found
    }

    /// `.git` is usually a directory. In a worktree or a submodule it is a
    /// file containing `gitdir: <path>`, and following that is the difference
    /// between working everywhere and working only in the simple case.
    static func gitDirectory(for url: URL) -> URL {
        let candidate = url.appending(path: ".git")
        var isDirectory: ObjCBool = false

        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
            // Perhaps the user picked the .git directory itself, or a bare repo.
            return url
        }
        if isDirectory.boolValue { return candidate }

        guard let contents = try? String(contentsOf: candidate, encoding: .utf8),
              let line = contents.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") })
        else { return candidate }

        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        return path.hasPrefix("/")
            ? URL(filePath: path)
            : url.appending(path: path).standardizedFileURL
    }

    /// Loose refs under `refs/heads`, plus whatever `packed-refs` holds.
    ///
    /// Both are needed: git moves refs into `packed-refs` when there are many
    /// of them, and a repository that has been packed would otherwise appear
    /// to have no branches at all.
    static func branches(in git: URL) -> [String] {
        var names: Set<String> = []
        let heads = git.appending(path: "refs/heads")

        if let enumerator = FileManager.default.enumerator(
            at: heads, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) {
            for case let file as URL in enumerator {
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                else { continue }
                let relative = file.path.replacingOccurrences(of: heads.path + "/", with: "")
                if !relative.isEmpty { names.insert(relative) }
            }
        }

        if let packed = try? String(contentsOf: git.appending(path: "packed-refs"), encoding: .utf8) {
            for line in packed.split(separator: "\n") {
                guard !line.hasPrefix("#"), !line.hasPrefix("^") else { continue }
                let parts = line.split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let ref = parts[1].trimmingCharacters(in: .whitespaces)
                guard ref.hasPrefix("refs/heads/") else { continue }
                names.insert(String(ref.dropFirst("refs/heads/".count)))
            }
        }

        return names.sorted()
    }

    /// Commit subjects from the reflog, newest first.
    ///
    /// The reflog is where git writes, in plain text, what each move of HEAD
    /// was: `commit: Fix the thing`. It is local and it is not exhaustive —
    /// it expires, and it only knows what this checkout did — but reading it
    /// needs no decompression and no subprocess, which is the trade being made.
    static func recentCommitSubjects(in git: URL, limit: Int = 300) -> [String] {
        guard let log = try? String(contentsOf: git.appending(path: "logs/HEAD"), encoding: .utf8)
        else { return [] }

        var subjects: [String] = []
        var seen: Set<String> = []

        for line in log.split(separator: "\n").reversed() {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let message = String(line[line.index(after: tab)...])

            // `commit: subject`, `commit (amend): subject`, `commit (initial): subject`.
            guard let colon = message.firstIndex(of: ":"), message.hasPrefix("commit") else { continue }
            let subject = message[message.index(after: colon)...].trimmingCharacters(in: .whitespaces)

            guard !subject.isEmpty, seen.insert(subject).inserted else { continue }
            subjects.append(subject)
            if subjects.count >= limit { break }
        }
        return subjects
    }

    /// The first card key mentioned, matched on a word boundary so that
    /// WORK-1 does not claim a branch about WORK-14.
    static func firstKey(in text: String, from keys: [String]) -> String? {
        let upper = text.uppercased()
        return keys.first { key in
            let needle = key.uppercased()
            guard let range = upper.range(of: needle) else { return false }
            // The character after the key must not continue the number.
            guard range.upperBound < upper.endIndex else { return true }
            return !upper[range.upperBound].isNumber
        }
    }
}
