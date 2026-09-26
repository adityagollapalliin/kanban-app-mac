# Root cause analyses

One file per *class* of fault rather than per incident, because every fault in
here happened more than once. The recurrence is the finding: a bug that
appears three times in three milestones is not three mistakes, it is one
missing guard.

Each file follows the same shape:

- **Symptom** — what was actually observed, not what it turned out to be.
- **Root cause** — the mechanism, stated precisely enough to be checked.
- **How it was found** — and, where it applies, why it was *not* found sooner.
- **Fix** — what changed.
- **Prevention** — the test or rule that makes a fourth instance fail loudly.

## Index

| File | Class | Instances | Severity |
|---|---|---|---|
| [database-double-close.md](database-double-close.md) | Use-after-free in SQLite teardown | 1 (latent since the CLI existed) | **Critical** — silent data-layer corruption |
| [archive-decoder-brittleness.md](archive-decoder-brittleness.md) | Synthesised `Codable` on export types | 5 | **High** — every exported backup unreadable |
| [duplicate-creation-paths.md](duplicate-creation-paths.md) | Two ways to make the same thing, only one updated | 2 | **High** — silently empty query results |
| [swiftui-layout-faults.md](swiftui-layout-faults.md) | Containers that do not do what they appear to | 9 | **Medium** — invisible to every test |
| [configured-but-inert.md](configured-but-inert.md) | A setting nothing reads | 4 | **High** — the feature appears to work |
| [query-language-collisions.md](query-language-collisions.md) | Extending a grammar in place changes stored meaning | 1 (6 affected strings) | **High** — saved filters silently change results |
| [ordering-and-arithmetic.md](ordering-and-arithmetic.md) | Comparing the wrong quantity | 3 | **Medium** — wrong rows, wrong figures |

**Twenty-five instances across seven classes.**

## The one-line summary of all of it

Five of the six classes share a shape: **something was true when the code was
written, stopped being true later, and nothing was watching.** Ranks equalled
codes. Every card's type was one of four. Every project came into being one
way. Every stored query was in one language. The guard in each case is a test
that asserts the assumption *as an assumption*, so the day it stops holding is
the day a test goes red rather than the day a user notices.
