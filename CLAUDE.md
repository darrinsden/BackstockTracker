# Backstock Tracker

iOS app for Jacent Strategic Merchandising Area Managers (AMs) to scan returned/clearance product into boxes, track the running credit total against the $149.99 per-box limit, and coordinate with the rest of their area on what's already on the floor. Built with SwiftUI + SwiftData on iOS 17+. No third-party dependencies today.

## How an AM actually uses it

The whole app is structured around a single physical session: one AM, in one store, working one box of 1–20, scanning UPCs. Everything else is scaffolding around that loop.

### First-run gating

`LaunchCoordinator` keeps the tab bar hidden until both selections exist in `@AppStorage`:

1. **`AreaPickerView`** — list of distinct `area` values from the roster CSV. Sets `selectedArea`.
2. **`StorePickerView`** — two dependent dropdowns (chain → store number) filtered to that area, plus a "Sync stores now" button if the table is empty. Sets `selectedStore` + `selectedStoreNumber` and seeds `selectedBox = 1` on Continue.

Both pickers are reused as sheets from `SettingsView`. Changing area clears the store; changing the store resets the box.

### Scan tab (`ScanView`)

The Scan tab is built around a focused, invisible `TextField` (`scanField`) that catches keyboard-wedge scanner input — hand scanners send the UPC followed by a return, which submits the field. Camera fallback comes from a "Scan with camera" button that presents `CameraScannerView` (VisionKit's `DataScannerViewController`). Both paths funnel into the same lookup.

Top to bottom, the screen renders:

- **Identity header** — chain + store number + area, so the AM always sees where they are.
- **Edit-in-place banner** — appears when `ScanSessionStore.isEditingExistingRecord` is true (kicked off by "Edit in Scan" on a team box). Tells the AM what record they're editing and offers an exit ramp.
- **Empty-catalog / empty-stores banners** — if either local table is empty, show an inline "Sync now" button. Scanning would silently fail otherwise.
- **Store picker bar** — current chain / store number / **box number (1–20)**, plus a "Change store" button (confirmation-gated when there's an in-progress session).
- **Status bar** — running subtotal, item count, color-coded against the $149.99 limit.
- **Scan field** — the focused TextField; tap anywhere outside to dismiss the keyboard.
- **Error / success banners** — red auto-dismisses after 4s; green confirms saves and draft restores.
- **Items list** — one row per scanned line; tap to edit quantity, swipe to delete, bookmark icon to flag for pick list. Toolbar Edit/Done enables multi-select for bulk delete.
- **Action bar** — Clear (confirmation-gated, no undo since nothing has hit SwiftData) and Submit.

#### Per-UPC lookup behavior

`CatalogService.lookup(upc:store:)` tries 12-digit, 13-digit-with-leading-zero, and 13-without, in that order. Outcomes:

- **Hit for this store** → add row or increment existing row, confirm chirp.
- **Hit for another store** → red banner "Not in this store — available at X (Walmart, Target, …)" and a "Add anyway" affordance that opens `ManualPriceSheet` with `reason = .otherStore`.
- **No hit anywhere** → `ManualPriceSheet` with `reason = .notInCatalog`, buzzer tone. Item gets tagged as a manual override in the persisted session.

`ManualPriceSheet` has three fields: name, price (decimal pad), and an optional note ("new SKU, confirmed with store"). The header makes it clear the item will be flagged in the audit log.

#### Drafts

`restoreDraftIfAvailable()` runs on appear and whenever `selectedStore`, `selectedStoreNumber`, or `selectedBox` changes. A half-scanned box survives backgrounding, app kill, and store/box changes — the draft is keyed on the (store, storeNumber, box) tuple, so each box has its own resumable scratch.

### Submit (`SubmitSheet`)

- **Under $149.99** → green Submit. Writes the box to SwiftData (`ScanSession` + `ScannedItem`), pushes a `BackstockSession` record to CloudKit, posts `.teamSessionDidUpdate`, clears the scan list.
- **Over $149.99** → orange "Request approval." Opens `MFMailComposeViewController` pre-filled to the TM (from `territory_managers.csv`), with subject `"Backstock session — <date>"`, a multi-line body listing each item with quantity / line total / UPC / override note, and a CSV attachment. The box only persists as `.overLimit` after the mail composer reports a send.
- **Edit-existing flow** → same sheet, labels swap to "Save changes? / Confirm and save" with the caption *"This updates the existing box for everyone in your area."*

### Backstock tab (`HistoryView` → `StoreHistoryList`)

Always store-scoped — no Mine/Team toggle, no cross-store mixing. Shows every CloudKit `BackstockSession` for the current store, sorted by box number. Pull-to-refresh re-fetches; the `.teamSessionDidUpdate` notification keeps the list live.

Per-row actions:
- **Tap** → `TeamSessionDetailView` (box contents, sortable, with per-item edit, quantity bump, bookmark, and "Edit in Scan" which loads the record into `ScanSessionStore` and flips to the Scan tab).
- **Swipe / context-menu** → Delete (with optimistic pick-list cascade + rollback on failure), Merge into another box, change box number.
- **Empty-boxes bulk cleanup** at the top of the list.

Two wider surfaces sit above the per-box list:
- **`AllBackstockDetailView`** — flattens all boxes for the store into one searchable list, with sort + commodity filter. Duplicate `(recordId, upc, price)` rows are aggregated so the bookmark visual stays accurate.
- **`AreaBackstockView`** — same idea but across every store in the AM's area. Defense-in-depth scrub on the chain-name corruption (see below) runs at init.

### Pick list (`PickListStore` + `PickListSheet`)

Tap the bookmark on any team item to add it to a device-local queue (`PickListStore`, persisted to `UserDefaults` so it survives app kill). Open the pick list sheet from any backstock surface to walk the floor with a focused, searchable list grouped by box.

- **Mark picked** → updates the queue locally.
- **Remove from backstock** → for items whose source record is in the current store's slice, rebuild the box's items and push the patch back through `CloudSyncService.updateItems`. Cross-store picks are left alone with a warning. The action snapshots the affected pick entries first so the queue can be restored on failure.

### Settings (`SettingsView`)

Form with four sections: Area, Store, Product catalog (Sync now + last-result line), Stores (Sync now + last-result line). Changing area clears store + storeNumber and wipes any in-progress scan session. Changing store wipes the in-progress session.

## Architecture overview

Single-file Swift project (`BackstockTracker/BackstockTrackerApp.swift`, ~10K lines, brace-balanced). One scaffolding file at `BackstockTracker/Backend/FirestoreSyncService.swift` is gated behind `#if canImport(FirebaseFirestore)` — not yet in the build target.

Major sections of the main file, in order:

1. **App entry** — `BackstockTrackerApp` (constructs `ModelContainer` via `BackstockMigrationPlan`; launches four parallel CSV syncs; primes the audio session)
2. **Sync coordinators** — `RosterSyncCoordinator`, `CatalogSyncCoordinator`, `StoreSyncCoordinator`, `TerritoryManagerSyncCoordinator` (each `@Observable @MainActor`)
3. **SwiftData models** — `Product`, `AreaManager`, `Store`, `TerritoryManager`, `ScanSession`, `ScannedItem`, plus `*Sync` audit records
4. **Session store** — `ScanSessionStore` (`@Observable` in-memory; persists to SwiftData on submit; held at the app root via `.environment(...)`; carries `isEditingExistingRecord` for the edit-in-place flow)
5. **Cloud + pick stores** — `CloudSyncService` (CloudKit public-DB actor with optimistic cache, retry-sweep, and the chain-name scrub), `PickListStore` (`@Observable`; cross-AM pick queue persisted to `UserDefaults`)
6. **Catalog/Store services** — `CatalogService.lookup(upc:store:)`, `StoreService.distinctStoreNames(in:)`, `storeNumbers(for:in:)`
7. **Sync service** — `SyncService` parses Drive-hosted CSVs, atomic full-replace of each table
8. **Audio service** — synthesized PCM tones via `AVAudioPlayer` (NOT system sounds — those proved unreliable)
9. **Views** — `StorageErrorView`, `LaunchCoordinator`, `AreaPickerView`, `StorePickerView`, `LoadingRosterView`, `RootTabView`, `ScanView`, `ManualPriceSheet`, `SubmitSheet`, `HistoryView`, `StoreHistoryList`, `DetailHeaderView`, `TeamSessionDetailView`, `AllBackstockDetailView`, `AreaBackstockView`, `PickListSheet`, `PickQuantitySheet`, `QuantityEditSheet`, `SessionDetailView`, `SettingsView`, `CameraScannerView`

## Reference data sources (Google Drive, "Anyone with link can view")

| File | Schema | Drive ID |
|------|--------|----------|
| `area_managers.csv` | `employeeNumber, firstName, lastName, territory, area, email` (6th optional) | `1rOFqR8IDo4lEJmT39tHtw7JsLggOauxf` |
| `catalog.csv` | `upc, name, price, commodity, store, retailPrice, rank` (12-digit UPC-A; preserve leading zeros; cols 4–7 optional) | `1izR-bDANhkOBlOyvgB9k4gCHOUSn6x5n` |
| `stores.csv` | `store, storeNumber, area, shortName` (3rd and 4th optional for backward compat) | `1WtggB4_n1G2avUV4q0Di4VRjG2ZdrEh3` |
| `territory_managers.csv` | `territory, email` | `1eJ7rQLkO9uCwATuPfPCxvSX-jIRnggss` |

`SyncService.normalizeSourceURL` accepts any Drive URL format (share link or direct download) and rewrites to the `uc?export=download&id=...` form.

## Key behavioral decisions

- **Hard limit:** `ScanSessionStore.hardLimit = 149.99`. Triggers over-limit branch in submit flow.
- **Catalog scoping:** `Product.upc` is NOT unique. The composite (upc, store) is the logical primary key, enforced at sync time by full-replace. The same UPC can carry different prices at Target vs. Walmart.
- **Store scoping:** Stores partition by `area` (the AM's specific slice), not by `territory` (the broader region). Case-sensitive exact-match — "Seattle-North" ≠ "Seattle North" ≠ "seattle-north".
- **Area + store + box gating:** `LaunchCoordinator` shows `AreaPickerView` then `StorePickerView` before the `RootTabView` appears. Box number lives in `@AppStorage("selectedBox")` (0 = unset, 1–20 valid) and resets to 1 on any store change.
- **UPC format flexibility:** `CatalogService.lookup` tries 12-digit, 13-digit-with-leading-zero, and 13-without — handles scanner inconsistencies.
- **Over-limit submit flow:** Submit button changes to "Request approval" (orange) at >$149.99. Tap → `MFMailComposeViewController` with subject `"Backstock session — <date>"`, body listing each line, and a CSV attachment. Session persists as `.overLimit` only after mail composer reports send.
- **Manual overrides:** `ManualPriceSheet` opens for UPCs missing from the catalog or wrong-store, with different copy per `reason`. Items are stored with `overrideNote` and shown distinctly in audit / email export.
- **Drafts:** Half-scanned boxes persist by (store, storeNumber, box) — `restoreDraftIfAvailable()` rehydrates on appear and on any store/box change.
- **Edit-in-place:** "Edit in Scan" on a team box loads its items into `ScanSessionStore`, flips `isEditingExistingRecord = true`, switches the tab to Scan, and changes Submit's copy to "Save changes." After save, the app posts `.openBackstockRecord`, flips back to Backstock, and pushes the updated detail screen onto the nav stack.
- **Audio:** Synthesized 1800Hz confirm chirp (80ms), 380Hz buzzer (350ms). Audio session is `.playback`, primed at app launch.
- **Camera fallback:** `CameraScannerView` closes 0.4s after success, stays open with red error on not-found, distinguishes "Not in catalog" from "Not in this store — available at X".
- **Pick list:** `PickListStore` is a singleton `@Observable` injected at the app root. Persists to `UserDefaults`. `removeAllFor(recordId:)`, `entries(forRecordId:)`, and `restore(_:)` are the cascade-delete + optimistic-rollback hooks used by `StoreHistoryList` on box delete, merge, or empty-bulk cleanup.
- **Chain-name corruption scrub:** `CloudSyncService.scrubChainCorruption` strips a known upstream catalog corruption (long-form chain names embedded inside product / commodity strings — e.g. `PASTRY → PAlbertsons/SafewayTRY`). Applied at `StoreHistoryList.reload`, on every `.teamSessionDidUpdate`, and again at `AreaBackstockView.init`.

## Sort orders (`ScanSortOrder`)

Shared across `TeamSessionDetailView`, `AllBackstockDetailView`, `AreaBackstockView`, `SessionDetailView`:

- `.rank` — default. Merchandising rank from the catalog (lower is better); items without a rank fall to the bottom.
- `.scanOrder` — preserves the order rows were added.
- `.nameAZ` / `.nameZA` — case-insensitive name sort.
- `.quantityDesc` — highest-quantity-first for triaging deep backstock. Ties broken by name asc.

Price sorts were removed by request — they didn't map to any AM workflow on the backstock surfaces.

## Schema migration policy

Container init runs through `BackstockMigrationPlan` (a `SchemaMigrationPlan`). The plan currently lists one version, `BackstockSchemaV1`, which holds the eight `@Model` types (`Product`, `ScanSession`, `ScannedItem`, `CatalogSync`, `AreaManager`, `AreaManagerSync`, `Store`, `StoreSync`).

**To make a schema change without breaking existing installs:**

1. Copy `BackstockSchemaV1` to `BackstockSchemaV2`, bump `versionIdentifier`.
2. Make the change inside V2.
3. Add a `MigrationStage` entry to `BackstockMigrationPlan.stages`. Use `.lightweight(fromVersion:toVersion:)` for additive changes; `.custom(...)` for renames, splits, type changes, or anything that needs old-row data to populate new fields.
4. Add V2 to `BackstockMigrationPlan.schemas`.

If `ModelContainer` init throws despite the migration plan (real disk / sandbox failure, not schema drift), the app routes to `StorageErrorView` instead of crashing — the user gets a "Copy diagnostics" button and a delete-and-reinstall instruction.

## CloudKit team sync (public database)

Submitted sessions are pushed to `CKContainer("iCloud.com.jacent.BackstockTracker").publicCloudDatabase`, record type `BackstockSession`. Records are anonymous by design — no submitter identity, just `area / store / storeNumber / box / items / subtotal / retailTotal / status / submittedAt`.

**Required before production TestFlight:**
- Enable iCloud capability in Xcode (Signing & Capabilities → + Capability → iCloud → CloudKit → container `iCloud.com.jacent.BackstockTracker`)
- First app run auto-generates the Development schema on first save
- In the CloudKit Dashboard: make `submittedAt` **Sortable** and `area` **Queryable** (both under Schema → Indexes) before deploying to Production
- **Open `BackstockSession` write/delete permissions** — Schema → Record Types → BackstockSession → Security tab → set both **Write** and **Delete** to **Authenticated** (the public-DB default is **Creator**, which only lets the original submitter modify the record). This is what enables team-edit, the box delete affordance, and the pick-list "Remove from backstock" cross-AM workflow. Without it, any non-creator update returns `CKError.permissionFailure` ("WRITE operation not permitted").
- Deploy Schema to Production before App Store release

**Retry on launch:** `CloudSyncService.retryPending` sweeps for local sessions with `cloudSyncedAt == nil` and uploads them, so a network blip at submit time doesn't drop records from the team feed.

**Live update notification:** `Notification.Name.teamSessionDidUpdate` (userInfo `"record": TeamBackstockRecord`) is posted after any successful patch (edit-items, update-box, pick-list remove, merge). `StoreHistoryList` and `AreaBackstockView` both observe it and apply the scrub before merging the cleaned record into their state. Any new in-place edit path MUST post this — otherwise other open screens won't see the change until next reload.

## Firestore migration (scaffolding only)

`BackstockTracker/Backend/FirestoreSyncService.swift` is the planned cross-platform replacement for `CloudSyncService`. It's intentionally **not yet added to the Xcode target** — the file lives behind `#if canImport(FirebaseFirestore) && canImport(FirebaseAuth)` so it compiles to nothing today. Public API mirrors `CloudSyncService` 1:1 so call sites can be flipped behind a `useFirestore` feature flag. Activation checklist is in the file header. Do not start writing through it until SPM deps are added, the `useFirestore` flag exists, and `data-contract.md` is signed off.

## Coding conventions

- **Comments:** Liberal explanatory comments on non-obvious logic, especially around sync, audio, mail composer wrappers, store-scoping edge cases, and the chain-name scrub. Match the existing tone — explain *why*, not *what*.
- **Edits:** Prefer surgical edits over full-file rewrites. Re-read the file region before editing — it's long (~10K lines) and easy to make wrong assumptions.
- **Brace balance:** After any non-trivial edit, verify braces balance. Use `/balance-check` (see `.claude/commands/`) or `scripts/balance.py`.
- **Imports at the top:** `SwiftUI, SwiftData, AudioToolbox, AVFoundation, BackgroundTasks, VisionKit, Vision, MessageUI, CloudKit`. Add new imports here, not inline.
- **No new dependencies without asking:** No SPM packages, no CocoaPods. The Firebase exemption is approved in principle but not yet activated. Anything else needs a conversation.
- **Error display:** Red errors auto-dismiss after 4s via `scanErrorBanner(message:)`; green successes auto-dismiss via `scanSuccessBanner`.

## Build & test workflow

- **Build:** Open `~/jacent/BackstockTracker/BackstockTracker.xcodeproj` in Xcode → Cmd+R for simulator/device run.
- **Schema-change rebuild:** Delete the app from device/simulator first, then Cmd+R.
- **TestFlight:** Bump build number in General tab → Product → Archive → Distribute App → App Store Connect → Upload.
- **No unit tests yet.** When we add them, target the pure logic in `CatalogService`, `StoreService`, `SyncService.parse*`, `ScanSessionStore` total/limit math, and `CloudSyncService.scrubChainCorruption`.

## Common gotchas

- `MFMailComposeResult` is Equatable, but `Result<MFMailComposeResult, Error>` is NOT. State that needs `.onChange(of:)` should be the bare `MFMailComposeResult?`.
- `@AppStorage` only supports `String`, not `String?`. Use empty string for "not yet set."
- `EditButton` in toolbar didn't fire reliably in our setup; we use a manual `editMode` toggle instead.
- Stepper inside a List row intercepts tap-to-select in edit mode — hide the stepper when `editMode.isEditing`.
- Don't add `Done` button in keyboard toolbar — it overlapped the Submit button at small sizes.
- `dismiss-keyboard-on-outside-tap` was blocking swipe-to-delete handles. We use `scrollDismissesKeyboard(.immediately)` plus a `simultaneousGesture(TapGesture())` (discrete, doesn't contend with continuous swipe).
- `StoreSyncCoordinator` writes via a fresh `ModelContext(container)`, so screens fetching the store list need a `@Query` (not `context.fetch(...)` from `@Environment`) to see updates.
- Any in-place edit path that mutates a CloudKit record MUST post `.teamSessionDidUpdate` with the updated `TeamBackstockRecord` in `userInfo["record"]`.
- Identifiable wrapper around the manual-override UPC (`ManualUPCPrompt`) — bundling presentation trigger + payload is required because SwiftUI sometimes built the sheet body before separate `@State` writes propagated, so the UPC field came up blank.

## Outstanding work

- [ ] Info.plist: `NSCameraUsageDescription` (required for App Store / TestFlight)
- [ ] Info.plist: `BGAppRefreshTaskSchedulerPermittedIdentifiers` if we add background sync
- [ ] "Signed-in AM removed from roster" edge case
- [ ] Enable CloudKit capability in Xcode + deploy schema to production before TestFlight release
- [ ] Transfer Apple Dev account and iCloud container to Jacent-owned org
- [ ] Wire `FirestoreSyncService` into the build behind a `useFirestore` flag; dual-write one TestFlight cycle
- [ ] Android port — same Drive sources, same data-contract.md schema
