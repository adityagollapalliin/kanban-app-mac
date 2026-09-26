# LocalBoard

A Kanban and project-management app for macOS that keeps everything on your own
Mac. No accounts, no sync, no telemetry, and **no network access of any kind** —
enforced by the operating system rather than promised by the code.

> **Status: 0.1.0, pre-release.** This is unfinished software written for one
> person's use. Read [Cautions](#cautions) before you go near it with anything
> you care about.

---

## Contents

- [What it is](#what-it-is)
- [Cautions](#cautions) ← **read this first**
  - [Before you download anything](#before-you-download-anything)
  - [Gatekeeper will refuse to open it](#gatekeeper-will-refuse-to-open-it)
  - [Your data has no safety net but yours](#your-data-has-no-safety-net-but-yours)
  - [Upgrades are one-way](#upgrades-are-one-way)
  - [What is not protected](#what-is-not-protected)
  - [Nobody has reviewed this](#nobody-has-reviewed-this)
  - [Known limits](#known-limits)
- [Requirements](#requirements)
- [Building it yourself](#building-it-yourself)
- [Where your data lives](#where-your-data-lives)
- [Backups](#backups)
- [Uninstalling](#uninstalling)
- [The command line](#the-command-line)
- [How the no-network guarantee works](#how-the-no-network-guarantee-works)
- [Project layout](#project-layout)
- [Documentation](#documentation)
- [Licence and warranty](#licence-and-warranty)

---

## What it is

A board, a backlog, and the things that grow around them once a board is
actually used: a filter language, saved views, sprints, custom fields, goals,
dashboards, time tracking, docs, whiteboards and a configurable workflow.

It is a **single-user, single-machine** application. There is no server, no
account, and no way for two people to work on the same board — not as a missing
feature, but as the shape of the thing.

**Current state:** milestone 8.5c. 767 tests. See [CHANGELOG.md](CHANGELOG.md)
for what exists and [docs/rca/open-items.md](docs/rca/open-items.md) for what
does not.

---

## Cautions

### Before you download anything

**Build it from source. Do not run a prebuilt binary of this app from anyone,
including me.**

This project publishes **no releases and no binaries**. There is no `.dmg`, no
`.pkg`, no Homebrew cask, no App Store listing. If you find a file somewhere
claiming to be LocalBoard, it did not come from here, and you have no way to
tell what is inside it.

That matters more than usual here, because:

- The app is **ad-hoc signed** (`codesign --sign -`). An ad-hoc signature
  proves the bundle has not been altered *since it was signed* — it says
  **nothing at all** about who signed it. Anybody can produce one.
- It is **not notarized**. Apple has not scanned it for malware.
- It carries no Developer ID, so there is no identity to revoke if a build
  turns out to be malicious.

Building it yourself takes one command and about a minute. Do that instead.

### Gatekeeper will refuse to open it

Because the app is ad-hoc signed and unnotarized, macOS will block it. If you
build it locally with `make install`, you will usually not see this, because
the file never received a quarantine attribute. If you move the bundle between
machines, or download it, you will.

**The honest advice: if you did not build it, do not bypass Gatekeeper to run
it.** The instructions below exist because you may legitimately need them for
*your own* build — not so you can talk yourself past a warning about someone
else's.

For a bundle you built and then moved:

```sh
xattr -d com.apple.quarantine /path/to/LocalBoard.app
```

Understand what that command does: it removes the flag macOS uses to decide
whether to check a file's provenance. Run it on something you did not build and
you have disabled the only automatic protection standing between you and it.

### Your data has no safety net but yours

There is no cloud. There is no sync. There is no account to recover from.

- **Your board exists on exactly one Mac.** If that Mac is lost, stolen, wiped
  or fails, the board is gone unless *you* had a backup.
- **Nothing is uploaded, ever** — which is the point, and is also why nothing
  can be restored from anywhere.
- Attachments are **copied into the app's container** when you attach them. If
  you delete the original afterwards, the container copy is the only one. If
  you delete the container, both are gone.

Make sure Time Machine (or your own backup) covers
`~/Library/Containers/dev.localboard.LocalBoard/`. See [Backups](#backups).

### Upgrades are one-way

The database has a schema version, currently **11**. Opening your file with a
newer build migrates it forward. **There is no migration backward.**

An older build opening a newer file will refuse to touch it rather than damage
it — you will get a "this file was written by a newer version" error. That is
deliberate and it is the safe behaviour, but it does mean:

> **Once you have opened your board with a newer build, older builds cannot
> open it again.**

The app takes an automatic copy before every migration, keeping the **last
five**, in
`~/Library/Containers/dev.localboard.LocalBoard/Data/Library/Application Support/LocalBoard/Backups/`.
Those are your route back. They are not a substitute for a real backup: five
deep is not many, and they live on the same disk as the original.

### What is not protected

- **The database is not encrypted.** `board.sqlite` is a plain SQLite file. Any
  process running as you, and anyone with your unlocked Mac, can read every
  card, comment and attachment. **Turn on FileVault** if the contents matter.
- **Attachments are stored as plain files** in the container, under their
  original names.
- **Diagnostics logs** are written locally and pruned on a schedule. They may
  contain card titles.
- There is **no passcode, no per-board lock, and no redaction**. The app's
  security model is "the account on this Mac is trusted"; it has nothing to add
  beyond that.

Do not put credentials, medical records, or anything covered by a regulatory
regime into this app without doing your own assessment first.

### Nobody has reviewed this

- Written by one person with heavy AI assistance, over a short period.
- **No external security review. No code audit. No penetration testing.**
- The test suite is large (767 tests) and the no-network property is
  mechanically verified, but tests demonstrate the absence of *known* faults,
  not the absence of faults.
- [`docs/rca/`](docs/rca/) documents twenty-five real defects found during
  development, including a use-after-free in the database layer that corrupted
  SQLite's internal state, and four features that shipped configurable and
  inert. That directory exists because this kind of thing happens; treat it as
  evidence about the general rate, not as a closed list.

### Known limits

Current as of milestone 8.5c. The fuller list is in
[docs/rca/open-items.md](docs/rca/open-items.md).

| Limit | Detail |
|---|---|
| **Apple Silicon only** | Built `arm64`. Intel Macs are not supported and are not tested. |
| **macOS 14 or later** | Uses APIs with no back-deployment. |
| **Single user, single machine** | No sync, no sharing, no multi-device. |
| **No accessibility labels on five screens** | Analytics, Sprints, Releases, Backlog and Timeline. Deliberately deferred. |
| **No global hotkey** | The in-app ⌘N works; a system-wide one would need an event tap and Accessibility permission. Deferred. |
| **Priority steps cannot be reordered** | They can be renamed and recoloured. Inserting a step is not yet allowed. |
| **The workflow diagram is uncapped** | Fine for a normal number of columns; a project with dozens would draw a great many arrows. |
| **Unfinished roadmap** | Milestone 8.5d onward — rich text, field-level history, the `localboard://` URL scheme, Quick Look previews — is not started. |

---

## Requirements

- **macOS 14.0** or later
- **Apple Silicon** (arm64)
- **Xcode 16 or later** command line tools, for a Swift 6 toolchain
- No other dependencies. The project uses **zero third-party packages**.

---

## Building it yourself

```sh
git clone https://github.com/adityagollapalliin/kanban-app-mac.git
cd kanban-app-mac

make test          # run the suite — do this first
make verify        # prove the build reaches no network
make install       # build, sign ad-hoc, install to ~/Applications
```

`make help` lists everything. The useful targets:

| Target | What it does |
|---|---|
| `make build` | Compile every target (debug) |
| `make test` | Run all 767 tests |
| `make verify` | Check that nothing reaches the network |
| `make bundle` | Assemble `LocalBoard.app` into `dist/` |
| `make install` | Bundle, then install the app and the `localboard` CLI |
| `make run` | Launch from `dist/` without installing |
| `make where` | Print the data folders |
| `make uninstall` | Remove both. **Your boards are left untouched.** |
| `make clean` | Remove build products |

**Run `make verify` yourself.** Do not take the no-network claim on trust —
the check is a shell script you can read in a couple of minutes.

---

## Where your data lives

Everything is inside the app's sandbox container:

```
~/Library/Containers/dev.localboard.LocalBoard/Data/Library/Application Support/LocalBoard/
├── board.sqlite          your boards, cards, everything
├── board.sqlite-wal      write-ahead log — part of the database, do not delete
├── board.sqlite-shm      shared memory index — likewise
├── Attachments/          copies of files you attached
├── Diagnostics/          local logs, pruned automatically
└── Backups/              automatic pre-migration copies, last five
```

`make where` prints these paths.

> **The `-wal` and `-shm` files are part of your database.** Copying only
> `board.sqlite` will silently lose everything committed since the last
> checkpoint. Copy all three, or use the app's own export.

---

## Backups

Three options, in increasing order of how much they protect you:

1. **Time Machine** covering `~/Library/Containers/dev.localboard.LocalBoard/`.
   This is the one to set up.
2. **Export a project to JSON**, either from the app or with
   `localboard export --project KEY > board.json`. Human-readable, and it
   imports back as a new project. It does **not** include attachments.
3. **Copy the whole folder** while the app is closed — all three `board.sqlite*`
   files plus `Attachments/`.

The automatic `Backups/` folder is a migration safety net, not a backup
strategy: it keeps five copies, on the same disk, and only ever updates when a
schema upgrade runs.

---

## Uninstalling

```sh
make uninstall
```

This removes the app and the CLI. **It deliberately leaves your data alone**,
so reinstalling picks up exactly where you left off.

To delete your data as well — **this cannot be undone**:

```sh
rm -rf ~/Library/Containers/dev.localboard.LocalBoard
```

Export anything you want to keep first.

---

## The command line

`localboard` is installed to `~/.local/bin` and talks to the same database as
the app. Both can be open at once — the database uses WAL journalling and a
busy timeout so they do not tread on each other.

```sh
localboard list --project TASK
localboard add "Fix the export" --project TASK
localboard list --query "priority IN (high, highest)" --syntax jql
localboard export --project TASK > backup.json
```

`localboard` with no arguments lists every command.

> **Do not edit `board.sqlite` by hand with the `sqlite3` CLI** unless you know
> exactly what you are doing. The `sqlite3` tool has **foreign keys disabled by
> default**, so a `DELETE` that the app would cascade correctly will instead
> leave orphaned rows behind. If you must, run `PRAGMA foreign_keys=ON;` first,
> and take a copy before you start.

---

## How the no-network guarantee works

Three independent layers, so no single mistake removes it:

1. **The sandbox has no network entitlement.**
   `App/LocalBoard.entitlements` contains neither
   `com.apple.security.network.client` nor `.network.server`. Without the
   client entitlement, the **kernel** refuses outbound connections — the app's
   own good behaviour is not what is stopping it.
2. **The source is checked mechanically.** `Scripts/verify-no-network.sh`
   fails the build if `URLSession`, `NSURLConnection`, `import Network`,
   `NWConnection`, BSD sockets, `Process(` or `NSTask` appear anywhere in the
   sources, and it inspects the **built** bundle's entitlements with `plutil`
   rather than grepping for them.
3. **Subprocesses are banned too.** `Process(` is on that list on purpose: a
   program that can launch another program can reach the network through it.
   This is why the optional repository-link feature reads git's files directly
   instead of running `git`.

The only network-adjacent capability the app has is
`com.apple.security.files.user-selected.read-write` — files **you** pick
through a system open or save panel, and nothing else.

Full detail in [PRIVACY.md](PRIVACY.md).

---

## Project layout

| Target | Contents |
|---|---|
| `LocalBoardCore` | Pure domain types. No SQLite, no SwiftUI, no I/O. |
| `LocalBoardStore` | SQLite persistence, the migration ladder, repositories. |
| `LocalBoardUI` | SwiftUI views and the view model. |
| `localboard` | The command-line tool. |
| `LocalBoardApp` | The app shell. |

Swift Package Manager, no `.xcodeproj`. Strict concurrency is on.

---

## Documentation

| File | What it covers |
|---|---|
| [CHANGELOG.md](CHANGELOG.md) | Every milestone, with the reasoning behind the decisions |
| [PRIVACY.md](PRIVACY.md) | Exactly what is stored, where, and for how long |
| [PERFORMANCE.md](PERFORMANCE.md) | The memory budget, measured figures, and how to measure again |
| [DISTRIBUTION.md](DISTRIBUTION.md) | What shipping this would involve — documentation only |
| [IMPACT-8.5.md](IMPACT-8.5.md) | Impact analysis for the current milestone |
| [docs/rca/](docs/rca/) | Root cause analyses for twenty-five real defects |

The RCA directory is worth reading before trusting the app with anything. It is
an honest record of what went wrong and why, including faults that shipped and
were caught later.

---

## Licence and warranty

**MIT License, with supplemental terms.** See [LICENSE](LICENSE) for the full
text. The MIT grant is unmodified, so the usual permissions apply: use, copy,
modify, merge, publish, distribute, sublicense and sell, provided the copyright
notice and permission notice travel with it.

Appended to it is a set of **Supplemental Terms and Disclaimers** that do not
restrict those permissions but do make the allocation of risk explicit. In
plain English, and without replacing anything in the LICENSE file:

- **This is unfinished software and is presumed to contain defects.** It has
  had no security review, no audit and no independent evaluation. Automated
  tests and documentation are not a warranty of anything.
- **If you take it, you take it at your own discretion and your own risk.**
  Downloading, cloning, pulling, forking, copying, replicating, building or
  running it is your own decision, made on your own judgment.
- **From the moment any part of it leaves this repository, the author has no
  further part in what happens.** No duty of support, maintenance, updates,
  notification or disclosure arises, and none is implied by anything said or
  done.
- **Liability is excluded to the fullest extent the law permits**, including
  for data loss — which matters here, because the app stores everything
  locally, migrates irreversibly, and neither encrypts nor backs up for you.
- **It is not for high-risk or regulated use.** Medical, financial,
  safety-critical, or anything with statutory record-keeping obligations.
- **Forks and derivatives are their publisher's responsibility**, not the
  author's, and must not imply endorsement.
- **No binary releases are published.** Any binary you did not build yourself
  is of unverified provenance.

> The author is not a lawyer and this text is not legal advice. If anything
> real depends on these terms, have a solicitor review them for your
> jurisdiction.
