# Closing the database twice

**Severity: critical.** Silent corruption of SQLite's internal state, surfacing
as failures in unrelated code minutes later.

Found during Milestone 8.5a. Latent since the CLI was written — every build
that shipped with `localboard` had it.

## Symptom

An intermittent test failure, in a *different* test each run:

```
.migrationFailed(version: 6, detail: "bad parameter or other API misuse")
.migrationFailed(version: 1, detail: "bad parameter or other API misuse")
.migrationFailed(version: 4, detail: "... (SQLite status 21, extended 21)")
```

Status 21 is `SQLITE_MISUSE`. The failing migrations were on **in-memory**
databases in tests that had nothing to do with the feature being built, and the
version varied between runs.

Frequency: clean across six consecutive full-suite runs before the new tests
were added; **four failures in eight runs** afterwards. Serial runs
(`--no-parallel`) were always clean.

## Root cause

```swift
deinit {
    statementCache.removeAll()
    sqlite3_close_v2(handle)      // ← no guard
}

public func close() {
    guard isOpen else { return }  // ← guard here
    statementCache.removeAll()
    sqlite3_close_v2(handle)
    isOpen = false
}
```

`close()` was idempotent; `deinit` was not. Every `Database` that had `close()`
called on it explicitly was closed **twice** — once by the caller, once when it
was deallocated. That is a use-after-free of the `sqlite3*` connection.

Everything that closed explicitly was doing it: the `localboard` CLI on exit,
the app on teardown, and every test that opened a file-backed database.

The damage does not appear where it is done. Freeing a connection twice
corrupts SQLite's process-wide allocator state, and the next unrelated
`sqlite3_exec` on *any* connection can come back `SQLITE_MISUSE`. That is why
it presented as a migration failing in a test that never touched the database
that was closed twice, and why it only appeared under parallel execution —
serial runs did not have another connection live at the moment of the corruption.

## Why it took so long to surface

Before Milestone 8.5a almost nothing called `close()` explicitly. The tests
used in-memory databases and let `deinit` do the work, which is the one path
where the missing guard is harmless. Writing tests that open *file-backed*
databases — needed for the backup-before-migration feature — created the first
workload that closed many connections explicitly and in parallel.

It was misattributed twice before being found:

1. Blamed on `VACUUM INTO`, which was being used for the backup and genuinely
   cannot run while a connection has active statements. Replacing it with a
   dedicated connection did not help.
2. Blamed on `VACUUM` in general. Replacing it with SQLite's online backup API
   did not help either.

Both of those changes were kept, because both were independently correct — but
neither was the cause.

## How it was finally isolated

By bisecting the *workload*, not the code:

| Run | Result |
|---|---|
| Full suite at the previous commit, ×6 | 0 failures |
| Full suite with the new work, ×8 | 4 failures in 2 runs |
| Full suite **without** the new backup tests, ×8 | 0 failures |
| Backup tests **alone**, ×6 | failures |
| Full suite `--no-parallel`, ×5 | 0 failures |

That triangulated to "the new file-backed database tests, only under
parallelism" — which pointed at shared process state rather than at any logic
in the feature.

A second change made the diagnosis readable: `executeRaw` was reporting
`sqlite3_errmsg` alone, which can return a *previous* error when the failing
call left none of its own. Including the numeric status turned
`"bad parameter or other API misuse"` into
`"... (SQLite status 21, extended 21)"`, confirming genuine `SQLITE_MISUSE`
rather than a stale message.

## Fix

```swift
deinit {
    guard isOpen else { return }
    statementCache.removeAll()
    sqlite3_close_v2(handle)
}
```

And, separately, every public entry point now refuses work on a closed
connection rather than handing SQLite a freed handle and relying on it
happening to return an error:

```swift
private func requireOpen() throws {
    guard isOpen else {
        throw LocalBoardError.databaseQueryFailed(detail: "The database has been closed.")
    }
}
```

"Usually returns `SQLITE_MISUSE`" is not a contract.

## Prevention

`MigrationBackupTests` now contains:

- **"Closing a database twice is harmless"** — closes three times, lets `deinit`
  close a fourth, then asserts SQLite still works by reopening the file.
- **"A closed database refuses work rather than using a freed handle"** —
  asserts the error rather than relying on undefined behaviour.

Fifteen consecutive full-suite runs were clean after the fix.

## The transferable lesson

An intermittent failure in code you did not touch is evidence about *shared
state*, not about the failing code. The useful question was never "what is
wrong with the migration" — it was "what did the new tests start doing that
nothing had done before".
