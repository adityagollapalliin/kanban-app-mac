# Comparing the wrong quantity

**Severity: medium.** Wrong rows returned, wrong figures shown — all of them
plausible-looking.

Three instances, Milestones 8 and 8.5.

## 1. Priority compared by storage code rather than by rank — 8.5c

**The assumption.** `priority >= high` compiled to `task.priority >= 3`.

That is correct **only while every priority's rank equals the number it is
stored under**. True of every scale the app seeds — and the reason it went
unnoticed — and false the moment a project inserts a step in the middle of its
own scale. A new "Medium-high" takes code 5 (the next free number) and rank 3
(where it belongs). Comparing codes would have sorted it **above Highest**.

**Fix.** The comparison asks the project's scale:

```sql
task.priority IN (
    SELECT code FROM priority_value WHERE project_id = ?
      AND rank >= (SELECT rank FROM priority_value WHERE project_id = ? AND code = ?))
```

**Caught on the way in.** The first version bound the parameters in the wrong
order — `projectID, code, projectID` against placeholders that read
`projectID, projectID, code`. The baseline test compares **bound values as well
as SQL**, so it failed on the parameters, not just the text. Comparing SQL
alone would have let a silently-wrong query through.

**Guard.** `PriorityValue.ranksMatchCodes(_:)` states the assumption as a
function, and the seeded-scale parity test asserts it. Adding a priority step
is refused in the UI until this is true by construction.

## 2. Rollups that count blanks as zero — Milestone 8

**The trap.** An average over related cards, where some left the field blank.
Treating blank as zero drags the figure down with data nobody entered — the
quiet way a rollup starts lying.

**The rule adopted**, asserted per function:

- `average` divides by the cards that **answered**, not by all of them.
- `count` counts the **cards**, including the ones that left it blank.
- Nothing related at all is **blank**, not zero — because zero is a figure
  somebody might act on. `count` is the exception: none is a good count of none.

Same reasoning in the formula evaluator: a blank field **propagates** rather
than standing in for zero, so a formula over an unfilled field reads as blank.
`isempty()` and `coalesce()` exist to say otherwise deliberately.

## 3. A goal counting downwards read as an overshoot — Milestone 8

**Symptom.** A goal to cut open bugs from 40 to 10, standing at 22, displayed
**"22 of 10"** — which parses as a count that has overshot its target.

**Cause.** The progress text assumed goals count upward.

**Fix.** `descending` (`target < start`) selects different wording:
`"22, down to 10"`.

The *arithmetic* was already right — progress is measured from `start`, so 22 of
the way from 40 to 10 is 60%, not 220%. Only the sentence was wrong. Worth
noting because a correct number with a wrong label is harder to spot than a
wrong number.

## Related: a tie nobody broke — Milestone 8

Two time-log entries written **in the same second** — a timer stopped and a
correction typed straight after — left it to SQLite which one a timesheet edit
reduced. `ORDER BY created_at DESC` is ambiguous when timestamps tie.

**Fix.** `ORDER BY created_at DESC, rowid DESC`. Insertion order settles it.

Found because a test seeded both entries with a stopped clock — the stopped
clock made a real-world race deterministic rather than hiding it.

## The transferable lesson

Each of these is an assumption that was true when written:

- ranks equalled codes;
- every related card had a value;
- goals counted upward;
- two writes never shared a second.

**Write the assumption down as a predicate** — `ranksMatchCodes`, `descending`,
an explicit `[Double?]` for "answered or not" — and the day it stops holding is
a test failure rather than a wrong number on somebody's screen.
