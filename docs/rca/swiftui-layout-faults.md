# Containers that do not do what they appear to

**Severity: medium**, but with a distinguishing property: **no test in this
project can catch any of them.** Every one was found by building the app,
screenshotting the window, and looking.

**Nine instances**, across Milestones 8, 8.5b and 8.5c.

## The instances

### 1. `LazyVGrid` cannot span columns — Milestone 8

**Symptom.** Every dashboard widget drew one cell wide, whatever width was set
in its editor. A two-wide chart and a one-wide counter were identical on screen.

**Cause.** `gridCellColumns(_:)` works in `Grid`, not `LazyVGrid`. The modifier
compiled, did nothing, and reported nothing.

**Fix.** Lay the rows out directly — a `LazyVStack` of `HStack`s, each widget
framed to `cell * span + spacing * (span - 1)`.

### 2. A stored layout the app could not draw — Milestone 8

**Symptom.** Widget height was modelled as a row *span*, and the packer
allocated cells accordingly.

**Cause.** Neither `Grid` nor `LazyVGrid` can draw a cell that straddles two
rows. The data model described an arrangement that could not be rendered, so
what came back from storage never matched what was on screen.

**Fix.** Height became a box height rather than a row span, and the packer was
changed to match. **A test asserting the old row-spanning behaviour was deleted**
— it was asserting something nothing could render, which is worse than no test.

### 3. `Grid` is never lazy — Milestone 8

**Symptom.** The weekly timesheet used **144 MB** for sixty rows, within sight
of the 150 MB ceiling.

**Cause.** `Grid` builds every row the moment it is asked to, and it was inside
a scroll view with nothing bounding it. A week in which a team logged against
three hundred cards would have gone straight through the ceiling.

**Fix.** A `LazyVStack` of rows whose columns line up because each is a fixed
width — which is what a timesheet's columns are anyway. **144 MB → 123 MB**, and
the cost no longer grows with the week.

### 4. A `minWidth` column collapses — Milestone 8

**Symptom.** The timesheet's day columns did not line up: each row's days
started at a different x.

**Cause.** The card column had a *minimum* width, so it grew to fit the longest
title **in its own row**.

**Fix.** A fixed width. A timesheet's columns are fixed by definition.

### 5. A scroll view gives its content only the width it asked for — Milestone 8

**Symptom.** The timesheet and the time-in-status report drew centred, floating
in the middle of the window.

**Fix.** `.frame(maxWidth: .infinity, alignment: .leading)` on the content.

### 6. `safeAreaInset` on a split view lands in the middle of it — 8.5b

**Symptom.** The navigator's query bar rendered halfway down the window, with a
screen of empty space above it.

**Cause.** An `HSplitView` takes all the height it is offered, so an inset on it
is placed relative to that full height rather than above it.

**Fix.** Stack the bar above the split view in a `VStack` instead.

### 7. A split view bottom-aligns a child that sizes to its content — 8.5b

**Symptom.** With the bar fixed, the table then sat in the floor of the window.

**Cause.** The children had been given a width but no height instruction, so
each sized to its content and settled against the bottom.

**Fix.** `maxHeight: .infinity` on both halves.

### 8. The title column is the one that gives way — 8.5b

**Symptom.** The navigator's Title column collapsed to an ellipsis — the one
column nobody can read a list without.

**Cause.** Every other column had a fixed width; Title was flexible, so it
absorbed all the shortfall.

**Fix.** `.width(min:ideal:)` on Title, and modest ideals on the rest.

### 9. A fixed inset radius is only right for a square — 8.5c

**Symptom.** On the workflow diagram, arrows between two columns stacked
vertically all but vanished: a label between two tiny chevrons, with no line.

**Cause.** The arrow was inset from each node's centre by a fixed distance
(`width / 2 + 6`) along the direction of travel. For a node 150×52, a *vertical*
arrow was inset by 81 points at each end — more than the gap between the nodes.

**Fix.** Compute where the ray actually crosses the rectangle, by scaling by
whichever axis it leaves through:

```swift
let scaleX = dx == 0 ? .infinity : halfWidth / abs(dx)
let scaleY = dy == 0 ? .infinity : halfHeight / abs(dy)
let scale = min(scaleX, scaleY)
```

**Related, same screen.** The labels of an A→B/B→A pair printed on top of each
other. A perpendicular bow cannot separate two labels wider than the bow, so
each label now also slides towards its own end of the curve.

## Why tests cannot catch these

Every one of these compiled, ran, and produced a view hierarchy that was
structurally correct. `gridCellColumns` on a `LazyVGrid` is legal Swift. A
`Grid` inside a `ScrollView` is legal SwiftUI. An arrow inset by 81 points is
arithmetic that does exactly what it says. What was wrong in each case was the
*rendered result*, and this project has no snapshot testing.

## The procedure that does catch them

Recorded in full in the project's own notes; in outline:

1. Temporarily change the screen's default in source, `make bundle`.
2. Get the app's `CGWindowID` via `CGWindowListCopyWindowInfo`.
3. `screencapture -x -o -l <id>` — works even when the app is not focused,
   which `open -a` cannot guarantee.
4. **Look at the image.**
5. Revert the temporary default before committing.

Steps 1 and 5 are where mistakes get committed; the default was reverted and
verified by `grep` every time.

## The rule, now five instances old

> A nested lazy container is not lazy; a container with no scrolling region of
> its own cannot be lazy at all; and `Grid` is not lazy in the first place.

And a sixth, from this round:

> A layout the storage can describe but the view cannot draw is a bug in the
> storage, not a limitation of the view.
