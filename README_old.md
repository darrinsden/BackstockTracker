# Backstock Tracker

iOS app for Jacent Strategic Merchandising Area Managers (AMs) to scan returned and clearance product into boxes, track the running credit total against the $149.99 per-box limit, and coordinate with the rest of their area on what's already on the floor.

Built with SwiftUI + SwiftData. No third-party dependencies today.

## What it does, in one trip

A day-in-the-life of an AM with the app:

1. **First-run pick area, then store.** On launch the app fetches the latest roster, catalog, store, and TM CSVs from Google Drive. Once those land the AM chooses their area (e.g. `Seattle-North`), then the chain + store number for the location they're walking into today.
2. **Scan into a box.** On the Scan tab, each UPC scanned (camera or hand scanner) is looked up in the catalog *for this store* — same UPC at Target and Walmart can have different prices, so the lookup is scoped. The item is added to the current box and the running subtotal updates at the top.
3. **Manage the box.** Tap a row to edit quantity, swipe to delete, or use the bookmark to flag for the pick list. A red banner appears for "not in catalog" or "not in this store — available at X" so the AM knows whether to skip or move the item.
4. **Submit at the limit.** Under $149.99 → Submit writes the box and pushes it to the team feed instantly. Over $149.99 → Submit becomes orange "Request approval"; tap it to open a pre-filled email to the TM in Mail.app. The box only records as `.overLimit` after the email actually sends.
5. **Walk the floor against the team feed.** The Backstock tab shows every box submitted for the current store, by anyone in the area, with totals and per-box detail. Use it to know what's already boxed before scanning a duplicate.
6. **Work the pick list.** Tap the bookmark on any item in any box to add it to the pick list — a device-local queue persisted across app launches. Open the pick list sheet to walk the floor with a focused list, mark items picked, and (when appropriate) call "Remove from backstock," which rebuilds the source box and pushes the patch back to the team feed.

## Setup

### Prerequisites
- macOS with Xcode 16 or later
- An Apple Developer account (for device deployment / TestFlight)
- iOS 17+ target (SwiftData requirement)

### Open the project

```bash
open BackstockTracker.xcodeproj
```

Then in Xcode:
- Select your Apple ID under **Signing & Capabilities → Team**
- Pick a destination (simulator or your iPhone)
- **Cmd+R** to build and run

### Reference data

The app pulls four CSVs from Google Drive at launch. Each must be set to "Anyone with the link can view." Schemas and Drive IDs live in [CLAUDE.md](./CLAUDE.md#reference-data-sources-google-drive-anyone-with-link-can-view).

| File | Purpose |
|------|---------|
| `area_managers.csv` | Roster of AMs with territory + area assignments |
| `catalog.csv` | Products with prices, scoped per retailer chain |
| `stores.csv` | Store locations (chain + number + area + short label) |
| `territory_managers.csv` | TM emails for over-limit approvals |

The URLs are wired into each `*SyncCoordinator` at the top of `BackstockTrackerApp.swift`. To swap a URL, edit the `private let sourceURL = URL(string: "...")!` line in the relevant coordinator.

### CloudKit (team sync)

The team feed runs on CloudKit's public database, container `iCloud.com.jacent.BackstockTracker`. Before shipping to TestFlight you must enable the iCloud capability in Xcode and deploy the schema. The full pre-prod checklist (sortable / queryable indexes, write/delete permissions, schema deploy) is in [CLAUDE.md → CloudKit team sync](./CLAUDE.md#cloudkit-team-sync-public-database).

## Daily-use cheat sheet

| Action | Where |
|--------|-------|
| Change area or store mid-day | Settings → Area / Store |
| Manually sync catalog / stores | Settings → Sync now |
| Re-scan a UPC the camera missed | Hand-type into the search field (any partial match also surfaces it) |
| Edit a submitted box | Backstock tab → tap the box → **Edit in Scan** |
| Merge two boxes for the same store | Backstock tab → swipe / context-menu → **Merge into…** |
| Flag an item for floor pulling | Bookmark icon in any team item row |
| Walk the pick list | Backstock tab → pick-list button → walk floor → **Remove from backstock** when done |
| View backstock across all stores in the area | Backstock tab → **All stores** (`AreaBackstockView`) |

## Architecture

Single-file Swift project (`BackstockTracker/BackstockTrackerApp.swift`, ~10K lines). Major pieces:

- **Sync coordinators** — four `@Observable @MainActor` singletons that pull each CSV in parallel at launch
- **SwiftData models** — `Product`, `AreaManager`, `Store`, `TerritoryManager`, `ScanSession`, `ScannedItem`, plus `*Sync` audit records (see `BackstockSchemaV1`)
- **`ScanSessionStore`** — in-memory observable session being built on the Scan tab; persists to SwiftData on submit
- **`CloudSyncService`** — CloudKit public-DB actor; upload, edit, delete, retry-on-launch, and a read-side scrub for a known catalog text corruption
- **`PickListStore`** — device-local pick queue persisted to `UserDefaults`, with cascade-delete + optimistic-rollback hooks
- **`ScanView`** — Scan tab; hand scanner via focused TextField, camera fallback via `CameraScannerView` (VisionKit)
- **`SubmitSheet`** — branches between under-limit (direct submit) and over-limit (TM approval email)
- **`HistoryView` / `StoreHistoryList` / `TeamSessionDetailView` / `AllBackstockDetailView` / `AreaBackstockView`** — the Backstock tab surfaces, all driven by the same `TeamBackstockRecord` data shape
- **`PickListSheet`** — pick-list working queue with search, commodity filter, and the cross-AM "Remove from backstock" action

See [CLAUDE.md](./CLAUDE.md) for the full architecture, behavioral decisions, gotchas, and the planned Firestore migration.

## Deployment

### TestFlight

1. Bump the build number in **Xcode → Project → General → Build**
2. Set destination to **Any iOS Device (arm64)**
3. **Product → Archive**
4. In the Organizer: **Distribute App → App Store Connect → Upload**
5. Wait ~10 minutes for processing in App Store Connect
6. Add testers under the **TestFlight** tab

Latest TestFlight build: **17**.

### Required Info.plist additions (TODO before App Store)
- `NSCameraUsageDescription` — explanation for camera barcode scanning

## Schema changes during development

The app uses a `SchemaMigrationPlan` (`BackstockMigrationPlan`). Additive field changes can ride a lightweight stage; renames, splits, or type changes need a custom stage. Step-by-step in [CLAUDE.md → Schema migration policy](./CLAUDE.md#schema-migration-policy).

In dev: if the migration plan can't reconcile (e.g. mid-development churn), delete the app from the simulator/device before rebuilding. Real users on TestFlight should never need to do this — that's the whole point of having a migration plan.

## Working with Claude Code

This project ships with a `.claude/` directory configured for Claude Code. Useful slash commands:

- `/balance-check` — verify Swift braces balance after an edit
- `/sync-status` — verify the four Drive URLs are current and not placeholders
- `/schema-bump` — checklist after changing a `@Model` class

Full project context lives in [CLAUDE.md](./CLAUDE.md), which Claude Code reads at session start.

## Known issues / open items

- Apple Developer account and iCloud container are on a personal Apple ID — needs transfer to a Jacent-owned organisation account before broader rollout.
- CloudKit schema is on Development; needs to be deployed to Production before App Store release.
- No automated tests yet. Targets when added: `CatalogService` (UPC lookup variants), `SyncService.parse*` (CSV edge cases), `ScanSessionStore` (limit math), `CloudSyncService.scrubChainCorruption`.
- `FirestoreSyncService.swift` is scaffolding — not yet wired into the build. Activation steps in the file header.
- No formal observability beyond in-app banners and Xcode Organizer crash reports.

## License / ownership

Internal Jacent Strategic Merchandising tool. Not for redistribution.
