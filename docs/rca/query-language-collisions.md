# Extending a grammar in place changes what stored text means

**Severity: high.** Saved filters would have silently returned different cards.

Found in Milestone 8.5b, **before** any code was written, by building a
regression corpus first.

## Symptom

None — and that is the point. This was caught before it could happen, by an
exercise that was itself a requirement of the approved plan.

## The finding

The brief asked for the filter language to be extended towards JQL, with the
promise that it be a **strict superset**: every filter anybody had already
saved must still parse and still return the same cards.

Building the regression corpus surfaced that this is **not achievable**. Six
JQL-shaped strings already *compiled* in the original language — as full-text
searches, because an unrecognised word is a search term there:

| String | What it meant before | What JQL would make it |
|---|---|---|
| `ORDER BY due` | search for "order", "by", "due" | a sort clause |
| `priority IN (high, highest)` | search for four words | a set filter |
| `summary ~ login` | search for two words | a contains filter |
| `status WAS "In Progress"` | search for those words | a history query |
| `status CHANGED FROM "To Do" TO "Done"` | search for those words | a history query |
| `status = "No Such Column"` | a real comparison matching nothing | unchanged |

Giving those words their JQL meanings changes what such a filter returns. None
was saved in the live database — but "unlikely" was not the promise.

## Root cause of the near-miss

The instinct was to extend one grammar and rely on care. The corpus showed that
care is not sufficient, because the conflict is not between old syntax and new
syntax — it is between new syntax and **text that was previously meaningless
and therefore fell through to full-text search**. A permissive fallback turns
every future keyword into a breaking change.

## Fix

A `syntax` column on every table that stores query text, defaulting to
`'simple'`. A filter written before the change is *declared* to be in the old
language and continues to be read by the old parser. Its meaning cannot change,
because the code that reads it does not change.

Seven columns gained one:

`saved_view`, `quick_filter`, `swimlane`, `goal`, `dashboard_widget`,
`view_config.filter_query`, and `board.filter_syntax`.

Three future tables (automation conditions, SLA queues, filter digests) will be
born with one. Card colour rules need none — they point at a saved view and
inherit its language.

**A stated rule, worth repeating:** *a column holding query text is incomplete
without a column saying which language it is in.*

## Implementation note

One parser with a mode, not two parsers. The fields, values, flags and brackets
are identical in both languages and a second copy would drift. Every JQL
production is gated on the mode — **including the tokenizer's handling of `~`
and `,`**, which are ordinary characters inside a word in the simple grammar.
Tokenising them in both would itself have changed what a saved text search
matches.

## Prevention

`QueryCorpus` + `QueryCompatibilityTests` + `Fixtures/query-baseline.json`:

- **101 query strings** — the four in the live database, the four every new
  board is given, twenty already asserted in the suite, four the app asks
  itself in source, plus coverage of every field, every flag, every comparison
  and each custom-field storage kind, and the twelve the parser rejects.
- Each is compiled against a **fixed** database and a **stopped clock**, and
  both the SQL *and* the bound values are compared against a recorded baseline.
- Re-recording requires `RECORD_QUERY_BASELINE=1`. An ordinary run cannot
  overwrite the baseline, because a run that quietly re-recorded it would turn
  every failure into a pass.

The six colliding strings are held in their own group, `textSearchToday`, with
a comment explaining that they are *not* invalid strings waiting for a meaning
— they are valid strings that already have one.

## The baseline has moved exactly once

Milestone 8.5c, for the priority-rank change (see
[ordering-and-arithmetic.md](ordering-and-arithmetic.md)). Six of 101 entries
changed SQL; every one was a priority comparison and the other 95 were
untouched. The equivalence of *results* was asserted card by card in a test
written **before** the baseline was moved. That order matters: re-recording
first and testing afterwards proves nothing.
