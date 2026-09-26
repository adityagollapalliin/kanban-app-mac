# Synthesised `Codable` on the export format's types

**Severity: high.** Every file anybody had exported became unreadable, with an
error no user could act on.

**Five instances.** `BoardTask` (8.5a), `Project` (pre-existing, since
workflow enforcement), `Status` (8.5c), and — found by the probe test the
moment it was first run — `Person` and `CardLabel`, both of which had required
a `color` key since colours were added.

## Symptom

```
DecodingError.keyNotFound: Key 'typeCode' not found in keyed decoding container.
DecodingError.keyNotFound: Key 'enforcesWorkflow' not found. Path: project.
DecodingError.keyNotFound: Key 'diagramX' not found. Path: statuses[0].
```

Importing any archive written by an earlier build fails outright. Not a
degraded import — a refusal.

## Root cause

The types the export format carries used Swift's **synthesised** `Codable`
conformance. A synthesised decoder requires *every* property's key to be
present. So the moment a non-optional property is added to one of those types:

```swift
public var typeCode: Int          // added in 8.5a
public var enforcesWorkflow: Bool // added when workflow enforcement arrived
public var diagramX: Double       // added in 8.5c
```

…every previously written file lacks that key and throws.

The critical property of this bug is that **it is introduced by an edit that
looks entirely unrelated to the export format.** Nobody adding a diagram
coordinate to `Status` is thinking about backups.

This had already been solved *once*, correctly, for the `ProjectArchive`
envelope itself, which has a hand-written `init(from:)` using
`decodeIfPresent`. The lesson was applied to the container and not to anything
inside it.

## How it was found

Instance 1 (`BoardTask`) and instance 2 (`Project`) were found in 8.5b while
implementing condition 2 of the approved plan — "importing a backup that lacks
`syntax` treats every query as simple" — which required writing a test that
decodes an archive spelled the old way. Both fell out of that test immediately.

Instance 3 (`Status`) was caught **by that same test, the same day it was
introduced**, which is the whole value of having written it.

Instances 4 and 5 (`Person`, `CardLabel`) were found the first time the probe
suite ran — it had been written but never compiled, because tooling access was
lost mid-session. Both had been broken for as long as people and labels have
had colours. **Five of the seven payload types were affected; only
`ChecklistItem` and the archive envelope were ever safe.**

## Fix

Hand-written decoders with defaults for every property added after the format
existed. For example:

```swift
public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    ...
    typeCode = try container.decodeIfPresent(Int.self, forKey: .typeCode) ?? type.rawValue
    environment = try container.decodeIfPresent(String.self, forKey: .environment) ?? ""
    ...
}
```

Note the default for `typeCode`: it falls back to the enumeration's raw value,
so an old file's cards keep the kind they had rather than all becoming one kind.
A default of `0` would have silently turned every card in every backup into an
Epic.

## Prevention

Two layers.

1. **A probe test per payload type** (`ArchivePayloadProbeTests`) that decodes
   each type from the minimal JSON the *first* version of that type produced.
   Seven types, seven tests. A new non-optional property fails its type's test
   on the day it is written.

2. **A rule, stated in the code**, on each hand-written decoder:

   > Written by hand rather than synthesised, because a synthesised decoder
   > demands every key: adding one non-optional property would make every file
   > anybody had already exported unreadable. Every property added from here on
   > gets a default here in the same commit.

## Status

All seven payload types now have hand-written decoders and a passing probe.

The probe covers the types the archive carries today. The archive gained
`savedViews` in 8.5b; if it later carries components, resolutions, transition
rules or field configurations, each of those types needs the same treatment and
the same probe. **This is the single most likely place for a fourth instance.**
