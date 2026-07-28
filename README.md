# AmbixDeals

The Foundation-only deals wire codec shared between **Ambix Station** and **Ambix
Daisho** (and, later, other Ambix apps). It has zero dependencies — no Firebase, no
UIKit/SwiftUI, no app-module imports — so it compiles and unit-tests on any platform,
including Linux CI.

## What's in here

Extracted **byte-identical** from `AmbixStationCore` (Ambix Station repo) on
2026-07-28, via `git show origin/main:<path>` so every moved file is a provable
copy of the Station blob at extraction time:

| File | Moved from (Station, `origin/main`) |
|---|---|
| `Sources/AmbixDeals/Money.swift` | `Sources/AmbixStationCore/Money.swift` |
| `Sources/AmbixDeals/FirestoreValue.swift` | `Sources/AmbixStationCore/Relay/FirestoreValue.swift` |
| `Sources/AmbixDeals/MirrorWrite.swift` | `Sources/AmbixStationCore/Relay/MirrorWrite.swift` |
| `Sources/AmbixDeals/Deal.swift` | `Sources/AmbixStationCore/Offers/Deal.swift` |
| `Sources/AmbixDeals/DealDraft.swift` | `Sources/AmbixStationCore/Offers/DealDraft.swift` |
| `Sources/AmbixDeals/DealDraft+MirrorEmitting.swift` | `Sources/AmbixStationCore/Offers/DealDraft+MirrorEmitting.swift` |
| `Sources/AmbixDeals/DraftValidation.swift` | `Sources/AmbixStationCore/Offers/DraftValidation.swift` |
| `Sources/AmbixDeals/DealsSettings.swift` | `Sources/AmbixStationCore/Contracts/DealsSettings.swift` |
| `Sources/AmbixDeals/CostFloorPolicy.swift` | **split out** of `Sources/AmbixStationCore/Offers/DealEvaluation.swift` (the `CostFloorPolicy` struct + its doc comment only — the engine file itself, and everything else in it, stays in Station) |

`CostFloorPolicy.swift` is the one file in this package with any hand-authored
content beyond a straight copy: it is the exact `CostFloorPolicy` type + doc comment
block lifted out of `DealEvaluation.swift`, wrapped only in `import Foundation`.
Nothing else changed.

Test files moved alongside their types (import line changed to
`@testable import AmbixDeals`; no other edits):

| File | Moved from |
|---|---|
| `Tests/AmbixDealsTests/MoneyTests.swift` | `Tests/AmbixStationCoreTests/MoneyTests.swift` |
| `Tests/AmbixDealsTests/DealCodecTests.swift` | `Tests/AmbixStationCoreTests/Offers/DealCodecTests.swift` |
| `Tests/AmbixDealsTests/DealDraftTests.swift` | `Tests/AmbixStationCoreTests/Offers/DealDraftTests.swift` (includes the 65-test encode↔decode lockstep sweep) |
| `Tests/AmbixDealsTests/DealsSettingsTests.swift` | `Tests/AmbixStationCoreTests/DealsSettingsTests.swift` |

Engine-adjacent tests (`DealEngine*Tests.swift`, `DealTraceTests.swift`,
`RefundMoneyTests.swift`) stay in Station — they exercise types (`DealEngine`,
`RefundMoney`, `DealCartLine`, …) that are not part of this package.

## Lockstep rules

- **This package is the single source of truth for the deals wire shape.** Station
  and Daisho must consume the *same* tagged version, never hand-copy these files
  again.
- The `DealDraftTests` encode→decode lockstep sweep lives here specifically so
  encode and decode can never silently drift from each other across a version bump.
- Any wire-shape change (new discount kind, new field, changed defaulting/clamping
  behavior) is a **version bump** here, not a silent edit downstream. Consumers pin
  by exact version or a narrow range — see Semver discipline below.
- Station keeps a contract test pinning the projector-facing shape
  (`discount.kind`, `payload`) so a package bump that changes the wire fails
  Station's CI, not the live store.
- The **ABSENT-vs-NULL** semantics in `DealDraft.mirrorWrite()` assume the caller
  writes with Firestore `setData(merge: true)`. Any consumer (Daisho included) that
  writes drafts through a plain `setData` or `updateData` will get different stored
  documents from the same `MirrorWrite` — build (or reuse) a merge-true renderer,
  don't assume.
- The decode engine matters as much as the codec: identical `Deal.init(from:)`
  behavior requires feeding it through an equivalent JSON bridge. Station's own
  `DealsStore.sanitizedDocument` (JSONSerialization → JSONDecoder, with an
  NSNumber-reboxing fix and Timestamp→ISO conversion) is the reference
  implementation; a consumer using Firestore's native `Decoder` (e.g. `doc.data(as:)`)
  is not guaranteed to produce identical results for `Decimal`-typed fields.

## Local-override workflow (day-to-day Station/Daisho dev)

While iterating on both a consumer app and this package in the same session, don't
fight the pinned version — use SPM's local package override so edits here are
picked up immediately without a publish/tag/bump cycle:

**Xcode (Daisho, or Station's App target via its `.xcodeproj`):**
File → Packages → “AmbixDeals” → *Edit* (or drag a local checkout into
File → Add Package Dependencies… → *Add Local*). Xcode will build against your
local working copy instead of the pinned tag until you remove the override.

**Swift Package Manager CLI (Station's `Package.swift`, `swift build`/`swift test`):**
Add a local override in `~/Desktop/AmbixDeals` (or wherever you've checked it out)
via a `Package.swift` `dependencies` override, or use
`swift package edit AmbixDeals --path /path/to/local/AmbixDeals` inside the
consuming package to switch it to local-edit mode; `swift package unedit
AmbixDeals` to switch back to the pinned version.

**Before landing on `main` in any consumer**, remove the local override and confirm
the consumer still builds/tests green against the pinned tag — local overrides are
for active co-development only, never committed state.

## Semver discipline

- Tags are semver (`vMAJOR.MINOR.PATCH`), starting at `v0.1.0` for the initial
  extraction. This is a break from AmbixCore's history (milestone-string tags only,
  no version-based pinning) — a deliberate fix, not an oversight.
- Consumers pin by **exact version** (`.package(url:, exact: "0.1.0")`) or a narrow
  range once the API stabilizes. Never a floating branch or an unpinned local path
  on `main` — that's the exact failure mode (`../AmbixCore` symlink drift) this
  package exists to avoid.
- Any change to a wire-visible default, discriminator, or field name is at minimum a
  **minor** bump (and almost certainly needs a corresponding AmbixServer
  `shapeGuard` review, since the server polices the same `deals` documents
  server-side). Breaking a decode/encode contract is a **major** bump.
- Bump the tag only after `swift test` is green locally for this package; consumer
  repos re-pin and re-test on their own schedule, they do not float automatically.

## Build

```
swift build --jobs 4
swift test --jobs 4
```

No dependencies, no Firebase, no unsafe compiler flags — this package is safe to
consume as a **remote** (git-pinned) SPM dependency, unlike `AmbixStationCore`
(which uses `-strict-concurrency=complete` via `unsafeFlags`, tolerated only for
local/Xcode package references).
