# Features that could be configured and did nothing

**Severity: high.** Worse than a missing feature, because the settings screen
asserts that it works.

**Four instances, all shipped in Milestone 8.5c**, all found by a deliberate
call-site sweep rather than by use.

## Symptom

Nothing. That is the problem.

Each of these had a repository method, a view-model wrapper in three of the
four cases, and a settings UI that wrote the configuration to the database
correctly. Turning them on produced no error, no warning, and no behaviour.

## The four

| Feature | What existed | What was missing |
|---|---|---|
| **Transition conditions** (`isOffered`) | Store method, view-model wrapper | No view called it. Every move was offered regardless of its conditions — so a condition behaved exactly like no condition. |
| **Per-kind field defaults** (`applyDefaults`) | Store method only | No wrapper, no call site. A default recorded in settings was never applied to any card. |
| **Per-kind required fields** (`missingRequired`) | Store method, view-model wrapper | No view called it. A required field was never reported as missing. |
| **Transition screens** (`screenFields`) | Column, storage, editor UI | The move path never read it. A transition configured to stop and ask went straight through. |

The condition case is the sharpest. A **condition** and a **validator** differ
precisely in that a condition *hides* the move while a validator *refuses* it
— that distinction is written into the design and into the tests. With
`isOffered` uncalled, conditions silently became the weakest possible thing:
neither hiding nor refusing.

## Root cause

Each was built bottom-up — schema, then repository, then tests, then settings
UI — and the last step, *reading* the configuration from the place the
behaviour happens, was never taken. The store tests passed because they call
the repository directly. The UI compiled because nothing requires a public
method to be called.

**Nothing in the toolchain objects to a public method with no callers.** Swift
does not warn, the tests do not notice, and the settings screen looks complete.

## How they were found

A deliberate sweep, prompted by writing them down as *suspicions* rather than
assuming they were fine:

```sh
grep -rn "isOffered\|applyDefaults\|missingRequired" Sources/ | grep -v Repository
grep -rn "screenFields" Sources/ | grep -v WorkflowEditorView
```

All four came back with a definition, a wrapper, and no consumer.

## Fix

- **`applyDefaults`** is now called inside `TaskRepository.create` — the single
  funnel every creation path goes through (board, quick add, template, menu
  bar, CLI). Wiring it at one caller would have meant the others silently did
  not, which is the mistake documented in
  [duplicate-creation-paths.md](duplicate-creation-paths.md).
- **`isOffered`** backs a new `offeredStatuses(for:)`, which both status menus
  now use instead of listing every column.
- **`missingRequired`** is shown as a line on the card, not as a refusal at
  creation: a card is usually made from a title alone and filled in afterwards.
- **`screenFields`** is honoured in `BoardViewModel.move`, the one funnel every
  move goes through. A transition with a screen *parks* the move as a
  `pendingTransition`; the board presents a sheet; submitting fills the fields
  in and completes the move; cancelling writes nothing. A screen whose fields
  the card already carries is skipped, because a dialog that always appears is
  a dialog people learn to dismiss without reading.

## Prevention

`WorkflowWiringTests` — eight tests that fail if any of the four goes back to
being a setting that does nothing. They deliberately exercise the **view
model**, not the repositories, because the repositories were never the part
that was broken:

- a condition removes a column from `offeredStatuses`;
- a card's own column is always on the list;
- a screen parks the move and writes nothing;
- submitting fills the field in and completes it;
- cancelling leaves the card exactly where it was;
- an already-answered screen does not appear;
- a required field is reported and then stops being reported;
- a new card of a kind with defaults gets them.

## The transferable lesson

"Implemented" and "wired" are different claims, and the tests that prove the
first do not touch the second. When a feature is built bottom-up, the last
question is not *does the repository do it* — it is **who calls this?** A
`grep` for the method name, expecting at least one hit outside its own file and
its own wrapper, takes seconds and would have caught all four.
