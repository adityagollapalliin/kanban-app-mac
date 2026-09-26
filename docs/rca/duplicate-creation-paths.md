# Two ways to make a project, one of them updated

**Severity: high.** Silently empty query results — no error, no warning.

**Two instances, both in Milestone 8.5.**

## Symptom

Instance 2 is the clearer one. A swimlane defined by `priority >= highest`
stopped showing any cards. No error appeared anywhere. The board simply had no
expedite lane, as though no card were urgent.

## Root cause

Schema v9 made four fixed vocabularies — issue types, priorities, link types,
resolutions — into rows a project owns. The migration seeded them for every
project that existed **when it ran**. A project created afterwards needs the
same rows seeded by the code that creates projects.

There turned out to be **three** ways a project comes into being:

| Path | Purpose |
|---|---|
| The v9 migration | Projects that already existed |
| `createProject` | A project the user makes |
| `seedStarterContent` | What a brand-new, empty file is given |

Instance 1 (8.5a): only the migration was written. `createProject` was missed,
so any project made after upgrading had no vocabulary.

Instance 2 (8.5c): `createProject` had been fixed, but `seedStarterContent` —
**the path every new installation takes** — had not. Its projects had no
`priority_value` rows, so the rank subquery introduced by the priority change
matched nothing, and every `priority` comparison returned zero cards.

## Why it was silent

The failure mode is an empty result set, which is indistinguishable from a
correct query that happens to match nothing. Nothing throws. Nothing logs.

Instance 1 surfaced as a *test* failure only because the test helper seeds
projects by hand and was updated alongside. Instance 2 surfaced only because
the priority change made an existing swimlane test go red — had that test not
existed, it would have shipped.

## Fix

A single seeding routine, `VocabularyRepository.seedDefaults(forProject:)`,
called from both runtime paths, and idempotent so calling it twice adds
nothing:

```sql
INSERT INTO issue_type (...) VALUES (...)
ON CONFLICT (project_id, code) DO NOTHING;
```

The migration keeps its own copy of the seed data, because migrations are
append-only and must not change when the runtime seed does.

## Prevention

`ProjectCreationParityTests` — "A starter project and a made one have the same
vocabulary" — exercises both runtime paths in one test and asserts they agree
on every vocabulary, under the same numbers:

```swift
for project in [starter.projectID, made.id] {
    #expect(try vocabulary.issueTypes(inProject: project).map(\.code) == [0, 1, 2, 3])
    #expect(try vocabulary.priorities(inProject: project).count == 5)
    #expect(PriorityValue.ranksMatchCodes(try vocabulary.priorities(inProject: project)))
    ...
}
```

The comment on it states the stake plainly: the paths must agree *under the
same numbers*, or a card moved between two spaces created either side of an
upgrade would change kind.

## The transferable lesson

Before adding per-project seed data, enumerate every way that thing comes into
being — and write the parity test **first**, because it is the only artefact
that will still be true in six months when a fourth path is added.
