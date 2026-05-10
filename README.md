# Backstock Tracker

iOS app for Jacent Strategic Merchandising Area Managers (AMs). Scan returned and clearance product into boxes, track the running credit total against the $149.99 per-box limit, request TM approval over the limit, and coordinate with the rest of the area on what's already on the floor.

Built with SwiftUI + SwiftData. No third-party dependencies today.

## A day in the life

1. **Launch.** App fetches the latest roster, catalog, store, and TM CSVs from Google Drive in parallel.
2. **Pick area, then store.** Two gating screens (`AreaPickerView` → `StorePickerView`). Both selections persist; you only re-pick when you change them in Settings.
3. **Pick a box (1–20).** The store picker bar at the top of the Scan tab carries the active box number. Each box gets its own draft, so half-scanned work survives backgrounding and box switches.
4. **Scan.** Hand scanner (USB / Bluetooth, keystroke-style) or the camera button. Each UPC is looked up *for the selected store* — same UPC at Target and Walmart can have different prices.
   - **Hit** → row added, confirm chirp, running subtotal updates.
   - **Wrong store** → red banner ("Not in this store — available at Walmart"), with "Add anyway" → manual-override sheet.
   - **Not in catalog** → buzzer + manual-override sheet (name, price, optional note). Item is flagged as a manual override in the audit log.
5. **Manage the box.** Tap a row to edit quantity, swipe to delete, bookmark to flag for the pick list. Toolbar Edit/Done turns on multi-select for bulk delete. Clear-all is confirmation-gated.
6. **Submit at or near the limit.**
   - **Under $149.99** → green Submit. Box is saved locally, uploaded to CloudKit, posted to the live team feed, and the scan list clears.
   - **Over $149.99** → orange "Request approval." Opens a pre-filled Mail.app draft to the TM with subject `"Backstock session — <date>"`, a multi-line body listing each item (qty, line total, UPC, override note), and a CSV attachment. The box only records as `.overLimit` after the email actually sends.
7. **Walk the floor against the team feed.** Backstock tab shows every submitted box for the current store, by anyone in the area. Tap a box to drill in; long-press / swipe to delete, merge, or change box number. "All stores" widens the same view to every store in the area.
8. **Work the pick list.** Tap a bookmark in any team item to add it to the device-local pick queue (survives app kill). Open the pick list sheet to walk the floor with a focused, searchable, commodity-filterable list. Mark picked, or call **"Remove from backstock"** — that rebuilds the source box and pushes the patch back to the team feed.
9. **Edit a submitted box.** From a box detail view, tap **"Edit in Scan"** — the Scan tab loads with the box's items and an orange banner ("You're editing Box 3 at Target #860 — Cancel"). Submit's labels swap to "Save changes," and after save the app pops back to the box detail.

## Setup

### Prerequisites
- macOS with Xcode 16 or later
- Apple Developer account (for device deployment / TestFlight)
- iOS 17+ target (SwiftData requirement)

### Open the project

```bash
open BackstockTracker.xcodeproj
```

Then in Xcode:
- **Signing & Capabilities → Team** — your Apple ID
- Pick a destination (simulator or your iPhone)
- **Cmd+R** to build and run

### Reference data

The app pulls four CSVs from Google Drive at launch. Each must be set to "Anyone with the link can view." Schemas and Drive IDs live in [CLAUDE.md → Reference data sources](./CLAUDE.md#reference-data-sources-google-drive-anyone-with-link-can-view).

| File | Purpose |
|------|---------|
| `area_managers.csv` | Roster of AMs with territory + area assignments |
| `catalog.csv` | Products with prices, scoped per retailer chain |
| `stores.csv` | Store locations (chain + number + area + short label) |
| `territory_managers.csv` | TM emails for over-limit approvals |

URLs are wired into each `*SyncCoordinator` at the top of `BackstockTrackerApp.swift`. To swap a URL, edit the `private let sourceURL = URL(string: "...")!` line in the relevant coordinator.

### CloudKit team sync

The team feed runs on CloudKit's public database, container `iCloud.com.jacent.BackstockTracker`. Before shipping to TestFlight you must enable the iCloud capability in Xcode and deploy the schema. Full pre-prod checklist (Sortable / Queryable indexes, write/delete permissions, schema deploy) is in [CLAUDE.md → CloudKit team sync](./CLAUDE.md#cloudkit-team-sync-public-database).

## Daily-use cheat sheet

| Need to… | Where |
|----------|-------|
| Change area or store mid-day | Settings → Area / Store |
| Switch boxes | Box number selector in the Scan tab's store picker bar |
| Manually sync catalog or stores | Settings → Sync now (or the inline "Sync now" on an empty-table banner) |
| Re-scan a UPC the camera missed | Hand-type into the focused scan field (auto-focus stays on it) |
| Add a UPC the catalog doesn't have | Scan it → manual-override sheet opens → fill name + price + optional note |
| Edit a submitted box | Backstock tab → tap the box → **Edit in Scan** |
| Merge two boxes for the same store | Backstock tab → swipe / context-menu → **Merge into…** |
| Move a box to a different box number | Backstock tab → swipe / context-menu → **Change box number** |
| Bulk delete empty boxes | Backstock tab → **Clean up empty boxes** button at the top |
| Flag an item for floor pulling | Bookmark icon in any team item row |
| Walk the pick list | Backstock tab → pick-list button → walk floor → **Remove from backstock** when done |
| View backstock across all stores in the area | Backstock tab → **All stores** (`AreaBackstockView`) |
| Sort a long detail list | Sort menu — Rank (default), Scan order, Name A→Z / Z→A, **Quantity high→low** |

## Architecture

Single-file Swift project (`BackstockTracker/BackstockTrackerApp.swift`, ~10K lines). Major pieces:

- **Sync coordinators** — four `@Observable @MainActor` singletons that pull each CSV in parallel at launch
- **SwiftData models** — `Product`, `AreaManager`, `Store`, `TerritoryManager`, `ScanSession`, `ScannedItem`, plus `*Sync` audit records (see `BackstockSchemaV1`)
- **`ScanSessionStore`** — in-memory observable session being built on the Scan tab; persists to SwiftData on submit; carries `isEditingExistingRecord` for the edit-in-place flow
- **`CloudSyncService`** — CloudKit public-DB actor; upload, edit-items, update-box, delete, retry-on-launch, and a read-side scrub for the known chain-name corruption
- **`PickListStore`** — device-local pick queue persisted to `UserDefaults`, with cascade-delete + optimistic-rollback hooks
- **`ScanView`** — Scan tab; hand scanner via focused `TextField`, camera fallback via `CameraScannerView` (VisionKit)
- **`ManualPriceSheet`** — manual-override entry, two variants (not-in-catalog / wrong-store)
- **`SubmitSheet`** — confirmation sheet for both new-box and edit-existing flows
- **`HistoryView` / `StoreHistoryList` / `TeamSessionDetailView` / `AllBackstockDetailView` / `AreaBackstockView`** — the Backstock tab surfaces, all driven by the same `TeamBackstockRecord` shape
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

The app uses a `SchemaMigrationPlan` (`BackstockMigrationPlan`). Additive field changes ride a lightweight stage; renames, splits, or type changes need a custom stage. Step-by-step in [CLAUDE.md → Schema migration policy](./CLAUDE.md#schema-migration-policy).

In dev: if the migration plan can't reconcile (mid-development churn), delete the app from the simulator/device before rebuilding. Real users on TestFlight should never need to do this — that's the point of the migration plan.

## Working with Claude Code

This project ships with a `.claude/` directory configured for Claude Code. Useful slash commands:

- `/balance-check` — verify Swift braces balance after an edit
- `/sync-status` — verify the four Drive URLs are current and not placeholders
- `/schema-bump` — checklist after changing a `@Model` class

Full project context lives in [CLAUDE.md](./CLAUDE.md), which Claude Code reads at session start.

## Known issues / open items

- Apple Developer account and iCloud container are on a personal Apple ID — needs transfer to a Jacent-owned organisation account before broader rollout.
- CloudKit schema is on Development; needs Production deploy before App Store release.
- No automated tests yet. Targets when added: `CatalogService` (UPC lookup variants), `SyncService.parse*` (CSV edge cases), `ScanSessionStore` (limit math), `CloudSyncService.scrubChainCorruption`.
- `FirestoreSyncService.swift` is scaffolding — not yet wired into the build. Activation steps are documented in the file header.
- No formal observability beyond in-app banners and Xcode Organizer crash reports.

## License / ownership

Internal Jacent Strategic Merchandising tool. Not for redistribution.
