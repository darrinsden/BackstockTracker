# Backstock Tracker

iOS app for Jacent Strategic Merchandising Area Managers to scan returned/clearance product into boxes, track the running credit total against the $149.99 per-box limit, and surface what's already on the floor across the AM's entire area. Built with SwiftUI + SwiftData on iOS 17+. No third-party dependencies (today).

## How an AM actually uses it (mental model)

The whole app is structured around a single physical session: one AM, in one store, working one box, scanning UPCs. Everything else is scaffolding around that loop.

1. **Pick area, then store.** First-run shows `AreaPickerView` (distinct `area` values from the roster), then `StorePickerView` (chain → store-number dropdowns, filtered to the picked area). Both are gates — the tab bar doesn't appear until both `selectedArea` and `selectedStoreNumber` are set. Switching either of them later (from `SettingsView`) clears the dependent selection and any in-progress scan session.
2. **Scan into a box.** `ScanView` is the Scan tab. Each scan looks up `(upc, store)` against the local catalog and either adds the item, increments its quantity, or shows a red banner ("Not in catalog" / "Not in this store — available at X / Y"). A running subtotal renders at the top.
3. **Submit at or near the limit.** Under $149.99 → Submit writes the box to SwiftData and pushes it to CloudKit as a `BackstockSession`. Over $149.99 → Submit becomes orange "Request approval"; tapping opens `SubmitSheet` → pre-filled `MFMailComposeViewController` to the TM. The session only persists as `.overLimit` after the mail composer reports send.
4. **Walk the floor against the team feed.** The Backstock tab (`HistoryView`) shows every box already submitted for the AM's current store, scoped to one physical location at a time. Drill into a box (`TeamSessionDetailView`) to see its items, flag any onto the pick list, or edit it in place. `AllBackstockDetailView` flattens all boxes for the store into one searchable list; `AreaBackstockView` widens the same idea to the entire area (cross-store).
5. **Pick list as a working queue.** The bookmark icon on any team item adds it to `PickListStore` (a `@Observable` device-local list, persisted to `UserDefaults`). The pick list sheet lets the AM walk the floor with a focused list, mark items picked, and — when the box owner is themselves or anyone else in the area — call "Remove from backstock," which rebuilds the source record's `items` and pushes the patch back to CloudKit.

## Architecture overview

Single-file Swift project (`BackstockTracker/BackstockTrackerApp.swift`, ~10K lines, brace-balanced). One scaffolding file lives at `BackstockTracker/Backend/FirestoreSyncService.swift` and is gated behind `#if canImport(FirebaseFirestore)` — not yet linked into the target. Major sections of the main file, in order:

1. **App entry** — `BackstockTrackerApp` (constructs `ModelContainer` via `BackstockMigrationPlan`; launches four parallel CSV syncs; primes the audio session)
2. **Sync coordinators** — `RosterSyncCoordinator`, `CatalogSyncCoordinator`, `StoreSyncCoordinator`, `TerritoryManagerSyncCoordinator` (each `@Observable @MainActor`)
3. **SwiftData models** — `Product`, `AreaManager`, `Store`, `TerritoryManager`, `ScanSession`, `ScannedItem`, plus `*Sync` audit records for each table
4. **Session store** — `ScanSessionStore` (`@Observable` in-memory; persists to SwiftData on submit; held at the app root via `.environment(...)`)
5. **Cloud + pick stores** — `CloudSyncService` (CloudKit public DB actor with optimistic cache + retry sweep), `PickListStore` (`@Observable`; cross-AM pick queue persisted to `UserDefaults`)
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
- **Area + store gating:** `LaunchCoordinator` shows `AreaPickerView` then `StorePickerView` before the `RootTabView` appears. Both selections live in `@AppStorage` (`selectedArea`, `selectedStore`, `selectedStoreNumber`). The Backstock and Scan tabs assume both are set and stay scoped to that one physical store. Changing either from `SettingsView` clears the dependents and any in-progress scan session.
- **UPC format flexibility:** `CatalogService.lookup` tries 12-digit, 13-digit-with-leading-zero, and 13-without — handles scanner inconsistencies.
- **Over-limit submit flow:** Submit button changes to "Request approval" (orange) at >$149.99. Tap → `SubmitSheet` with TM email card → "Open email draft" → `MFMailComposeViewController` opens Mail.app pre-filled. Session persists as `.overLimit` only after mail is sent.
- **Audio:** Synthesized 1800Hz confirm chirp (80ms), 380Hz buzzer (350ms). Audio session is `.playback`, primed at app launch.
- **Camera fallback:** `CameraScannerView` (VisionKit `DataScannerViewController`). Closes 0.4s after success, stays open with red error on not-found, distinguishes "Not in catalog" from "Not in this store — available at X".
- **Pick list:** `PickListStore` is a singleton `@Observable` injected into the environment at the app root. Items are `(recordId, upc, name, commodity, ...)` and persist to `UserDefaults` so the queue survives app kill. `removeAllFor(recordId:)`, `entries(forRecordId:)`, and `restore(_:)` are the cascade-delete + optimistic-rollback hooks used by `StoreHistoryList` when a record is deleted, merged, or cleaned up.
- **Chain-name corruption scrub:** `CloudSyncService.scrubChainCorruption` is a read-side defensive pass that strips a known upstream catalog corruption (long-form chain names embedded inside product / commodity strings — e.g. `PASTRY → PAlbertsons/SafewayTRY`). Applied once at `StoreHistoryList.reload` and again on every `teamSessionDidUpdate`, with defense-in-depth at `AreaBackstockView.init`.

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

If `ModelContainer` init throws despite the migration plan (real disk / sandbox failure, not schema drift), the App routes to `StorageErrorView` instead of crashing — the user gets a "Copy diagnostics" button and a delete-and-reinstall instruction.

## CloudKit team sync (public database)

Submitted sessions are pushed to `CKContainer("iCloud.com.jacent.BackstockTracker").publicCloudDatabase`, record type `BackstockSession`. The Backstock tab is fully team-feed driven — there is no separate "Mine" toggle; the AM's own boxes appear in the same list, scoped to the currently-selected store. Records are anonymous by design — no submitter identity, just `area / store / storeNumber / box / items / subtotal / retailTotal / status / submittedAt`.

**Required before production TestFlight:**
- Enable iCloud capability in Xcode (Signing & Capabilities → + Capability → iCloud → CloudKit → container `iCloud.com.jacent.BackstockTracker`)
- First app run auto-generates the Development schema on first save
- In the CloudKit Dashboard: make `submittedAt` **Sortable** and `area` **Queryable** (both under Schema → Indexes) before deploying to Production
- **Open `BackstockSession` write/delete permissions** — Schema → Record Types → BackstockSession → Security tab → set both **Write** and **Delete** to **Authenticated** (the public-DB default is **Creator**, which only lets the original submitter modify the record). This is what enables team-edit, the box delete affordance, and the pick-list "Remove from backstock" cross-AM workflow. Without it, any non-creator update returns `CKError.permissionFailure` ("WRITE operation not permitted").
- Deploy Schema to Production before App Store release

**Retry on launch:** `CloudSyncService.retryPending` sweeps for local sessions with `cloudSyncedAt == nil` and uploads them, so a network blip at submit time doesn't drop records from the team feed.

**Live update notification:** `Notification.Name.teamSessionDidUpdate` (userInfo `"record": TeamBackstockRecord`) is posted after any successful patch (edit-items, update-box, pick-list remove, merge). `StoreHistoryList` and `AreaBackstockView` both observe it and apply the scrub before merging the cleaned record into their state. Use this hook for any new in-place edit path — don't bypass it, or other open screens won't see the change until next reload.

## Firestore migration (scaffolding only)

`BackstockTracker/Backend/FirestoreSyncService.swift` is the planned cross-platform replacement for `CloudSyncService`. It's intentionally **not yet added to the Xcode target** — the file lives behind `#if canImport(FirebaseFirestore) && canImport(FirebaseAuth)` so it compiles to nothing today. The public API mirrors `CloudSyncService` 1:1 so call sites can be flipped behind a `useFirestore` feature flag. Activation checklist is in the file header. Do not start writing through it until SPM deps are added, the `useFirestore` flag exists, and the data-contract.md schema is signed off.

## Coding conventions

- **Comments:** Liberal explanatory comments on non-obvious logic, especially around sync, audio, mail composer wrappers, store-scoping edge cases, and the chain-name scrub. Match the existing tone — explain *why*, not *what*.
- **Edits:** Prefer surgical `str_replace` edits over full-file rewrites. Re-read the file region before editing — it's long (~10K lines) and easy to make wrong assumptions.
- **Brace balance:** After any non-trivial edit, verify braces balance. Use the helper command `/balance-check` (see `.claude/commands/`) or run the inline Python script in `scripts/balance.py`.
- **Imports at the top:** `SwiftUI, SwiftData, AudioToolbox, AVFoundation, BackgroundTasks, VisionKit, Vision, MessageUI, CloudKit`. Add new imports here, not inline.
- **No new dependencies without asking:** No SPM packages, no CocoaPods. The Firebase exemption is approved in principle but not yet activated. Anything else needs a conversation.
- **Error display:** Red errors auto-dismiss after 4s in the scan screen via `scanErrorBanner(message:)`.

## Build & test workflow

- **Build:** Open `~/jacent/BackstockTracker/BackstockTracker.xcodeproj` in Xcode → Cmd+R for simulator/device run.
- **Schema-change rebuild:** Delete the app from device/simulator first, then Cmd+R.
- **TestFlight:** Bump build number in General tab → Product → Archive → Distribute App → App Store Connect → Upload.
- **No unit tests yet.** When we add them, target the pure logic in `CatalogService`, `StoreService`, `SyncService.parse*`, `ScanSessionStore` total/limit math, and `CloudSyncService.scrubChainCorruption`.

## Common gotchas

- `MFMailComposeResult` is Equatable, but `Result<MFMailComposeResult, Error>` is NOT (because `any Error` isn't Equatable). State that needs `.onChange(of:)` should be the bare `MFMailComposeResult?`.
- `@AppStorage` only supports `String`, not `String?`. Use empty string for "not yet set."
- `EditButton` in toolbar didn't fire reliably in our setup; we use a manual `editMode` toggle instead.
- Stepper inside a List row intercepts tap-to-select in edit mode — hide the stepper when `editMode.isEditing`.
- Don't add `Done` button in keyboard toolbar — it overlapped the Submit button at small sizes.
- `dismiss-keyboard-on-outside-tap` was blocking swipe-to-delete handles. We use `scrollDismissesKeyboard(.immediately)` only.
- `StoreSyncCoordinator` writes via a fresh `ModelContext(container)`, so screens fetching the store list need a `@Query` (not `context.fetch(...)` from `@Environment`) to see updates.
- Any in-place edit path that mutates a CloudKit record MUST post `.teamSessionDidUpdate` with the updated `TeamBackstockRecord` in `userInfo["record"]` — otherwise `AreaBackstockView` and other open lists won't refresh until next reload.

## Outstanding work

- [ ] Info.plist: `NSCameraUsageDescription` (required for App Store / TestFlight)
- [ ] Info.plist: `BGAppRefreshTaskSchedulerPermittedIdentifiers` if we add background sync
- [ ] "Signed-in AM removed from roster" edge case
- [ ] Enable CloudKit capability in Xcode + deploy schema to production before TestFlight release
- [ ] Transfer Apple Dev account and iCloud container to Jacent-owned org
- [ ] Wire `FirestoreSyncService` into the build behind a `useFirestore` flag; dual-write one TestFlight cycle
- [ ] Android port — same Drive sources, same data-contract.md schema
