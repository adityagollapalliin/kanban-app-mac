# Open items

Updated 2026-09-26, after the interrupted audit was completed.

## Closed since the first draft

Everything this file originally listed as unverified has now been checked.

| Item | Outcome |
|---|---|
| Transition screens may not prompt | **Confirmed inert. Fixed.** See [configured-but-inert.md](configured-but-inert.md) |
| `applyDefaults` may never be called | **Confirmed inert. Fixed** — now called inside `TaskRepository.create` |
| `isOffered` may not hide moves | **Confirmed inert. Fixed** — both status menus use `offeredStatuses(for:)` |
| `missingRequired` may not be surfaced | **Confirmed inert. Fixed** — shown on the card |
| FK cascades for v9–v11 tables | **Checked and asserted.** `CascadeTests`, 7 tests |
| `PRAGMA foreign_key_check` on the live database | **Clean** at v11, before and after benchmark cleanup |
| Memory for the three new screens at 1,000 cards | **Measured.** Navigator 76 MB, workflow 61 MB — both well inside the 150 MB ceiling. `Table` is genuinely lazy |
| CLI export/import at v11 | **Verified.** The archive carries `savedViews` with `syntax`, and tasks with `typeCode` and `environment` |
| Archive payload decoders | **Two more instances found** (`Person`, `CardLabel`) and fixed; all seven types now pass the probe |

## Still open

### SQL parameter-binding order outside the query baseline

One instance of this was found and fixed in 8.5c, caught only because the query
baseline compares **bound values** as well as SQL text. Statements outside that
baseline have no equivalent guard, and a wrong binding order produces a query
that runs and returns the wrong rows.

There is no cheap automated check for this. The practical mitigation is the
habit the compiler's comment now records: bind in the order the placeholders
appear, and say so where the statement is long enough to make that non-obvious.

### The workflow diagram is uncapped

Every node and every arrow is drawn. Four statuses is nothing; a project with
forty would draw forty nodes and up to 1,560 arrows. The mind map needed a cap
at 150 nodes for exactly this reason. Measured at 61 MB with four statuses, so
this is a *latent* limit rather than a present problem — but it is the same
shape as a fault this project has hit five times.

### Milestone 8.5d onwards

Unstarted. The URL scheme (`CFBundleURLTypes`) and `QuickLookUI` were approved
and belong to 8.5d.

## Environment note, for the record

Mid-session the tooling lost read access to the repository while it lived in
`~/Downloads`. This turned out to be **macOS TCC**, not the tool's sandbox: the
Downloads folder permission had been revoked for the terminal, and `getcwd()`
returned `EPERM` while `cd` still succeeded. `sudo` does not help, because TCC
is enforced per application rather than per user.

Resolved by moving the repository to `~/Developer/kanban-app-mac`, which is not
a TCC-protected location. Recorded here because the symptom — git reporting
`Unable to read current working directory` on a directory you are standing in —
is unobvious and cost an hour.
