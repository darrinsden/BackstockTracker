//
//  BackstockTrackerApp.swift
//  Backstock Tracker
//
//  A single-file skeleton for Backstock Tracker, the Jacent Strategic Merchandising
//  Backstock tracking app. Drop this file into a new
//  iOS App project in Xcode (iOS 17+, Swift 5.9+, SwiftData).
//
//  Scope covered:
//    - SwiftData @Model types: Product, ScanSession, ScannedItem,
//      CatalogSync, AreaManager
//    - ScanSessionStore: @Observable in-memory store for the active
//      scan session, owns the running subtotal and limit logic
//    - CatalogService: UPC lookup backed by SwiftData
//    - SyncService: SharePoint/CSV pull, parse, atomic catalog replace
//    - AudioService: error buzzer via AudioServices
//    - ScanView: keyboard-wedge scanner input, manual override sheet on UPC miss
//
//  Not yet wired here (add as follow-ups):
//    - HistoryView, SessionDetailView, SettingsView, ManualPriceSheet
//      body layouts — stubs only
//    - Microsoft Graph / SharePoint auth (MSAL) — replace the URL
//      fetch in SyncService.fetchCSV()
//    - BGAppRefreshTask registration in AppDelegate — commented hook
//      provided
//

import SwiftUI
import SwiftData
import AudioToolbox
import AVFoundation
import BackgroundTasks
import VisionKit
import Vision
import MessageUI
import CloudKit

// MARK: - Theme

// Jacent-branded color palette. Applied app-wide via .tint() on the
// root view (LaunchCoordinator), so every Button / NavigationLink /
// progress indicator picks up the muted teal automatically. Errors,
// warnings, and success states stay on their semantic system colors
// (red / orange / green) — those carry meaning and shouldn't be
// re-tinted.
//
// Hex values mirror the Jacent marketing materials:
//   • teal    — primary brand surface ("jacent" logo background)
//   • yellow  — secondary accent (the "Retail made easier." tagline)
//   • cream   — soft light surface for tinted headers
//   • ink     — warm dark for emphasis text
extension Color {
    // Primary brand tint — muted teal/sea-green. Adaptive: a touch
    // brighter on dark so it carries the same energy against a
    // black-ish background.
    static let jacentTeal = Color(
        light: Color(red: 0x4A / 255, green: 0x9B / 255, blue: 0x97 / 255),
        dark:  Color(red: 0x5F / 255, green: 0xB5 / 255, blue: 0xB1 / 255)
    )

    // Secondary brand accent — warm sun yellow. Used for highlights
    // (over-limit chips, "draft saved" toast accent stripe, etc.)
    // rather than primary actions. We don't override .tint with it
    // because two competing tints in toolbars look chaotic.
    static let jacentYellow = Color(
        light: Color(red: 0xF0 / 255, green: 0xC2 / 255, blue: 0x4A / 255),
        dark:  Color(red: 0xF6 / 255, green: 0xCE / 255, blue: 0x66 / 255)
    )

    // Soft cream surface, slightly desaturated from pure white. Use
    // sparingly — tinted headers, picker chrome, etc. Most of the
    // app continues to use the system grouped backgrounds for
    // accessibility/contrast reasons.
    static let jacentCream = Color(
        light: Color(red: 0xF6 / 255, green: 0xF3 / 255, blue: 0xEC / 255),
        dark:  Color(red: 0x1F / 255, green: 0x26 / 255, blue: 0x26 / 255)
    )

    // Warm dark used for emphatic foreground text on tinted surfaces
    // where pure `.primary` reads too cold against the teal/cream.
    static let jacentInk = Color(
        light: Color(red: 0x1E / 255, green: 0x33 / 255, blue: 0x33 / 255),
        dark:  Color(red: 0xEC / 255, green: 0xF1 / 255, blue: 0xEF / 255)
    )

    // Convenience alias kept around so call sites can refer to
    // "the brand tint" without naming a specific hue — if Jacent
    // ever rebrands, only this extension changes.
    static var brandAccent: Color { jacentTeal }

    // Helper init that picks between light/dark variants without
    // requiring an asset catalog. Wraps UIColor's dynamic provider.
    init(light: Color, dark: Color) {
        self = Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(dark)
                : UIColor(light)
        })
    }
}

// MARK: - Schema versioning
//
// Every persisted @Model type belongs to a VersionedSchema. The
// migration plan walks from the on-disk version up to the current one
// at launch, applying any registered MigrationStages along the way.
//
// HOW TO ADD A V2:
//   1. Copy `BackstockSchemaV1` to `BackstockSchemaV2`. Bump
//      `versionIdentifier`.
//   2. Make whatever schema change you need INSIDE V2 — adding fields,
//      removing fields, renaming types. The compiler will tell you
//      what else needs to move (the top-level type aliases below).
//   3. Add a `MigrationStage` to `BackstockMigrationPlan.stages`. Use
//      `.lightweight(fromVersion:toVersion:)` for additive changes;
//      `.custom(...)` when you need to populate new fields from old
//      ones, split a type, etc.
//   4. Update `BackstockMigrationPlan.schemas` to include V2.
//
// The single-file project keeps `Product`, `ScanSession`, etc. as
// top-level types (where the rest of the code references them). V1
// just lists those same types; V2+ will need to either keep the names
// at top-level and migrate-in-place or introduce nested versioned
// copies. Either is fine — pick whichever is shorter for the change.

enum BackstockSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            Product.self,
            ScanSession.self,
            ScannedItem.self,
            CatalogSync.self,
            AreaManager.self,
            AreaManagerSync.self,
            Store.self,
            StoreSync.self
        ]
    }
}

enum BackstockMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [BackstockSchemaV1.self]
    }

    /// Empty until V2 lands. Each subsequent version contributes one
    /// stage describing how to get from the previous version's shape
    /// to its own.
    static var stages: [MigrationStage] {
        []
    }
}

// MARK: - App entry

@main
struct BackstockTrackerApp: App {
    // Shared SwiftData container. All @Model types registered here.
    //
    // DEV-MODE RECOVERY: Any change to a @Model type produces a schema
    // that's incompatible with the on-disk store, which makes the
    // initial ModelContainer() throw. Rather than crashing and forcing
    // the dev to delete + reinstall the app, we catch the first failure,
    // nuke the SwiftData store files on disk, and retry once. Only the
    // second failure is a true fatal.
    //
    // This is STILL a dev-only workaround — it silently destroys local
    // audit history whenever the schema drifts. Before we ship to real
    // users with real data, swap this for a VersionedSchema migration
    // plan (see "Outstanding work" in CLAUDE.md).
    // Result of trying to bring up the SwiftData container. `container`
    // is nil only when ModelContainer init throws even with the
    // VersionedSchema migration plan applied — i.e. real disk / sandbox
    // failures, not schema drift. The user gets the StorageErrorView in
    // that case rather than a crash.
    let container: ModelContainer?
    let bootError: BootError?

    init() {
        let result = Self.makeContainer()
        self.container = result.container
        self.bootError = result.error
    }

    /// Open the SwiftData store using `BackstockMigrationPlan`. The
    /// migration plan handles forward-compatible schema evolution
    /// automatically: lightweight changes (added optional properties,
    /// new @Model types, new indexes) just work, and breaking changes
    /// get explicit `MigrationStage.custom` entries when we add a V2.
    ///
    /// No more wipe-and-retry — that was a dev-only band-aid for the
    /// previous crash-on-schema-drift behavior, and would silently
    /// destroy user data in production. Real init failures now route
    /// to StorageErrorView so the user can read what happened.
    private static func makeContainer() -> (container: ModelContainer?, error: BootError?) {
        // CRITICAL: cloudKitDatabase: .none disables SwiftData's
        // automatic private-database mirroring. Without this, enabling
        // the iCloud/CloudKit capability in Xcode makes SwiftData try
        // to sync every @Model to the user's private CloudKit DB —
        // which requires every attribute to be optional and no unique
        // constraints, neither of which our schema satisfies.
        //
        // Our CloudKit use is intentional and narrow: CloudSyncService
        // writes team sessions to the PUBLIC database directly. We
        // never want SwiftData syncing the local audit store to iCloud.
        let schema = Schema(versionedSchema: BackstockSchemaV1.self)
        let config = ModelConfiguration(
            schema: schema,
            cloudKitDatabase: .none
        )
        print("ℹ️ SwiftData store URL: \(config.url.path)")

        do {
            let container = try ModelContainer(
                for: schema,
                migrationPlan: BackstockMigrationPlan.self,
                configurations: [config]
            )
            return (container, nil)
        } catch {
            print("🛑 ModelContainer init failed under migration plan: \(error)")
            return (nil, BootError(message: "\(error)"))
        }
    }

    /// Captured details from a failed container init. Surfaced verbatim
    /// in StorageErrorView so the user (or support) has something to
    /// copy / paste when reporting the problem.
    struct BootError {
        let message: String

        var summary: String {
            "Backstock Tracker can't open its local storage. This is " +
            "almost always fixed by deleting the app and reinstalling " +
            "it from TestFlight — submitted sessions are stored in the " +
            "cloud and will reappear after sign-in."
        }

        var diagnosticDetails: String { message }
    }


    var body: some Scene {
        WindowGroup {
            // If the container came up cleanly, render the normal app.
            // If not, the user gets an explanatory screen instead of a
            // crash. We deliberately do NOT attach .modelContainer() in
            // the error branch — there's no usable container, and the
            // error view doesn't query SwiftData.
            if let container, bootError == nil {
                LaunchCoordinator()
                    .environment(ScanSessionStore())
                    // Singleton — persists across screens, tabs, and
                    // app launches. Backstock search rows toggle
                    // entries; the toolbar pick-list button on the
                    // Backstock contents screen presents the sheet.
                    .environment(PickListStore.shared)
                    // Jacent-branded accent applied at the root so it
                    // cascades through every NavigationStack, Button,
                    // toolbar item, and progress indicator in the app.
                    .tint(.jacentTeal)
                    .task {
                        // Prime the audio service so its session config runs
                        // during launch, not on first scan.
                        _ = AudioService.shared
                        // AM roster syncs on app launch only. The catalog
                        // has its own schedule (foreground + BGAppRefresh).
                        await syncAreaManagersOnLaunch(container: container)
                    }
                    .modelContainer(container)
            } else {
                StorageErrorView(error: bootError ?? BootError(
                    message: "Container is nil but no error was captured."
                ))
                .tint(.jacentTeal)
            }
        }
    }

    // Container is now passed in explicitly because the property is
    // Optional — the call site has already unwrapped it via the `if let`
    // guard in `body`, so this function works against a known-good
    // container without re-checking.
    private func syncAreaManagersOnLaunch(container: ModelContainer) async {
        // Run all four syncs in parallel. Roster blocks the UI
        // (LaunchCoordinator waits on it). The others run non-blocking —
        // the UI loads immediately and each table populates in the
        // background while the AM picks their identity.
        async let roster: Void = RosterSyncCoordinator.shared.run(container: container)
        async let catalog: Void = CatalogSyncCoordinator.shared.run(container: container)
        async let stores: Void = StoreSyncCoordinator.shared.run(container: container)
        _ = await (roster, catalog, stores)

        // After the local tables are populated, sweep for any submitted
        // sessions whose CloudKit upload never succeeded (network blip,
        // iCloud-not-signed-in on submit, etc.) and retry them. Runs
        // after the catalog/stores syncs so buildPayload can find the
        // store + product rows it needs to decorate the payload.
        await CloudSyncService.retryPending(
            container: container,
            catalogContext: { ModelContext(container) }
        )
    }
}

// MARK: - StorageErrorView
//
// Last-resort screen when the SwiftData container can't be brought up,
// even after a recovery wipe and an in-memory fallback. This used to be
// a fatalError(), which gave the user a hard crash and no signal. Now
// they get something they can read and act on.

struct StorageErrorView: View {
    let error: BackstockTrackerApp.BootError
    @State private var showDetails = false
    @State private var copied = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.jacentYellow)

            VStack(spacing: 12) {
                Text("Storage couldn't start")
                    .font(.title2).fontWeight(.semibold)
                    .multilineTextAlignment(.center)
                Text(error.summary)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)

            VStack(spacing: 12) {
                Button {
                    UIPasteboard.general.string = error.diagnosticDetails
                    copied = true
                    // Reset the "Copied" affordance after a beat so the
                    // user can copy again if they need to paste twice.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy diagnostics",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    showDetails.toggle()
                } label: {
                    Label(showDetails ? "Hide details" : "Show details",
                          systemImage: showDetails
                              ? "chevron.up"
                              : "chevron.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.horizontal, 32)

            if showDetails {
                ScrollView {
                    Text(error.diagnosticDetails)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 32)
                }
                .frame(maxHeight: 240)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Spacer()

            Text("After reinstalling, sign in again with your employee number — your team's submitted sessions are stored in the cloud and will reappear.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .animation(.easeInOut(duration: 0.2), value: showDetails)
        .animation(.easeInOut(duration: 0.2), value: copied)
    }
}

// MARK: - Roster sync coordinator

// Shared, observable handle to the launch-time AM roster sync. The
// LoadingRosterView watches this to show syncing / failed / done states,
// and lets the user retry without relaunching the app.
@Observable
final class RosterSyncCoordinator {
    static let shared = RosterSyncCoordinator()

    enum State {
        case idle
        case syncing
        case succeeded(count: Int)
        case failed(message: String)
    }

    var state: State = .idle

    // Google Drive share URL for area_managers.csv.
    // Either share link format works — the SyncService normalizes it.
    private let sourceURL = URL(string: "https://drive.google.com/file/d/1rOFqR8IDo4lEJmT39tHtw7JsLggOauxf")!

    private init() {}

    @MainActor
    func run(container: ModelContainer) async {
        state = .syncing
        let service = SyncService(sourceURL: sourceURL)
        let record = await service.syncAreaManagers(into: container)
        let context = ModelContext(container)
        context.insert(record)
        try? context.save()
        switch record.status {
        case .success: state = .succeeded(count: record.managerCount)
        case .failed, .partial: state = .failed(message: record.errorMessage ?? "Unknown error")
        }
    }
}

// Background catalog sync. Runs at app launch alongside the roster sync,
// but unlike the roster sync, this is non-blocking — the app UI loads
// immediately and the catalog populates when ready. This lets the AM
// start navigating while we pull the product list in the background.
@Observable
@MainActor
final class CatalogSyncCoordinator {
    static let shared = CatalogSyncCoordinator()

    enum State {
        case idle
        case syncing
        case succeeded(count: Int)
        case failed(message: String)
    }

    var state: State = .idle

    // Google Drive share URL for catalog.csv.
    // Either share link format works — the SyncService normalizes it.
    private let sourceURL = URL(string: "https://drive.google.com/file/d/1izR-bDANhkOBlOyvgB9k4gCHOUSn6x5n")!

    private init() {}

    @MainActor
    func run(container: ModelContainer) async {
        state = .syncing
        let service = SyncService(sourceURL: sourceURL)
        let record = await service.sync(into: container)
        let context = ModelContext(container)
        context.insert(record)
        try? context.save()
        switch record.status {
        case .success: state = .succeeded(count: record.productCount)
        case .failed, .partial: state = .failed(message: record.errorMessage ?? "Unknown error")
        }
    }
}

// Background stores sync. Runs at app launch alongside the roster and
// catalog syncs. Populates the Store table, which drives the two
// dependent pickers on the scan screen.
@Observable
@MainActor
final class StoreSyncCoordinator {
    static let shared = StoreSyncCoordinator()

    enum State {
        case idle
        case syncing
        case succeeded(count: Int)
        case failed(message: String)
    }

    var state: State = .idle

    // Google Drive share URL for stores.csv.
    // Either share link format works — the SyncService normalizes it.
    private let sourceURL = URL(string: "https://drive.google.com/file/d/1WtggB4_n1G2avUV4q0Di4VRjG2ZdrEh3")!

    private init() {}

    @MainActor
    func run(container: ModelContainer) async {
        state = .syncing
        let service = SyncService(sourceURL: sourceURL)
        let record = await service.syncStores(into: container)
        let context = ModelContext(container)
        context.insert(record)
        try? context.save()
        switch record.status {
        case .success: state = .succeeded(count: record.storeCount)
        case .failed, .partial: state = .failed(message: record.errorMessage ?? "Unknown error")
        }
    }
}

// MARK: - Models (SwiftData)

@Model
final class Product {
    // UPC is no longer unique — the same UPC can appear in multiple stores
    // (e.g. Target vs. Walmart carrying the same product at different
    // prices). The composite (upc, store) is the logical primary key,
    // enforced at sync time by the full-replace catalog sync rather than
    // a DB constraint.
    var upc: String
    var name: String
    // Wholesale / credit price — the value that accumulates against
    // the session's $149.99 limit.
    var price: Decimal
    // Merchandising bucket from catalog.csv (column "commodity" —
    // previously "category"). Kept optional so old rows or rows
    // missing the column parse cleanly.
    var commodity: String?
    // Store name (the retailer chain: "Target", "Walmart"). The specific
    // store number is NOT on the product — it's on the Store entity below,
    // which maps chains to their specific numbered locations.
    var store: String
    // Retail price (what the item sells for on the shelf). Optional so
    // rows that don't yet carry it parse cleanly. Shown separately from
    // `price` in UI where both are useful (e.g. margin-at-a-glance).
    var retailPrice: Decimal?
    // Merchandising rank — lower-is-better ordering hint from the
    // catalog source, used for default sort in future surfaces.
    // Optional because older/partial catalogs omit it.
    var rank: Int?
    var lastUpdated: Date

    init(upc: String,
         name: String,
         price: Decimal,
         commodity: String? = nil,
         store: String = "",
         retailPrice: Decimal? = nil,
         rank: Int? = nil,
         lastUpdated: Date = .now) {
        self.upc = upc
        self.name = name
        self.price = price
        self.commodity = commodity
        self.store = store
        self.retailPrice = retailPrice
        self.rank = rank
        self.lastUpdated = lastUpdated
    }
}

// Store entity: maps a store name (retailer chain) to its specific
// numbered locations. Populated from stores.csv. A single store name
// typically has multiple store numbers (e.g. "Target" has #1842,
// #4213, etc.). Each store is also scoped to an area so the scan
// screen can filter the picker to only the stores the signed-in AM
// actually covers.
@Model
final class Store {
    var store: String
    var storeNumber: String
    var area: String
    // Optional compact label for cramped UI surfaces (e.g. history rows,
    // picker summaries). Empty string = no shortname set; callers should
    // fall back to `store`. Kept in addition to `store` rather than
    // replacing it so the canonical name stays available for emails,
    // print headers, and CSV round-trips.
    var shortName: String
    var lastUpdated: Date

    init(store: String,
         storeNumber: String,
         area: String = "",
         shortName: String = "",
         lastUpdated: Date = .now) {
        self.store = store
        self.storeNumber = storeNumber
        self.area = area
        self.shortName = shortName
        self.lastUpdated = lastUpdated
    }

    /// What to show in space-constrained UI. Uses shortName when
    /// provided, otherwise falls back to the full store name.
    var displayName: String {
        shortName.isEmpty ? store : shortName
    }
}

@Model
final class AreaManager {
    @Attribute(.unique) var employeeNumber: String
    var firstName: String
    var lastName: String
    var territory: String   // broader grouping
    var area: String        // the AM's slice within a territory
    var email: String       // for CC on TM approval emails; empty if unknown

    var fullName: String { "\(firstName) \(lastName)" }

    init(employeeNumber: String,
         firstName: String,
         lastName: String,
         territory: String,
         area: String,
         email: String = "") {
        self.employeeNumber = employeeNumber
        self.firstName = firstName
        self.lastName = lastName
        self.territory = territory
        self.area = area
        self.email = email
    }
}

enum SessionStatus: String, Codable, CaseIterable {
    case active
    case submitted
    case abandoned
}

@Model
final class ScanSession {
    @Attribute(.unique) var id: UUID
    var employeeNumber: String           // FK -> AreaManager.employeeNumber
    var startedAt: Date
    var submittedAt: Date?
    var totalAmount: Decimal
    var statusRaw: String
    var notes: String?
    var storeNumber: String?
    // Physical box this session is packed into — 1…10, picked on the
    // scan screen alongside store + store number. Optional so pre-box
    // sessions and "I forgot to pick" cases don't crash.
    var box: Int?
    var catalogSyncedAt: Date?           // catalog freshness at session time
    // Timestamp of successful CloudKit public-database upload. nil until
    // we've pushed this session up; non-nil once the team-view record
    // is live in iCloud. On a failed/deferred upload we leave it nil so
    // `CloudSyncService.retryPending` picks it back up on next launch.
    var cloudSyncedAt: Date?

    // Relationship: a session has many scanned items. Deleting a session
    // cascades to its items.
    @Relationship(deleteRule: .cascade, inverse: \ScannedItem.session)
    var items: [ScannedItem] = []

    var status: SessionStatus {
        get { SessionStatus(rawValue: statusRaw) ?? .active }
        set { statusRaw = newValue.rawValue }
    }

    init(id: UUID = UUID(),
         employeeNumber: String,
         startedAt: Date = .now,
         status: SessionStatus = .active,
         storeNumber: String? = nil,
         box: Int? = nil,
         catalogSyncedAt: Date? = nil) {
        self.id = id
        self.employeeNumber = employeeNumber
        self.startedAt = startedAt
        self.submittedAt = nil
        self.totalAmount = 0
        self.statusRaw = status.rawValue
        self.notes = nil
        self.storeNumber = storeNumber
        self.box = box
        self.catalogSyncedAt = catalogSyncedAt
        self.cloudSyncedAt = nil
    }
}

@Model
final class ScannedItem {
    @Attribute(.unique) var id: UUID
    var upc: String
    // Denormalized: we store the name/price AT SCAN TIME so the audit
    // log reflects historical prices even if the catalog changes later.
    var name: String
    var price: Decimal
    var quantity: Int
    var manualOverride: Bool
    var overrideNote: String?
    var scannedAt: Date

    var session: ScanSession?

    // Line total = price × quantity. Kept as a computed property so
    // audit readers don't risk stale values from manual edits.
    var lineTotal: Decimal {
        price * Decimal(quantity)
    }

    init(id: UUID = UUID(),
         upc: String,
         name: String,
         price: Decimal,
         quantity: Int = 1,
         manualOverride: Bool = false,
         overrideNote: String? = nil,
         scannedAt: Date = .now,
         session: ScanSession? = nil) {
        self.id = id
        self.upc = upc
        self.name = name
        self.price = price
        self.quantity = quantity
        self.manualOverride = manualOverride
        self.overrideNote = overrideNote
        self.scannedAt = scannedAt
        self.session = session
    }
}

enum SyncStatus: String, Codable {
    case success
    case failed
    case partial
}

@Model
final class CatalogSync {
    @Attribute(.unique) var id: UUID
    var syncedAt: Date
    var productCount: Int
    var sourceUrl: String
    var statusRaw: String
    var errorMessage: String?

    var status: SyncStatus {
        get { SyncStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }

    init(id: UUID = UUID(),
         syncedAt: Date = .now,
         productCount: Int,
         sourceUrl: String,
         status: SyncStatus,
         errorMessage: String? = nil) {
        self.id = id
        self.syncedAt = syncedAt
        self.productCount = productCount
        self.sourceUrl = sourceUrl
        self.statusRaw = status.rawValue
        self.errorMessage = errorMessage
    }
}

@Model
final class AreaManagerSync {
    @Attribute(.unique) var id: UUID
    var syncedAt: Date
    var managerCount: Int
    var sourceUrl: String
    var statusRaw: String
    var errorMessage: String?

    var status: SyncStatus {
        get { SyncStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }

    init(id: UUID = UUID(),
         syncedAt: Date = .now,
         managerCount: Int,
         sourceUrl: String,
         status: SyncStatus,
         errorMessage: String? = nil) {
        self.id = id
        self.syncedAt = syncedAt
        self.managerCount = managerCount
        self.sourceUrl = sourceUrl
        self.statusRaw = status.rawValue
        self.errorMessage = errorMessage
    }
}

// Parallel audit record for the stores.csv sync.
@Model
final class StoreSync {
    @Attribute(.unique) var id: UUID
    var syncedAt: Date
    var storeCount: Int
    var sourceUrl: String
    var statusRaw: String
    var errorMessage: String?

    var status: SyncStatus {
        get { SyncStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }

    init(id: UUID = UUID(),
         syncedAt: Date = .now,
         storeCount: Int,
         sourceUrl: String,
         status: SyncStatus,
         errorMessage: String? = nil) {
        self.id = id
        self.syncedAt = syncedAt
        self.storeCount = storeCount
        self.sourceUrl = sourceUrl
        self.statusRaw = status.rawValue
        self.errorMessage = errorMessage
    }
}

// MARK: - CloudKit team sync
//
// Every submitted session gets pushed to the shared CloudKit public
// database so other AMs in the org can see the "boxes of backstock"
// their teammates have recorded. We deliberately do NOT include any
// submitter identity — the record is about the physical box of
// backstock (store, store #, box number, item list), not who packed it.
//
// Database: CKContainer(identifier: "iCloud.com.jacent.BackstockTracker")
//           .publicCloudDatabase
//
// Record type: "BackstockSession"
// Fields:
//   sessionUUID   String (dedupe key — matches ScanSession.id)
//   area          String (the AM's area slice — used for filtering)
//   storeName     String
//   storeNumber   String
//   box           Int64? (optional)
//   status        String ("submitted" | "overLimit")
//   subtotal      Double
//   retailTotal   Double
//   submittedAt   Date/Time
//   itemsJSON     String (JSON-encoded [CloudSyncItem])
//
// Items are embedded as JSON rather than as child CKRecords because
// sessions are small (tens of items, well under the 1MB record cap)
// and a single-record model avoids parent/child query complexity.
//
// IMPORTANT — one-time setup required before this works:
//   1. Xcode → BackstockTracker target → Signing & Capabilities →
//      + Capability → iCloud → check CloudKit → add container
//      "iCloud.com.jacent.BackstockTracker".
//   2. First run generates the schema in Development. Before TestFlight,
//      deploy the schema to Production in the CloudKit Dashboard AND
//      make `submittedAt` Sortable and `area` Queryable in the schema
//      indexes tab so the team-view query works.

// Flat, Sendable snapshot of a session ready to be uploaded. Built on
// the main actor from SwiftData objects, then passed across actor
// boundaries to the CloudSyncService without dragging @Model refs along.
struct PendingCloudUpload: Sendable {
    let sessionUUID: String
    let area: String
    let storeName: String
    let storeNumber: String
    let box: Int?
    let status: String
    let subtotal: Double
    let retailTotal: Double
    let submittedAt: Date
    let items: [CloudSyncItem]
}

// Line-item payload embedded into the session's itemsJSON blob.
// Kept Codable so we can round-trip through JSONEncoder/Decoder.
// retailPrice / rank / commodity are resolved live from the catalog
// at upload time — they may be nil if the item wasn't in the catalog
// (manual overrides) or if the catalog didn't carry those fields.
struct CloudSyncItem: Codable, Hashable, Sendable {
    let upc: String
    let name: String
    let quantity: Int
    let price: Double
    let retailPrice: Double?
    let rank: Int?
    let commodity: String?
}

// Read-only representation of a team session fetched from CloudKit.
// Identifiable/Hashable so SwiftUI List can key off it.
struct TeamBackstockRecord: Identifiable, Hashable, Sendable {
    let id: String                 // sessionUUID
    let recordName: String         // CKRecord.ID.recordName for refetch
    let area: String
    let storeName: String
    let storeNumber: String
    // Mutable so the History edit flow can patch the box number in
    // place after a CloudKit update, without needing to rebuild the
    // whole struct or wait on a full refetch.
    var box: Int?
    let status: String
    // Mutable for the detail-view edit flow (change quantity / remove
    // item). Subtotal + retailTotal are recomputed from `items` on
    // every edit so the record stays internally consistent.
    var subtotal: Double
    var retailTotal: Double
    let submittedAt: Date
    var items: [CloudSyncItem]
}

// CloudKit sync service. Wraps CKContainer.publicCloudDatabase and
// handles marshaling between PendingCloudUpload / TeamBackstockRecord
// and CKRecord. Kept as an actor so concurrent uploads don't trip over
// each other, and so callers can `try await` without worrying about
// thread-safety on the underlying container.
actor CloudSyncService {
    static let shared = CloudSyncService()

    static let containerIdentifier = "iCloud.com.jacent.BackstockTracker"
    static let recordType = "BackstockSession"

    private let container: CKContainer
    private var database: CKDatabase { container.publicCloudDatabase }

    // Records we just uploaded but that CKQuery hasn't surfaced yet.
    // Public-DB queries are eventually consistent — a save returns
    // success, but the next CKQuery may not include the saved record
    // for several seconds (sometimes longer). Without this cache, the
    // History view's reload() would replace the optimistic notification
    // injection with a fetch that's missing the just-saved row, and
    // the AM would see their box vanish until CK caught up.
    //
    // Entries auto-evict the next time fetchAll sees the same id come
    // back from the server, so the cache shrinks naturally as records
    // become server-visible. Cold app launch wipes the cache, by which
    // point CKQuery is virtually always consistent (and retryPending
    // re-uploads anything still marked cloudSyncedAt == nil locally).
    private var optimisticPending: [String: TeamBackstockRecord] = [:]

    private init() {
        self.container = CKContainer(identifier: CloudSyncService.containerIdentifier)
    }

    // Register a freshly-uploaded record so fetchAll merges it into
    // every query result until the server starts returning it. Call
    // this immediately after a successful upload, before posting the
    // .teamSessionDidUpdate notification — that way any History view
    // not currently mounted (e.g. AM is still on the Scan tab) still
    // sees the record on its next reload().
    func registerOptimistic(_ record: TeamBackstockRecord) {
        optimisticPending[record.id] = record
    }

    // Save (or update) one session to the public DB. We key the record
    // on sessionUUID so re-uploads of the same session overwrite rather
    // than duplicate — matters for `retryPending`, which may race with
    // a successful upload that just hadn't marked cloudSyncedAt yet.
    func upload(_ payload: PendingCloudUpload) async throws {
        let recordID = CKRecord.ID(recordName: payload.sessionUUID)
        let record = CKRecord(recordType: CloudSyncService.recordType, recordID: recordID)
        record["sessionUUID"] = payload.sessionUUID as CKRecordValue
        record["area"]        = payload.area as CKRecordValue
        record["storeName"]   = payload.storeName as CKRecordValue
        record["storeNumber"] = payload.storeNumber as CKRecordValue
        if let box = payload.box {
            record["box"] = box as CKRecordValue
        }
        record["status"]      = payload.status as CKRecordValue
        record["subtotal"]    = payload.subtotal as CKRecordValue
        record["retailTotal"] = payload.retailTotal as CKRecordValue
        record["submittedAt"] = payload.submittedAt as CKRecordValue

        let encoder = JSONEncoder()
        let itemsData = try encoder.encode(payload.items)
        let itemsJSON = String(data: itemsData, encoding: .utf8) ?? "[]"
        record["itemsJSON"] = itemsJSON as CKRecordValue

        // `.allKeys` so a retry overwrites every field even if some
        // were missing the first time around.
        let config = CKModifyRecordsOperation.Configuration()
        config.qualityOfService = .utility

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let op = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
            op.configuration = config
            op.savePolicy = .allKeys
            op.modifyRecordsResultBlock = { result in
                switch result {
                case .success: cont.resume()
                case .failure(let err): cont.resume(throwing: err)
                }
            }
            database.add(op)
        }
    }

    // Patch a single field on an existing record: the physical box
    // number. Used when an AM realizes after submit that a box was
    // recorded under the wrong number (e.g. they forgot to bump the
    // picker). We fetch-then-save because `.ifServerRecordUnchanged`
    // would reject our blind write, and `.changedKeys` would still
    // need the change-token which isn't worth carrying here for a
    // one-field patch.
    func updateBox(sessionUUID: String, box: Int?) async throws {
        let recordID = CKRecord.ID(recordName: sessionUUID)
        // Fetch first so we're updating the live record (preserves
        // server-only fields like modificationDate).
        let record: CKRecord = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CKRecord, Error>) in
            database.fetch(withRecordID: recordID) { rec, err in
                if let err { cont.resume(throwing: err); return }
                guard let rec else {
                    cont.resume(throwing: NSError(domain: "CloudSync", code: -1, userInfo: [NSLocalizedDescriptionKey: "Record not found"]))
                    return
                }
                cont.resume(returning: rec)
            }
        }
        if let box {
            record["box"] = box as CKRecordValue
        } else {
            // Clearing the box — CKRecord uses nil assignment to
            // remove a field. Cast through NSNumber? for clarity.
            record["box"] = nil
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let op = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
            op.qualityOfService = .userInitiated
            op.savePolicy = .changedKeys
            op.modifyRecordsResultBlock = { result in
                switch result {
                case .success: cont.resume()
                case .failure(let err): cont.resume(throwing: err)
                }
            }
            database.add(op)
        }
    }

    // Patch an existing record's line items + derived totals. Used
    // when an AM edits a submitted box — bumps a quantity, removes an
    // item that was scanned by mistake, etc. Like updateBox we
    // fetch-then-save so the live record's server-managed fields
    // (modificationDate, etc.) are preserved, and we send the full
    // items array rather than an incremental patch because CloudKit
    // stores them as one encoded JSON blob anyway.
    func updateItems(sessionUUID: String, items: [CloudSyncItem], subtotal: Double, retailTotal: Double) async throws {
        let recordID = CKRecord.ID(recordName: sessionUUID)
        let record: CKRecord = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CKRecord, Error>) in
            database.fetch(withRecordID: recordID) { rec, err in
                if let err { cont.resume(throwing: err); return }
                guard let rec else {
                    cont.resume(throwing: NSError(domain: "CloudSync", code: -1, userInfo: [NSLocalizedDescriptionKey: "Record not found"]))
                    return
                }
                cont.resume(returning: rec)
            }
        }
        let encoder = JSONEncoder()
        let itemsData = try encoder.encode(items)
        let itemsJSON = String(data: itemsData, encoding: .utf8) ?? "[]"
        record["itemsJSON"]   = itemsJSON as CKRecordValue
        record["subtotal"]    = subtotal as CKRecordValue
        record["retailTotal"] = retailTotal as CKRecordValue

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let op = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
            op.qualityOfService = .userInitiated
            op.savePolicy = .changedKeys
            op.modifyRecordsResultBlock = { result in
                switch result {
                case .success: cont.resume()
                case .failure(let err): cont.resume(throwing: err)
                }
            }
            database.add(op)
        }
    }

    // Delete a session from the public database by its sessionUUID.
    // Record IDs are deterministic from sessionUUID (see upload above)
    // so we can build the ID without an extra query. Used by the
    // History swipe-to-delete affordance — any AM can remove any box,
    // since the feed is intentionally shared/anonymous.
    func delete(sessionUUID: String) async throws {
        let recordID = CKRecord.ID(recordName: sessionUUID)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let op = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: [recordID])
            op.qualityOfService = .userInitiated
            op.modifyRecordsResultBlock = { result in
                switch result {
                case .success: cont.resume()
                case .failure(let err): cont.resume(throwing: err)
                }
            }
            database.add(op)
        }
    }

    // Fetch all team sessions (optionally filtered to the caller's area
    // so AMs only see records from their own slice). Sorted by
    // submittedAt descending, capped at a generous limit so we don't
    // drown the UI if a team has been busy.
    func fetchAll(area: String?, limit: Int = 200) async throws -> [TeamBackstockRecord] {
        let predicate: NSPredicate
        if let area, !area.isEmpty {
            predicate = NSPredicate(format: "area == %@", area)
        } else {
            predicate = NSPredicate(value: true)
        }
        let query = CKQuery(recordType: CloudSyncService.recordType, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "submittedAt", ascending: false)]

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[TeamBackstockRecord], Error>) in
            let op = CKQueryOperation(query: query)
            op.resultsLimit = limit
            op.qualityOfService = .userInitiated

            var collected: [TeamBackstockRecord] = []
            op.recordMatchedBlock = { _, result in
                switch result {
                case .success(let rec):
                    if let decoded = Self.decode(record: rec) {
                        collected.append(decoded)
                    }
                case .failure:
                    // Skip individual bad rows rather than failing the
                    // whole query — one malformed record shouldn't hide
                    // everything else.
                    break
                }
            }
            op.queryResultBlock = { result in
                switch result {
                case .success: cont.resume(returning: collected)
                case .failure(let err): cont.resume(throwing: err)
                }
            }
            database.add(op)
        }
        // ↑ raw server result. Below we fold in any optimistic records
        // not yet visible server-side, and evict ones the server now
        // returns (so the cache shrinks as records become consistent).
    }

    // Public wrapper that calls into the actor's raw fetch and then
    // overlays the optimistic pending cache. Filters optimistic
    // records by area to match the server-side predicate.
    func fetchAllMerged(area: String?, limit: Int = 200) async throws -> [TeamBackstockRecord] {
        let server = try await fetchAll(area: area, limit: limit)
        let serverIds = Set(server.map(\.id))
        // Evict any optimistic entries the server now returns — the
        // server copy is canonical from this point forward.
        for id in serverIds {
            optimisticPending.removeValue(forKey: id)
        }
        // Merge in the still-pending optimistic records, scoped to the
        // same area filter the server query used. Caller (HistoryView)
        // already sorts.
        let pending = optimisticPending.values.filter { rec in
            guard let area, !area.isEmpty else { return true }
            return rec.area == area
        }
        return server + pending
    }

    // Retry any local sessions that never got their cloud ack. Called
    // on app launch and after a successful upload (so a multi-session
    // backlog drains). Swallows per-session errors so one bad record
    // doesn't stall the rest.
    @MainActor
    static func retryPending(container: ModelContainer, catalogContext: @escaping () -> ModelContext) async {
        let context = catalogContext()
        let descriptor = FetchDescriptor<ScanSession>(
            predicate: #Predicate { $0.cloudSyncedAt == nil && $0.statusRaw != "active" }
        )
        guard let pending = try? context.fetch(descriptor), !pending.isEmpty else { return }

        let storeDescriptor = FetchDescriptor<Store>()
        let allStores = (try? context.fetch(storeDescriptor)) ?? []
        let productDescriptor = FetchDescriptor<Product>()
        let allProducts = (try? context.fetch(productDescriptor)) ?? []

        for session in pending {
            guard let payload = buildPayload(
                session: session,
                stores: allStores,
                products: allProducts
            ) else { continue }
            do {
                try await CloudSyncService.shared.upload(payload)
                session.cloudSyncedAt = .now
                try? context.save()
            } catch {
                // Leave cloudSyncedAt nil — we'll try again next launch.
                print("Cloud retry upload failed for \(session.id): \(error)")
            }
        }
    }

    // Build a PendingCloudUpload from a persisted session + local
    // catalog/store snapshots. Returns nil when we can't gather the
    // Mirror a freshly-built upload payload into the read-side
    // TeamBackstockRecord shape so the History view can optimistically
    // show the record the instant upload succeeds — without waiting on
    // CloudKit's public-DB CKQuery to become consistent (which can lag
    // 1–3+ seconds after a save). recordName matches sessionUUID
    // because that's how `upload` keys the CKRecord.ID.
    static func makeRecord(from payload: PendingCloudUpload) -> TeamBackstockRecord {
        TeamBackstockRecord(
            id: payload.sessionUUID,
            recordName: payload.sessionUUID,
            area: payload.area,
            storeName: payload.storeName,
            storeNumber: payload.storeNumber,
            box: payload.box,
            status: payload.status,
            subtotal: payload.subtotal,
            retailTotal: payload.retailTotal,
            submittedAt: payload.submittedAt,
            items: payload.items
        )
    }

    // minimum needed (store name/number missing) — such records would
    // be useless in the team view.
    @MainActor
    static func buildPayload(
        session: ScanSession,
        stores: [Store],
        products: [Product],
        // Fallback used when the resolved Store row has no area set
        // (or the row is missing entirely). Live submits pass the
        // AM's currently-selected area here so the record always
        // carries a non-empty `area` — without it, three independent
        // read-side area filters (CKQuery predicate, fetchAllMerged
        // optimistic filter, handleTeamSessionUpdate guard) all drop
        // the record, making the just-submitted box invisible to
        // the AM forever.
        fallbackArea: String = ""
    ) -> PendingCloudUpload? {
        guard let storeNumber = session.storeNumber, !storeNumber.isEmpty else { return nil }
        // Resolve store name + area from the Store table. If the store
        // number somehow isn't in the local stores.csv snapshot, we
        // still upload — just with empty strings, so the record at
        // least carries the box + items for someone to read.
        let storeRow = stores.first { $0.storeNumber == storeNumber }
        let storeName = storeRow?.store ?? ""
        let resolvedArea = storeRow?.area ?? ""
        // Empty area on the Store row → use the caller-provided
        // fallback (the AM's selectedArea on the live submit path).
        let area = resolvedArea.isEmpty ? fallbackArea : resolvedArea

        // Per-item: resolve retailPrice/rank/commodity from the catalog.
        // Manual overrides and un-catalogued UPCs simply get nil for
        // those fields, which the JSON cleanly omits.
        let items: [CloudSyncItem] = session.items
            .sorted { $0.scannedAt < $1.scannedAt }
            .map { item in
                let product = products.first { $0.upc == item.upc && $0.store == storeName }
                    ?? products.first { $0.upc == item.upc }
                return CloudSyncItem(
                    upc: item.upc,
                    name: item.name,
                    quantity: item.quantity,
                    price: NSDecimalNumber(decimal: item.price).doubleValue,
                    retailPrice: product?.retailPrice.map { NSDecimalNumber(decimal: $0).doubleValue },
                    rank: product?.rank,
                    commodity: product?.commodity
                )
            }

        let retailTotal: Double = items.reduce(0) { sum, it in
            sum + (it.retailPrice ?? 0) * Double(it.quantity)
        }

        return PendingCloudUpload(
            sessionUUID: session.id.uuidString,
            area: area,
            storeName: storeName,
            storeNumber: storeNumber,
            box: session.box,
            status: session.statusRaw,
            subtotal: NSDecimalNumber(decimal: session.totalAmount).doubleValue,
            retailTotal: retailTotal,
            submittedAt: session.submittedAt ?? session.startedAt,
            items: items
        )
    }

    // Decode a CKRecord back into our flat Sendable representation.
    // Returns nil on any missing required field — we treat those rows
    // as malformed and skip them in the team list.
    private static func decode(record: CKRecord) -> TeamBackstockRecord? {
        guard
            let uuid = record["sessionUUID"] as? String,
            let storeName = record["storeName"] as? String,
            let storeNumber = record["storeNumber"] as? String,
            let status = record["status"] as? String,
            let submittedAt = record["submittedAt"] as? Date
        else { return nil }
        let area = (record["area"] as? String) ?? ""
        let subtotal = (record["subtotal"] as? Double) ?? 0
        let retailTotal = (record["retailTotal"] as? Double) ?? 0
        let box = record["box"] as? Int
        let itemsJSON = (record["itemsJSON"] as? String) ?? "[]"
        let decoded: [CloudSyncItem] = (try? JSONDecoder().decode(
            [CloudSyncItem].self,
            from: Data(itemsJSON.utf8)
        )) ?? []
        return TeamBackstockRecord(
            id: uuid,
            recordName: record.recordID.recordName,
            area: area,
            storeName: storeName,
            storeNumber: storeNumber,
            box: box,
            status: status,
            subtotal: subtotal,
            retailTotal: retailTotal,
            submittedAt: submittedAt,
            items: decoded
        )
    }
}

// MARK: - Pick list store
//
// A cross-screen, cross-launch list of items the AM has flagged from
// the backstock search results. The use case: an AM searches /
// scans a few SKUs they need, flags each one, then carries the
// list back to actually pull them from the boxes.
//
// Persists to UserDefaults as JSON so a kill-and-relaunch doesn't
// drop the list. Keyed by (recordId, upc) so the same UPC flagged
// from two different boxes (same SKU stocked in multiple physical
// boxes) shows up as two distinct entries — exactly what the AM
// wants when they're walking back to pull each one separately.

struct PickListItem: Codable, Hashable, Identifiable {
    /// Unique per individual unit. The AM tracks each physical unit
    /// they need to pull as its own row — flagging "3 of X" produces
    /// three separate PickListItems. Generated on add; persists.
    let id: UUID
    let recordId: String       // CloudKit record id for the box
    let upc: String
    let name: String
    let box: Int?
    let storeName: String
    let storeNumber: String
    let price: Double
    let commodity: String?
    let addedAt: Date
    var picked: Bool
}

@Observable
@MainActor
final class PickListStore {
    static let shared = PickListStore()

    /// Bumped from v1 → v2 when the schema flipped from
    /// "one row per (record, upc) carrying a quantity" to "one row
    /// per individual unit." Old v1 data isn't migrated — the
    /// feature is new enough that any in-flight lists are
    /// disposable.
    private static let storageKey = "pickList.v2"

    private(set) var items: [PickListItem] = []

    private init() {
        load()
    }

    /// Number of individual units still to pull (not yet checked off).
    var pendingCount: Int { items.filter { !$0.picked }.count }

    /// Total flagged regardless of picked state — drives the "Clear
    /// picked" affordance visibility.
    var pickedCount: Int { items.filter { $0.picked }.count }

    /// True when at least one row exists for this (record, upc) pair.
    /// The bookmark icon on the search results uses this to flip
    /// between filled (flagged) and outlined (not).
    func isFlagged(recordId: String, upc: String) -> Bool {
        items.contains(where: { $0.recordId == recordId && $0.upc == upc })
    }

    /// Add `count` individual rows from the same template. Each gets
    /// its own UUID so the sheet can render and toggle them
    /// independently.
    func addRows(template: PickListItem, count: Int) {
        guard count > 0 else { return }
        for _ in 0..<count {
            var copy = template
            // Force a fresh id for every appended row even if the
            // template already had one. We can't rely on the caller
            // to mint UUIDs.
            copy = PickListItem(
                id: UUID(),
                recordId: template.recordId,
                upc: template.upc,
                name: template.name,
                box: template.box,
                storeName: template.storeName,
                storeNumber: template.storeNumber,
                price: template.price,
                commodity: template.commodity,
                addedAt: .now,
                picked: false
            )
            items.append(copy)
        }
        persist()
    }

    /// Bookmark-tap-while-flagged path — pulls every row for a
    /// given (record, upc) pair off the list in one shot, regardless
    /// of how many copies the AM had queued up.
    func removeAllFor(recordId: String, upc: String) {
        items.removeAll { $0.recordId == recordId && $0.upc == upc }
        persist()
    }

    func setPicked(_ id: UUID, picked: Bool) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].picked = picked
        persist()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    func clearPicked() {
        items.removeAll { $0.picked }
        persist()
    }

    func clearAll() {
        items.removeAll()
        persist()
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(items)
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        } catch {
            print("PickListStore persist failed: \(error)")
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey) else { return }
        do {
            items = try JSONDecoder().decode([PickListItem].self, from: data)
        } catch {
            print("PickListStore load failed: \(error)")
        }
    }
}

// MARK: - Session store (in-memory, observable)

// The active scan session lives in memory while an AM is scanning.
// Only on submit does it get persisted as a ScanSession. Abandoned
// sessions stay out of the audit log unless explicitly saved.
@Observable
final class ScanSessionStore {
    struct InMemoryItem: Identifiable, Hashable, Codable {
        let id: UUID
        let upc: String
        let name: String
        let price: Decimal
        var quantity: Int
        let manualOverride: Bool
        let overrideNote: String?
        let scannedAt: Date

        init(id: UUID = UUID(),
             upc: String,
             name: String,
             price: Decimal,
             quantity: Int = 1,
             manualOverride: Bool,
             overrideNote: String?,
             scannedAt: Date) {
            self.id = id
            self.upc = upc
            self.name = name
            self.price = price
            self.quantity = quantity
            self.manualOverride = manualOverride
            self.overrideNote = overrideNote
            self.scannedAt = scannedAt
        }

        var lineTotal: Decimal {
            price * Decimal(quantity)
        }
    }

    var items: [InMemoryItem] = []
    var currentEmployeeNumber: String = "UNASSIGNED"
    var currentStoreNumber: String?
    // Physical box number picked on the scan screen. Copied onto the
    // persisted ScanSession at submit time. nil = no box picked yet.
    var currentBox: Int?

    // Edit-mode plumbing. When non-nil, the scan session is "editing"
    // an already-submitted CloudKit record rather than building a new
    // box from scratch. Submit goes the update-existing-record path
    // (CloudSyncService.updateItems against this UUID) instead of the
    // insert-new-ScanSession path. The metadata fields are kept on the
    // store so the scan view can show "Editing Box N at Target #1842"
    // without re-fetching the source record.
    var editingRecordId: String?
    var editingRecordStoreName: String = ""
    var editingRecordStoreNumber: String = ""
    var editingRecordBox: Int?
    // Cached enough of the original CloudKit record at loadForEditing
    // time to rebuild a complete TeamBackstockRecord on submitEdit
    // success. We use that rebuilt record for the
    // "after-save, return to detail" navigation push — without it
    // we'd have to refetch from CloudKit (eventually consistent, may
    // miss the just-saved state).
    var editingRecordArea: String = ""
    var editingRecordStatus: String = "submitted"
    var editingRecordSubmittedAt: Date = .distantPast

    var subtotal: Decimal {
        items.reduce(0) { $0 + $1.lineTotal }
    }

    func add(_ item: InMemoryItem) {
        // If this UPC is already on the box, bump the existing line's
        // quantity instead of creating a second row. AMs scanning the
        // same SKU off a pallet expect "x3" on one line, not three
        // separate lines cluttering the list.
        //
        // Matched on UPC only — a single UPC has one catalog price,
        // and if the user manually added one earlier, re-scanning it
        // should still increment rather than duplicate.
        //
        // The scan list renders `store.items.reversed()` (see
        // ScanView.itemsList), so the *last* element of this array is
        // the visual top of the list. To make every touched item
        // (scan, re-scan, manual entry) appear at the top, we
        // append. For re-adds, that means removing the existing line
        // and re-appending the bumped copy.
        if let idx = items.firstIndex(where: { $0.upc == item.upc }) {
            var bumped = items.remove(at: idx)
            bumped.quantity += item.quantity
            items.append(bumped)
        } else {
            items.append(item)
        }
        AudioService.shared.playScanConfirm()
    }

    func remove(_ item: InMemoryItem) {
        items.removeAll { $0.id == item.id }
    }

    func setQuantity(id: UUID, quantity: Int) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].quantity = max(1, quantity)
    }

    func clear() {
        items.removeAll()
    }

    // MARK: - Edit existing record

    // Load an already-submitted cloud record back into the in-memory
    // session so the AM can fix it inside the regular Scan view (scan
    // more items, bump quantities, remove rows) and push the result
    // back to the same CloudKit record on submit. Wipes any in-flight
    // local items first — the caller is responsible for warning the AM
    // (or saving as draft) before calling this.
    //
    // Items are reconstructed from CloudSyncItem. retailPrice / rank /
    // commodity don't round-trip onto InMemoryItem (those fields aren't
    // part of the in-memory model — they're resolved fresh from the
    // catalog at submit/upload time). On save, updateItems re-computes
    // them from the live catalog the same way the scan flow does.
    @MainActor
    func loadForEditing(recordId: String,
                        storeName: String,
                        storeNumber: String,
                        box: Int?,
                        area: String,
                        status: String,
                        submittedAt: Date,
                        items cloudItems: [CloudSyncItem]) {
        items.removeAll()
        for ci in cloudItems {
            items.append(InMemoryItem(
                upc: ci.upc,
                name: ci.name,
                price: Decimal(ci.price),
                quantity: ci.quantity,
                manualOverride: false,
                overrideNote: nil,
                scannedAt: .now
            ))
        }
        editingRecordId = recordId
        editingRecordStoreName = storeName
        editingRecordStoreNumber = storeNumber
        editingRecordBox = box
        editingRecordArea = area
        editingRecordStatus = status
        editingRecordSubmittedAt = submittedAt
        currentStoreNumber = storeNumber
        currentBox = box
    }

    // Drop edit-mode state without touching items. Called after a
    // successful update-existing-record submit and from the explicit
    // "Cancel editing" path on the scan view.
    func endEditing() {
        editingRecordId = nil
        editingRecordStoreName = ""
        editingRecordStoreNumber = ""
        editingRecordBox = nil
        editingRecordArea = ""
        editingRecordStatus = "submitted"
        editingRecordSubmittedAt = .distantPast
    }

    var isEditingExistingRecord: Bool {
        editingRecordId != nil
    }

    // MARK: - Draft persistence
    //
    // A "draft" is a snapshot of an in-progress scan session (items +
    // the store/box context they were scanned under). It lives in
    // UserDefaults as JSON, so the AM can tap Save at any point, close
    // the app, and come back later to finish the box without losing
    // work. Drafts are single-slot — only the most recent save is kept —
    // and tagged with their store/box so a stale draft can't bleed into
    // a different location's scan session.
    //
    // Lifecycle:
    //   - User taps Save → saveDraft(...)
    //   - App launches / ScanView appears empty → loadDraftIfMatches(...)
    //     restores items only if the current store/box match the draft
    //   - Successful submit → clearDraft() (no stale draft left over)
    //   - User confirms Clear → clearDraft() (the intent was to wipe)
    private static let draftKey = "scanSession.draft"

    struct DraftPayload: Codable {
        var items: [InMemoryItem]
        var storeNumber: String
        var storeName: String
        var area: String
        var box: Int
        var savedAt: Date
    }

    @discardableResult
    func saveDraft(storeName: String, storeNumber: String, area: String, box: Int) -> Bool {
        guard !items.isEmpty else { return false }
        let payload = DraftPayload(
            items: items,
            storeNumber: storeNumber,
            storeName: storeName,
            area: area,
            box: box,
            savedAt: .now
        )
        guard let data = try? JSONEncoder().encode(payload) else { return false }
        UserDefaults.standard.set(data, forKey: Self.draftKey)
        return true
    }

    // Attempt to restore a saved draft. Only succeeds when the draft's
    // store/box matches what the caller passed in — we never want to
    // dump Box 3 at Target into Box 1 at Walmart just because the AM
    // happened to have an old draft lying around. Returns true iff
    // items were actually restored.
    @discardableResult
    func loadDraftIfMatches(storeNumber: String, box: Int) -> Bool {
        guard let data = UserDefaults.standard.data(forKey: Self.draftKey),
              let payload = try? JSONDecoder().decode(DraftPayload.self, from: data) else {
            return false
        }
        guard payload.storeNumber == storeNumber, payload.box == box else {
            return false
        }
        // Don't clobber an already-populated box with the draft — the
        // user may have started new scans since the draft was saved.
        // Only restore onto an empty session.
        guard items.isEmpty else { return false }
        items = payload.items
        return true
    }

    // Peek at the draft's savedAt (for the "Draft restored" toast so
    // we can tell the AM how old it is) without mutating anything.
    var draftSavedAt: Date? {
        guard let data = UserDefaults.standard.data(forKey: Self.draftKey),
              let payload = try? JSONDecoder().decode(DraftPayload.self, from: data) else {
            return nil
        }
        return payload.savedAt
    }

    func clearDraft() {
        UserDefaults.standard.removeObject(forKey: Self.draftKey)
    }

    // Persist the active session to SwiftData. Returns the inserted
    // ScanSession (discardable) so the caller can, e.g., kick off a
    // follow-up CloudKit upload using the persisted id + items.
    //
    // Empty boxes are allowed through intentionally: an AM may want
    // to "claim" a box number in the team feed before they've scanned
    // anything (so others see Box 4 exists at this store). The team
    // history view has a "Remove empty boxes" affordance for cleaning
    // up placeholders that never got filled in.
    @MainActor
    @discardableResult
    func submit(into context: ModelContext, catalogSyncedAt: Date?) throws -> ScanSession? {
        let session = ScanSession(
            employeeNumber: currentEmployeeNumber,
            status: .submitted,
            storeNumber: currentStoreNumber,
            box: currentBox,
            catalogSyncedAt: catalogSyncedAt
        )
        session.submittedAt = .now
        session.totalAmount = subtotal

        for memItem in items {
            let scanned = ScannedItem(
                upc: memItem.upc,
                name: memItem.name,
                price: memItem.price,
                quantity: memItem.quantity,
                manualOverride: memItem.manualOverride,
                overrideNote: memItem.overrideNote,
                scannedAt: memItem.scannedAt,
                session: session
            )
            session.items.append(scanned)
            context.insert(scanned)
        }
        context.insert(session)
        try context.save()
        clear()
        // Session landed in SwiftData — any pending draft is now stale,
        // wipe it so the next launch doesn't try to restore an already-
        // submitted box on top of a fresh scan.
        clearDraft()
        return session
    }
}

// MARK: - Catalog service

// Wraps UPC lookup, scoped to a specific store. A single UPC may appear
// in the catalog multiple times (once per store) with different prices
// and metadata — the scan screen provides the store context to disambiguate.
struct CatalogService {
    let context: ModelContext

    // Result of a UPC lookup, distinguishing three outcomes:
    // - .found: UPC exists in this store's catalog
    // - .wrongStore: UPC exists in the catalog but for a different store
    // - .notInCatalog: UPC doesn't exist anywhere in the catalog
    enum LookupResult {
        case found(Product)
        case wrongStore(availableAt: [String]) // list of store names where it is stocked
        case notInCatalog
    }

    // Store-scoped lookup. Matches UPC format-flexibly (12-digit UPC-A vs
    // 13-digit EAN-13) AND scopes the result to a specific store (retailer
    // chain). Returns a LookupResult so the caller can distinguish "wrong
    // store" from "not in catalog" in UI messaging.
    //
    // Note: the catalog tracks products per *store* (retailer), not per
    // *store number*. Two Target stores share the same catalog. Store
    // number is tracked separately on the scan session for audit.
    func lookup(upc: String, store: String) -> LookupResult {
        let candidates = upcCandidates(from: upc)

        // First pass: exact store match
        for candidate in candidates {
            let descriptor = FetchDescriptor<Product>(
                predicate: #Predicate {
                    $0.upc == candidate && $0.store == store
                }
            )
            if let match = try? context.fetch(descriptor).first {
                return .found(match)
            }
        }

        // Second pass: UPC is in catalog but for different store(s)?
        var otherStores: [String] = []
        for candidate in candidates {
            let descriptor = FetchDescriptor<Product>(
                predicate: #Predicate { $0.upc == candidate }
            )
            if let matches = try? context.fetch(descriptor) {
                for m in matches {
                    if !m.store.isEmpty && !otherStores.contains(m.store) {
                        otherStores.append(m.store)
                    }
                }
            }
        }

        return otherStores.isEmpty ? .notInCatalog : .wrongStore(availableAt: otherStores)
    }

    // Returns *any* catalog row matching the UPC (regardless of store),
    // used to pre-fill the manual-add sheet when the UPC exists in the
    // catalog for a different store. Tries the same format-flexibility
    // candidates as `lookup` so a 12/13-digit mismatch still finds it.
    func anyProduct(upc: String) -> Product? {
        let candidates = upcCandidates(from: upc)
        for candidate in candidates {
            let descriptor = FetchDescriptor<Product>(
                predicate: #Predicate { $0.upc == candidate }
            )
            if let match = try? context.fetch(descriptor).first {
                return match
            }
        }
        return nil
    }

    private func upcCandidates(from upc: String) -> [String] {
        var list = [upc]
        if upc.count == 13 && upc.hasPrefix("0") {
            list.append(String(upc.dropFirst()))
        }
        if upc.count == 12 {
            list.append("0" + upc)
        }
        return list
    }

    func lastSyncedAt() -> Date? {
        var descriptor = FetchDescriptor<CatalogSync>(
            predicate: #Predicate { $0.statusRaw == "success" },
            sortBy: [SortDescriptor(\.syncedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first?.syncedAt
    }

    func productCount() -> Int {
        (try? context.fetchCount(FetchDescriptor<Product>())) ?? 0
    }
}

// MARK: - Store service

// Wraps the Store table with helpers for the dependent pickers on the
// scan screen: one for distinct store names (chains), and one for the
// store numbers filtered to a specific chain. All methods accept an
// optional area filter so the scan screen can scope results to
// the signed-in AM's area.
//
// When `area` is empty string, no filtering is applied (returns
// all stores). This handles the partial-migration case where stores.csv
// doesn't yet have an area column.
struct StoreService {
    let context: ModelContext

    // Distinct store names (chains), sorted alphabetically, optionally
    // filtered to a single area.
    func distinctStoreNames(in area: String = "") -> [String] {
        let all = (try? context.fetch(FetchDescriptor<Store>())) ?? []
        var seen = Set<String>()
        var result: [String] = []
        for s in all where !s.store.isEmpty {
            // If an area filter is requested, only include stores
            // that either match the area OR have no area set
            // (partial-migration safety).
            if !area.isEmpty && !s.area.isEmpty && s.area != area {
                continue
            }
            if !seen.contains(s.store) {
                seen.insert(s.store)
                result.append(s.store)
            }
        }
        return result.sorted()
    }

    // Store numbers assigned to a given store chain, sorted, optionally
    // filtered to a single area.
    func storeNumbers(for storeName: String, in area: String = "") -> [String] {
        let descriptor = FetchDescriptor<Store>(
            predicate: #Predicate { $0.store == storeName }
        )
        let matches = (try? context.fetch(descriptor)) ?? []
        let filtered = matches.filter { s in
            if area.isEmpty { return true }
            if s.area.isEmpty { return true }
            return s.area == area
        }
        return filtered.map { $0.storeNumber }.sorted()
    }

    func storeCount() -> Int {
        (try? context.fetchCount(FetchDescriptor<Store>())) ?? 0
    }

    // Look up the shortName for a specific (storeName, storeNumber)
    // pair in the given area. Returns nil when no row matches or the
    // row has no shortName registered. Used for tight UI where the
    // long chain name won't fit.
    func shortName(for storeName: String, storeNumber: String, in area: String = "") -> String? {
        guard !storeName.isEmpty, !storeNumber.isEmpty else { return nil }
        let descriptor = FetchDescriptor<Store>(
            predicate: #Predicate { $0.store == storeName && $0.storeNumber == storeNumber }
        )
        let matches = (try? context.fetch(descriptor)) ?? []
        let filtered = matches.filter { s in
            if area.isEmpty { return true }
            if s.area.isEmpty { return true }
            return s.area == area
        }
        return filtered.first(where: { !$0.shortName.isEmpty })?.shortName
    }
}

// MARK: - Sync service

// Pulls the catalog CSV from a shared source and replaces the local
// Product table atomically. For SharePoint, swap fetchCSV() for a
// Microsoft Graph call using MSAL — see comments at the call site.
//
// CSV format expected (first row is header):
//   upc,name,price,commodity,store,retailPrice,rank
//   037000127116,Tide Pods 42ct,19.99,Laundry,Target,24.99,1
//
// Columns 4 (commodity) onward are optional for backward
// compatibility. `price` is the wholesale/credit price that counts
// against the session limit; `retailPrice` is the shelf price and is
// displayed separately. `rank` is a numeric merchandising priority
// (lower is more prominent) — parsed when present, ignored otherwise.
//
// Prices parse as Decimal via NSDecimalNumber(string:) to avoid
// floating-point drift.
actor SyncService {
    enum SyncError: Error {
        case badResponse
        case malformedCSV(line: Int, reason: String)
        case emptyCatalog
        case emptyRoster
        case emptyStores
    }

    struct ParsedProduct {
        let upc: String
        let name: String
        let price: Decimal
        let commodity: String?
        let store: String
        let retailPrice: Decimal?
        let rank: Int?
    }

    let sourceURL: URL

    init(sourceURL: URL) {
        self.sourceURL = Self.normalizeSourceURL(sourceURL)
    }

    // Accepts either a Google Drive share URL or a direct-download URL
    // and returns the form that returns raw bytes on GET. This lets
    // whoever configures the app paste whatever URL is in their
    // clipboard, whether it's from Drive's "Share" dialog or from a
    // previously-configured deployment.
    //
    // Share URLs look like:
    //   https://drive.google.com/file/d/<ID>/view?usp=sharing
    //   https://drive.google.com/open?id=<ID>
    // Both normalize to:
    //   https://drive.google.com/uc?export=download&id=<ID>
    //
    // Non-Google-Drive URLs pass through unchanged, so self-hosted CSVs,
    // S3 URLs, and internal endpoints still work.
    static func normalizeSourceURL(_ url: URL) -> URL {
        let urlString = url.absoluteString
        guard urlString.contains("drive.google.com") else { return url }

        // Extract the file ID from either URL format
        let fileID: String?
        if let range = urlString.range(of: "/file/d/") {
            let afterPrefix = urlString[range.upperBound...]
            let id = afterPrefix.split(separator: "/").first.map(String.init)
            fileID = id
        } else if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let id = comps.queryItems?.first(where: { $0.name == "id" })?.value {
            fileID = id
        } else {
            fileID = nil
        }

        guard let id = fileID,
              let normalized = URL(string: "https://drive.google.com/uc?export=download&id=\(id)") else {
            return url
        }
        return normalized
    }

    // Top-level sync. Fetches, parses, then hands off to MainActor for
    // the atomic SwiftData replace.
    func sync(into container: ModelContainer) async -> CatalogSync {
        let startURL = sourceURL.absoluteString
        do {
            let csv = try await fetchCSV()
            let parsed = try parse(csv: csv)
            guard !parsed.isEmpty else { throw SyncError.emptyCatalog }
            let count = try await applyAtomicReplace(parsed: parsed, container: container)
            return CatalogSync(productCount: count, sourceUrl: startURL, status: .success)
        } catch {
            return CatalogSync(
                productCount: 0,
                sourceUrl: startURL,
                status: .failed,
                errorMessage: String(describing: error)
            )
        }
    }

    // Fetches the CSV from Google Drive's direct-download endpoint.
    // The sourceURL can be either format — a Drive share link or the
    // direct-download URL. The initializer normalizes it.
    //
    // If Jacent ever moves to authenticated sources (Google Workspace
    // restricted, Microsoft 365 with MSAL, or an internal REST API),
    // this is the single place to swap in auth headers:
    //
    //   var req = URLRequest(url: sourceURL)
    //   req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    //   let (data, resp) = try await URLSession.shared.data(for: req)
    //
    // The rest of the sync pipeline is auth-agnostic.
    private func fetchCSV() async throws -> String {
        let (data, resp) = try await URLSession.shared.data(from: sourceURL)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SyncError.badResponse
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SyncError.badResponse
        }
        return text
    }

    // Minimal CSV parser. Assumes no embedded commas/quotes in product
    // names — if the catalog has those, swap in a real CSV lib.
    private func parse(csv: String) throws -> [ParsedProduct] {
        var result: [ParsedProduct] = []
        let lines = csv.split(whereSeparator: \.isNewline)
        guard lines.count > 1 else { throw SyncError.emptyCatalog }

        for (idx, rawLine) in lines.enumerated() where idx > 0 {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let cols = line.split(separator: ",", omittingEmptySubsequences: false).map { String($0) }
            guard cols.count >= 3 else {
                throw SyncError.malformedCSV(line: idx + 1, reason: "expected at least 3 columns")
            }
            let upc = cols[0].trimmingCharacters(in: .whitespaces)
            let name = cols[1].trimmingCharacters(in: .whitespaces)
            let priceStr = cols[2].trimmingCharacters(in: .whitespaces)
            let commodity = cols.count >= 4 ? cols[3].trimmingCharacters(in: .whitespaces) : nil
            // Column 5 is the store (retailer chain). If absent (older
            // catalog format), default to empty string — products with an
            // empty store can only be matched when the AM's selected store
            // is also empty, so these effectively won't scan until the
            // catalog is re-synced with the new format.
            let store = cols.count >= 5 ? cols[4].trimmingCharacters(in: .whitespaces) : ""

            // Column 6: retailPrice (shelf price). Parsed when numeric,
            // left nil on empty string or unparseable values so one bad
            // row doesn't tank the whole sync.
            var retailPrice: Decimal? = nil
            if cols.count >= 6 {
                let s = cols[5].trimmingCharacters(in: .whitespaces)
                if !s.isEmpty {
                    let d = NSDecimalNumber(string: s)
                    if d != .notANumber { retailPrice = d as Decimal }
                }
            }
            // Column 7: rank (merchandising priority, lower is better).
            // Same lenient rules as retailPrice.
            var rank: Int? = nil
            if cols.count >= 7 {
                let s = cols[6].trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { rank = Int(s) }
            }

            let decimal = NSDecimalNumber(string: priceStr)
            guard decimal != .notANumber else {
                throw SyncError.malformedCSV(line: idx + 1, reason: "price not a number")
            }
            result.append(ParsedProduct(
                upc: upc,
                name: name,
                price: decimal as Decimal,
                commodity: commodity,
                store: store,
                retailPrice: retailPrice,
                rank: rank
            ))
        }
        return result
    }

    // Atomic replace: delete all existing Products, then insert new rows,
    // in a single save. If anything throws, the context discards changes.
    @MainActor
    private func applyAtomicReplace(parsed: [ParsedProduct], container: ModelContainer) async throws -> Int {
        let context = ModelContext(container)
        try context.delete(model: Product.self)
        let now = Date.now
        for p in parsed {
            context.insert(Product(
                upc: p.upc,
                name: p.name,
                price: p.price,
                commodity: p.commodity,
                store: p.store,
                retailPrice: p.retailPrice,
                rank: p.rank,
                lastUpdated: now
            ))
        }
        try context.save()
        return parsed.count
    }

    // MARK: Area manager sync
    //
    // CSV format expected (first row is header):
    //   employeeNumber,firstName,lastName,territory,area
    //   12345,Darrin,Jessup,East,Seattle-North
    //
    // Called on app launch from BackstockTrackerApp. Full replace each time —
    // matches the catalog's sync pattern. No upsert logic since
    // AreaManager has no local-only state to preserve.

    struct ParsedAreaManager {
        let employeeNumber: String
        let firstName: String
        let lastName: String
        let territory: String
        let area: String
        let email: String
    }

    func syncAreaManagers(into container: ModelContainer) async -> AreaManagerSync {
        let startURL = sourceURL.absoluteString
        do {
            let csv = try await fetchCSV()
            let parsed = try parseAreaManagers(csv: csv)
            guard !parsed.isEmpty else { throw SyncError.emptyRoster }
            let count = try await applyAtomicReplaceAreaManagers(parsed: parsed, container: container)
            return AreaManagerSync(managerCount: count, sourceUrl: startURL, status: .success)
        } catch {
            return AreaManagerSync(
                managerCount: 0,
                sourceUrl: startURL,
                status: .failed,
                errorMessage: String(describing: error)
            )
        }
    }

    private func parseAreaManagers(csv: String) throws -> [ParsedAreaManager] {
        var result: [ParsedAreaManager] = []
        let lines = csv.split(whereSeparator: \.isNewline)
        guard lines.count > 1 else { throw SyncError.emptyRoster }

        for (idx, rawLine) in lines.enumerated() where idx > 0 {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let cols = line.split(separator: ",", omittingEmptySubsequences: false).map { String($0) }
            guard cols.count >= 5 else {
                throw SyncError.malformedCSV(
                    line: idx + 1,
                    reason: "expected at least 5 columns: employeeNumber, firstName, lastName, territory, area[, email]"
                )
            }
            let employeeNumber = cols[0].trimmingCharacters(in: .whitespaces)
            let firstName = cols[1].trimmingCharacters(in: .whitespaces)
            let lastName = cols[2].trimmingCharacters(in: .whitespaces)
            let territory = cols[3].trimmingCharacters(in: .whitespaces)
            let area = cols[4].trimmingCharacters(in: .whitespaces)
            // Column 6 (email) is optional — older rosters without it
            // still work; affected AMs just won't be CCd on approval
            // emails until the column is populated.
            let email = cols.count >= 6 ? cols[5].trimmingCharacters(in: .whitespaces) : ""

            guard !employeeNumber.isEmpty else {
                throw SyncError.malformedCSV(line: idx + 1, reason: "employeeNumber is empty")
            }
            result.append(ParsedAreaManager(
                employeeNumber: employeeNumber,
                firstName: firstName,
                lastName: lastName,
                territory: territory,
                area: area,
                email: email
            ))
        }
        return result
    }

    @MainActor
    private func applyAtomicReplaceAreaManagers(parsed: [ParsedAreaManager], container: ModelContainer) async throws -> Int {
        let context = ModelContext(container)
        try context.delete(model: AreaManager.self)
        for am in parsed {
            context.insert(AreaManager(
                employeeNumber: am.employeeNumber,
                firstName: am.firstName,
                lastName: am.lastName,
                territory: am.territory,
                area: am.area,
                email: am.email
            ))
        }
        try context.save()
        return parsed.count
    }

    // MARK: Stores sync
    //
    // CSV format expected (first row is header):
    //   store,storeNumber,area,shortName
    //   Target,1842,Seattle-North,TGT
    //   Target,4213,Seattle-North,TGT
    //   Walmart,0051,Seattle-North,WMT
    //
    // Columns 3 (area) and 4 (shortName) are optional for backward
    // compatibility — older CSVs with just `store,storeNumber` still
    // parse cleanly. shortName, when present, is shown in compact UI
    // (history rows, pickers) in place of the full store name.

    struct ParsedStore {
        let store: String
        let storeNumber: String
        let area: String
        let shortName: String
    }

    func syncStores(into container: ModelContainer) async -> StoreSync {
        let startURL = sourceURL.absoluteString
        do {
            let csv = try await fetchCSV()
            let parsed = try parseStores(csv: csv)
            guard !parsed.isEmpty else { throw SyncError.emptyStores }
            let count = try await applyAtomicReplaceStores(parsed: parsed, container: container)
            return StoreSync(storeCount: count, sourceUrl: startURL, status: .success)
        } catch {
            return StoreSync(
                storeCount: 0,
                sourceUrl: startURL,
                status: .failed,
                errorMessage: String(describing: error)
            )
        }
    }

    private func parseStores(csv: String) throws -> [ParsedStore] {
        var result: [ParsedStore] = []
        let lines = csv.split(whereSeparator: \.isNewline)
        guard lines.count > 1 else { throw SyncError.emptyStores }

        for (idx, rawLine) in lines.enumerated() where idx > 0 {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let cols = line.split(separator: ",", omittingEmptySubsequences: false).map { String($0) }
            guard cols.count >= 2 else {
                throw SyncError.malformedCSV(
                    line: idx + 1,
                    reason: "expected at least 2 columns: store, storeNumber [, area, shortName]"
                )
            }
            let store = cols[0].trimmingCharacters(in: .whitespaces)
            let storeNumber = cols[1].trimmingCharacters(in: .whitespaces)
            // Area is optional for backward compatibility — stores
            // without an area will appear to every AM regardless of
            // the AM's area. This prevents a partial stores.csv from
            // locking everyone out while the column is being added.
            let area = cols.count >= 3 ? cols[2].trimmingCharacters(in: .whitespaces) : ""
            // shortName is also optional. When present it's used in
            // compact UI; when absent the caller falls back to the
            // full `store` name (see Store.displayName).
            let shortName = cols.count >= 4 ? cols[3].trimmingCharacters(in: .whitespaces) : ""

            guard !store.isEmpty, !storeNumber.isEmpty else {
                throw SyncError.malformedCSV(line: idx + 1, reason: "store or storeNumber is empty")
            }
            result.append(ParsedStore(store: store,
                                      storeNumber: storeNumber,
                                      area: area,
                                      shortName: shortName))
        }
        return result
    }

    @MainActor
    private func applyAtomicReplaceStores(parsed: [ParsedStore], container: ModelContainer) async throws -> Int {
        let context = ModelContext(container)
        try context.delete(model: Store.self)
        for s in parsed {
            context.insert(Store(store: s.store,
                                 storeNumber: s.storeNumber,
                                 area: s.area,
                                 shortName: s.shortName))
        }
        try context.save()
        return parsed.count
    }

}

// MARK: - Audio service (buzzer)

// Two distinct sounds: a short confirm chirp on a successful scan,
// and an attention-grabbing buzzer when a UPC is not found.
//
// Uses AVAudioPlayer with synthesized PCM tones rather than iOS system
// sounds. System sounds have proven unreliable across iOS versions —
// some IDs silently fail on iOS 17/18 depending on focus mode, ringer
// state, and audio routing. Synthesized tones are self-contained and
// play consistently as long as the audio session is active.
final class AudioService {
    static let shared = AudioService()

    private var confirmPlayer: AVAudioPlayer?
    private var buzzerPlayer: AVAudioPlayer?

    private init() {
        // .playback means "this app plays audible audio content" — iOS
        // treats this seriously and won't silently drop our output. It
        // does respect the ringer switch for ringing-style sounds, but
        // AVAudioPlayer with .playback plays regardless of the ringer.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)

        // Pre-build the two players so the first scan doesn't lag.
        confirmPlayer = makeTonePlayer(frequency: 1800, duration: 0.08, volume: 0.7)
        buzzerPlayer = makeTonePlayer(frequency: 380, duration: 0.35, volume: 0.9)
        confirmPlayer?.prepareToPlay()
        buzzerPlayer?.prepareToPlay()
    }

    func playScanConfirm() {
        confirmPlayer?.currentTime = 0
        confirmPlayer?.play()
    }

    func playNotFound() {
        buzzerPlayer?.currentTime = 0
        buzzerPlayer?.play()
    }

    // Builds an AVAudioPlayer that plays a sine wave tone at the given
    // frequency, duration, and volume. Uses an in-memory WAV blob so
    // there's no bundled file dependency.
    private func makeTonePlayer(frequency: Double, duration: Double, volume: Float) -> AVAudioPlayer? {
        let sampleRate = 44100.0
        let sampleCount = Int(duration * sampleRate)
        var samples: [Int16] = []
        samples.reserveCapacity(sampleCount)

        // Short linear fade-in/out (5ms each side) to prevent clicks on
        // waveform start/end — rectangular cutoff produces a clicky pop.
        let fadeSamples = Int(0.005 * sampleRate)

        for i in 0..<sampleCount {
            let t = Double(i) / sampleRate
            let envelope: Double
            if i < fadeSamples {
                envelope = Double(i) / Double(fadeSamples)
            } else if i > sampleCount - fadeSamples {
                envelope = Double(sampleCount - i) / Double(fadeSamples)
            } else {
                envelope = 1.0
            }
            let sample = sin(2.0 * .pi * frequency * t) * envelope * 0.8
            samples.append(Int16(sample * Double(Int16.max)))
        }

        // Build WAV header + PCM data.
        let byteRate = Int(sampleRate) * 2  // mono, 16-bit
        let dataSize = samples.count * 2
        var wav = Data()
        wav.append("RIFF".data(using: .ascii)!)
        wav.append(UInt32(36 + dataSize).littleEndianData)
        wav.append("WAVE".data(using: .ascii)!)
        wav.append("fmt ".data(using: .ascii)!)
        wav.append(UInt32(16).littleEndianData)       // PCM chunk size
        wav.append(UInt16(1).littleEndianData)        // format = PCM
        wav.append(UInt16(1).littleEndianData)        // mono
        wav.append(UInt32(sampleRate).littleEndianData)
        wav.append(UInt32(byteRate).littleEndianData)
        wav.append(UInt16(2).littleEndianData)        // block align
        wav.append(UInt16(16).littleEndianData)       // bits per sample
        wav.append("data".data(using: .ascii)!)
        wav.append(UInt32(dataSize).littleEndianData)
        samples.withUnsafeBufferPointer { buf in
            wav.append(buf.baseAddress!.withMemoryRebound(to: UInt8.self, capacity: dataSize) { ptr in
                Data(bytes: ptr, count: dataSize)
            })
        }

        let player = try? AVAudioPlayer(data: wav)
        player?.volume = volume
        return player
    }
}

// Little-endian byte helpers for WAV header construction.
private extension UInt16 {
    var littleEndianData: Data {
        var v = self.littleEndian
        return withUnsafeBytes(of: &v) { Data($0) }
    }
}
private extension UInt32 {
    var littleEndianData: Data {
        var v = self.littleEndian
        return withUnsafeBytes(of: &v) { Data($0) }
    }
}

// MARK: - Launch coordinator & onboarding

// Root gate: waits for the roster to sync, then makes sure the AM has
// picked an area before handing off to the main app. The area drives
// the store picker in ScanView and is how we scope an AM's work to
// their slice of the territory. Once the roster is in SwiftData AND
// an area is saved in @AppStorage, RootTabView takes over.
struct LaunchCoordinator: View {
    @Query private var managers: [AreaManager]
    @AppStorage("selectedArea") private var selectedArea: String = ""
    // Store selection is now a gating step too. Once both the store
    // chain and the store number are set, the Scan and History tabs
    // can run fully scoped to a single physical location — no per-scan
    // picker noise, no cross-store history mixing.
    @AppStorage("selectedStore") private var selectedStore: String = ""
    @AppStorage("selectedStoreNumber") private var selectedStoreNumber: String = ""

    var body: some View {
        Group {
            if managers.isEmpty {
                LoadingRosterView()
            } else if selectedArea.isEmpty {
                AreaPickerView()
            } else if selectedStore.isEmpty || selectedStoreNumber.isEmpty {
                StorePickerView()
            } else {
                RootTabView()
            }
        }
    }
}

// First-run area picker. Shown after the roster loads but before
// RootTabView appears, and reused from Settings via sheet presentation
// when the AM needs to change areas later. Populated from the distinct
// `area` values in the AreaManager roster — these are the officially
// deployed areas, not derived from wherever stores happen to exist.
struct AreaPickerView: View {
    @Query private var managers: [AreaManager]
    @AppStorage("selectedArea") private var selectedArea: String = ""
    // When presented as a sheet from Settings, `onPicked` fires so the
    // caller can clear store selection and dismiss. Default no-op keeps
    // the first-run use site simple.
    var onPicked: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    private var areas: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for m in managers where !m.area.isEmpty {
            if !seen.contains(m.area) {
                seen.insert(m.area)
                result.append(m.area)
            }
        }
        return result.sorted()
    }

    var body: some View {
        NavigationStack {
            Group {
                if areas.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading areas…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(areas, id: \.self) { area in
                        Button {
                            selectedArea = area
                            onPicked?()
                            dismiss()
                        } label: {
                            HStack {
                                Text(area).foregroundStyle(.primary)
                                Spacer()
                                if selectedArea == area {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Choose your area")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// Store gating screen. Shown after area is picked but before the tab
// bar appears, and reused from Settings (via sheet) when the AM wants
// to switch stores. Two dependent dropdowns (chain, then number) feed
// a Continue button — mirrors the familiar picker pattern the scan
// screen used to host, just moved up a level so the tab bar stays
// clean.
struct StorePickerView: View {
    @Environment(\.modelContext) private var context
    @AppStorage("selectedArea") private var selectedArea: String = ""
    @AppStorage("selectedStore") private var selectedStore: String = ""
    @AppStorage("selectedStoreNumber") private var selectedStoreNumber: String = ""
    @AppStorage("selectedBox") private var selectedBox: Int = 0
    // When presented as a sheet from Settings, `onPicked` fires on
    // Continue so the caller can dismiss. Default no-op for first-run.
    var onPicked: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    // Draft selections — committed to @AppStorage only on Continue so
    // the AM can play with the dropdowns without prematurely releasing
    // the gate (which would swap the view out from under them).
    @State private var draftStore: String = ""
    @State private var draftNumber: String = ""

    // Live store-sync state so the inline "Sync stores now" button
    // can show a spinner / error without us having to mirror the
    // coordinator's state into local @State. Same pattern as
    // SettingsView's sync row.
    @State private var storeCoordinator = StoreSyncCoordinator.shared

    private var storeService: StoreService { StoreService(context: context) }

    private var storeNames: [String] {
        storeService.distinctStoreNames(in: selectedArea)
    }

    // Store numbers for the currently-selected chain, or empty when
    // no chain has been chosen yet. Sorted numerically when possible.
    private var availableNumbers: [String] {
        guard !draftStore.isEmpty else { return [] }
        let raw = storeService.storeNumbers(for: draftStore, in: selectedArea)
        return raw.sorted { lhs, rhs in
            if let l = Int(lhs), let r = Int(rhs) { return l < r }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    private var canContinue: Bool {
        !draftStore.isEmpty && !draftNumber.isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                // Store chain dropdown.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Store")
                        .font(.caption).foregroundStyle(.secondary)
                    Menu {
                        ForEach(storeNames, id: \.self) { name in
                            Button {
                                if draftStore != name {
                                    draftStore = name
                                    // Dependent dropdown — a new chain
                                    // invalidates whatever number was
                                    // picked for the previous chain.
                                    draftNumber = ""
                                }
                            } label: {
                                HStack {
                                    Text(name)
                                    if draftStore == name {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        dropdownLabel(
                            placeholder: "Choose a store",
                            value: draftStore
                        )
                    }
                    .disabled(storeNames.isEmpty)
                    .opacity(storeNames.isEmpty ? 0.5 : 1.0)
                }

                // Store number dropdown, gated on chain selection.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Store #")
                        .font(.caption).foregroundStyle(.secondary)
                    Menu {
                        ForEach(availableNumbers, id: \.self) { num in
                            Button {
                                draftNumber = num
                            } label: {
                                HStack {
                                    Text("#\(num)")
                                    if draftNumber == num {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        dropdownLabel(
                            placeholder: draftStore.isEmpty ? "Pick a store first" : "Choose a store #",
                            value: draftNumber.isEmpty ? "" : "#\(draftNumber)"
                        )
                    }
                    .disabled(availableNumbers.isEmpty)
                    .opacity(availableNumbers.isEmpty ? 0.5 : 1.0)
                }

                Spacer()

                // Prominent Continue button commits the draft and
                // releases the gate.
                Button {
                    commit()
                } label: {
                    Text("Continue")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canContinue)

                // When area is set but no stores have synced yet, the
                // dropdowns are empty. Previously we just told the AM
                // to navigate to Settings → Stores → Sync now — but
                // the Continue button is disabled in this state, so
                // they're stuck on this screen with no way out (most
                // common when the launch sync raced with bad / no
                // service). Surface a Sync-stores-now button right
                // here so the recovery is one tap away, and watch the
                // coordinator's state to render progress / errors
                // inline.
                if storeNames.isEmpty {
                    storesEmptyCard
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle("Choose your store")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            // Seed the drafts with whatever was already saved so the
            // picker reopens on the current pick rather than blank.
            draftStore = selectedStore
            draftNumber = selectedStoreNumber
        }
    }

    /// Inline recovery card shown when the local stores table is
    /// empty. If the AM hasn't picked an area yet, just tell them to
    /// — there's nothing useful to sync for an empty area. Once
    /// they've picked one, render a real "Sync stores now" button
    /// that calls StoreSyncCoordinator and shows progress / errors
    /// without forcing them through Settings.
    @ViewBuilder
    private var storesEmptyCard: some View {
        if selectedArea.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Pick an area first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No stores synced for \(selectedArea) yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        // If the most recent sync attempt actually
                        // came back failed (vs just never having run
                        // because the launch sync was offline), show
                        // the underlying error so the AM can tell
                        // network from configuration trouble.
                        if case let .failed(message) = storeCoordinator.state {
                            Text(message)
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .lineLimit(3)
                        }
                    }
                }

                Button {
                    Task {
                        await StoreSyncCoordinator.shared.run(container: context.container)
                    }
                } label: {
                    HStack(spacing: 8) {
                        if isSyncingStores {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(isSyncingStores ? "Syncing stores…" : "Sync stores now")
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isSyncingStores)
            }
            .padding(14)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    /// True while the StoreSyncCoordinator is mid-fetch. Pulled out
    /// of the @ViewBuilder so the `if case` doesn't trip the
    /// type-checker inside the disabled / button-label expressions.
    private var isSyncingStores: Bool {
        if case .syncing = storeCoordinator.state { return true }
        return false
    }

    // Shared dropdown look — filled pill with a chevron, primary text
    // for a selection, secondary for the placeholder.
    @ViewBuilder
    private func dropdownLabel(placeholder: String, value: String) -> some View {
        HStack {
            Text(value.isEmpty ? placeholder : value)
                .fontWeight(value.isEmpty ? .regular : .medium)
                .foregroundStyle(value.isEmpty ? .secondary : .primary)
                .lineLimit(1)
            Spacer()
            Image(systemName: "chevron.down")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func commit() {
        guard canContinue else { return }
        selectedStore = draftStore
        selectedStoreNumber = draftNumber
        // Box is location-specific — reset so a previous store's box
        // number doesn't silently follow the AM to a new location.
        selectedBox = 1
        onPicked?()
        dismiss()
    }
}

// Shown while the roster syncs on first launch, or when a retry is
// needed after a failure. If the fetch succeeds, the LaunchCoordinator's
// @Query will repopulate and this view will dismiss naturally.
struct LoadingRosterView: View {
    @Environment(\.modelContext) private var context
    @State private var coordinator = RosterSyncCoordinator.shared

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "barcode.viewfinder")
                .font(.system(size: 42))
                .foregroundStyle(.tint)
                .frame(width: 72, height: 72)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            Text("Jacent Backstock Tracker").font(.title3).fontWeight(.medium)
            Text("Loading your area manager roster from Google Drive.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            contentForState
            Spacer()
        }
    }

    @ViewBuilder
    private var contentForState: some View {
        switch coordinator.state {
        case .idle, .syncing:
            ProgressView()
                .controlSize(.large)
            Text("Syncing…").font(.caption).foregroundStyle(.tertiary)
        case .succeeded:
            // Roster is in SwiftData — LaunchCoordinator's @Query will
            // pick it up on the next render tick. Nothing to do here.
            ProgressView()
        case .failed(let message):
            VStack(spacing: 12) {
                Text("Couldn't load roster")
                    .font(.subheadline).fontWeight(.medium).foregroundStyle(.red)
                Text(message)
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Button("Try again") {
                    Task { await retry() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func retry() async {
        let container = context.container
        await RosterSyncCoordinator.shared.run(container: container)
    }
}

// MARK: - Root tab view

struct RootTabView: View {
    // Tagged tab selection so other views can flip the active tab
    // programmatically — used by the "Edit in Scan" flow on the box
    // detail screen, which loads a record into ScanSessionStore and
    // then needs to surface the Scan tab.
    @State private var selectedTab: Int = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            ScanView()
                .tabItem { Label("Scan", systemImage: "barcode.viewfinder") }
                .tag(0)
            HistoryView()
                .tabItem { Label("Backstock", systemImage: "clock.arrow.circlepath") }
                .tag(1)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(2)
        }
        // "Edit in Scan" on a box detail screen posts this notification
        // after seeding the store; flip to the Scan tab so the AM lands
        // on the loaded session.
        .onReceive(NotificationCenter.default.publisher(for: .switchToScanTab)) { _ in
            selectedTab = 0
        }
        // After a successful submitEdit, the AM should land back on
        // the box they were editing — not stuck on Scan with cleared
        // state. Flip back to Backstock; HistoryView handles pushing
        // the record onto its NavigationStack.
        .onReceive(NotificationCenter.default.publisher(for: .openBackstockRecord)) { _ in
            selectedTab = 1
        }
    }
}

// MARK: - Scan view

private enum ScanSortOrder: String, CaseIterable {
    // Default. Merchandising rank from the catalog (lower is better);
    // items without a rank fall to the bottom of the list.
    case rank      = "Rank"
    case scanOrder = "Scan order"
    case nameAZ    = "Name A→Z"
    case nameZA    = "Name Z→A"
    // Price sorts removed by request — they didn't map to any AM
    // workflow on the backstock surfaces (rank already conveys the
    // useful "what should I work first" signal). Re-add scoped to a
    // specific view if a use case shows up.
}

private enum ScanFilterMode: String, CaseIterable {
    case all        = "All items"
    case manualOnly = "Manual overrides"
}

struct ScanView: View {
    @Environment(ScanSessionStore.self) private var store
    @Environment(\.modelContext) private var context

    // Keyboard-wedge scanner input flows through this field. Keep it
    // focused so the scanner's keystrokes (+ trailing return) land here.
    @State private var scanBuffer: String = ""
    @FocusState private var inputFocused: Bool

    // Identifiable wrapper that carries the UPC into the manual-
    // override sheet. We used to trigger the sheet with a separate
    // `showManualOverride: Bool` and read the UPC from a `missingUPC`
    // @State, but when presenting the sheet on the same tick as
    // dismissing the camera cover, SwiftUI sometimes built the sheet
    // body before the UPC state write had propagated, so the UPC
    // field came up blank. Bundling the UPC into the presentation
    // trigger makes it atomic.
    @State private var manualOverridePrompt: ManualUPCPrompt?
    @State private var showSubmitConfirm = false
    // Guards the "Clear" button in the action bar — clearing wipes
    // every scanned line in the current box, and there's no undo
    // because the items never touched SwiftData. An accidental tap on
    // a full box would cost the AM their whole scan session, so we
    // gate the action behind a confirmation dialog.
    @State private var showClearConfirm = false
    @State private var showCamera = false
    @State private var editMode: EditMode = .inactive
    @State private var selectedItems: Set<UUID> = []

    // "Change store" affordance on the scan screen — opens the same
    // StorePickerView Settings uses, so the AM can swap stores without
    // leaving the scan tab. Two-step UX: if there's an in-progress
    // session, we route through showChangeStoreConfirm first so a
    // stray tap doesn't silently nuke a half-scanned box.
    @State private var showStorePicker = false
    @State private var showChangeStoreConfirm = false

    // Camera-facing state so the camera view can show a 'not found'
    // flash when a scanned UPC isn't in the catalog.
    @State private var cameraNotFoundUPC: String?
    // Reason text accompanying cameraNotFoundUPC — distinguishes between
    // "not in catalog" and "wrong store" cases.
    @State private var cameraNotFoundReason: String?

    // Error message shown in the manual-entry path when a scan is rejected
    // because of store mismatch (doesn't go through the override sheet).
    @State private var lastScanErrorMessage: String?

    // Transient "success" banner shown after Save or after a draft is
    // restored on appear. Same auto-dismiss pattern as
    // lastScanErrorMessage, but green instead of red so the AM can tell
    // it's a confirmation, not a failure.
    @State private var lastSuccessMessage: String?

    // Selected store and store number persist across launches. AMs
    // typically spend a full day at one store, so remembering the last
    // selection is a kindness. Empty strings mean "not yet selected."
    @AppStorage("selectedStore") private var selectedStore: String = ""
    @AppStorage("selectedStoreNumber") private var selectedStoreNumber: String = ""
    // The AM's currently selected area. Drives the filter on both
    // store-name and store-number pickers. LaunchCoordinator guarantees
    // this is non-empty before ScanView mounts.
    @AppStorage("selectedArea") private var selectedArea: String = ""
    // Physical box number (1…10) the current session will be recorded
    // against. Stored in @AppStorage so the AM doesn't lose their box
    // if the app gets backgrounded mid-scan, but changes to it are
    // cheap — they can bump it for every new box through the day. 0
    // = not yet picked; treated as nil on the persisted session.
    @AppStorage("selectedBox") private var selectedBox: Int = 0

    // Drive the empty-catalog and empty-stores banners. When either is
    // empty, scanning will fail — show explicit warnings so the AM knows
    // to sync instead of assuming every product is legitimately missing.
    @Query private var products: [Product]
    @Query private var storesData: [Store]
    @State private var catalogCoordinator = CatalogSyncCoordinator.shared
    @State private var storeCoordinator = StoreSyncCoordinator.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Identity banner, matching the Backstock tab's header:
                // tinted accent wash, the store name promoted to the
                // headline line ("Target #860"), with the area as a
                // subline. Always present when a store is scoped — the
                // AM should see where they are before they scan.
                if !selectedStoreNumber.isEmpty || !selectedStore.isEmpty {
                    DetailHeaderView(
                        storeNumber: selectedStoreNumber,
                        storeName: resolvedStoreName,
                        useNameAsHeadline: true,
                        sublines: selectedArea.isEmpty ? [] : [selectedArea],
                        tinted: true
                    )
                }
                // Edit-mode strip — surfaces when the AM is editing an
                // existing CloudKit record (kicked off by "Edit in
                // Scan" on the box detail view). Tells them what
                // they're editing so a stray submit doesn't end up on
                // the wrong record, and gives them an exit ramp.
                if store.isEditingExistingRecord {
                    editModeBanner
                }
                if storesData.isEmpty {
                    emptyStoresBanner
                }
                if products.isEmpty {
                    emptyCatalogBanner
                } else if isCatalogSyncing {
                    catalogSyncingIndicator
                }
                if !storesData.isEmpty {
                    storePickerBar
                }
                statusBar
                scanField
                if let msg = lastScanErrorMessage {
                    scanErrorBanner(message: msg)
                }
                if let msg = lastSuccessMessage {
                    scanSuccessBanner(message: msg)
                }
                itemsList
                actionBar
            }
            .environment(\.editMode, $editMode)
            .scrollDismissesKeyboard(.immediately)
            // Tap anywhere outside the UPC field to dismiss the
            // keyboard. We use `.simultaneousGesture(TapGesture())`
            // rather than `.onTapGesture` so the tap recognizer runs
            // alongside the List's own gestures instead of consuming
            // them — this is what broke swipe-to-delete the first time
            // we tried this (see CLAUDE.md "dismiss-keyboard-on-
            // outside-tap"). TapGesture is a discrete recognizer and
            // swipe-to-delete is a continuous drag, so they don't
            // contend for the same event stream. The TextField's own
            // focus-on-tap still wins because it sets inputFocused =
            // true *after* this handler runs (SwiftUI processes the
            // focused binding update as part of the tap, not before).
            .simultaneousGesture(
                TapGesture().onEnded { inputFocused = false }
            )
            .navigationBarTitleDisplayMode(.inline)
            // Force the nav bar to render opaque so the principal
            // title doesn't wash out — same treatment as the Backstock
            // tab where the root is a VStack, not a ScrollView.
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                // Custom principal title so the text renders in full
                // `.primary` color and matches the darker "Backstock"
                // label on the History tab.
                ToolbarItem(placement: .principal) {
                    Text("Scan")
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !store.items.isEmpty {
                        Button(editMode.isEditing ? "Done" : "Edit") {
                            withAnimation {
                                if editMode.isEditing {
                                    editMode = .inactive
                                    selectedItems.removeAll()
                                } else {
                                    editMode = .active
                                }
                            }
                        }
                    }
                }
            }
            .onAppear {
                inputFocused = true
                validateStoreSelection()
                restoreDraftIfAvailable()
            }
            // If the AM changes area from Settings while ScanView is
            // alive in another tab, revalidate the store selection so
            // a stale pick doesn't linger into the next scan.
            .onChange(of: selectedArea) { _, _ in
                validateStoreSelection()
            }
            // A box number is location-specific — if the AM picks a
            // different store or store number, reset to Box 1 so the
            // previous box doesn't silently follow them. We reset to 1
            // (not 0/"unpicked") because once a store number is set,
            // a box must be chosen anyway and 1 is the most common.
            .onChange(of: selectedStore) { _, _ in
                selectedBox = 1
                // Re-check for a draft matching the new store context.
                restoreDraftIfAvailable()
            }
            .onChange(of: selectedStoreNumber) { _, _ in
                selectedBox = 1
                restoreDraftIfAvailable()
            }
            // Switching boxes within the same store also opens the
            // chance to restore a draft saved for that specific box.
            .onChange(of: selectedBox) { _, _ in
                restoreDraftIfAvailable()
            }
            .sheet(item: $manualOverridePrompt) { prompt in
                ManualPriceSheet(
                    upc: prompt.upc,
                    reason: prompt.reason,
                    prefillName: prompt.prefillName,
                    prefillPrice: prompt.prefillPrice,
                    prefillNote: prompt.prefillNote
                ) { override in
                    addManualItem(override)
                }
            }
            // Change-store sheet, mirroring the Settings flow: on
            // Continue, clear any in-progress session so the new
            // store's submit doesn't inherit the old store's items.
            // We don't post .switchToScanTab here — we're already on
            // Scan.
            .sheet(isPresented: $showStorePicker) {
                StorePickerView {
                    store.clear()
                }
            }
            // Confirmation when an in-flight scan is at risk. Splits
            // the destructive step from the picker so a stray tap on
            // "Change store" doesn't silently wipe a half-scanned box.
            .confirmationDialog(
                "Switching stores will clear your current scan. Continue?",
                isPresented: $showChangeStoreConfirm,
                titleVisibility: .visible
            ) {
                Button("Change store", role: .destructive) {
                    showStorePicker = true
                }
                Button("Cancel", role: .cancel) { }
            }
            .sheet(isPresented: $showSubmitConfirm) {
                SubmitSheet(
                    subtotal: store.subtotal,
                    store: selectedStore,
                    storeNumber: selectedStoreNumber,
                    itemCount: store.items.count,
                    isEditing: store.isEditingExistingRecord
                ) {
                    submit()
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraScannerView(notFoundUPC: cameraNotFoundUPC, notFoundReason: cameraNotFoundReason) { upc in
                    return handleScan(upc)
                }
            }
        }
    }

    private var emptyCatalogBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 4) {
                Text(isCatalogSyncing ? "Loading product catalog…" : "Product catalog is empty")
                    .font(.subheadline).fontWeight(.medium)
                Text(isCatalogSyncing
                     ? "Scans will fail until this finishes. Hang tight."
                     : "Every scan will say 'not in catalog' until the catalog is synced.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !isCatalogSyncing {
                Button("Sync") {
                    Task {
                        let container = context.container
                        await CatalogSyncCoordinator.shared.run(container: container)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
    }

    private var isCatalogSyncing: Bool {
        if case .syncing = catalogCoordinator.state { return true }
        return false
    }

    // Thin strip shown while a catalog sync is in progress but we
    // already have products — the AM can keep scanning with the old
    // catalog; the indicator just lets them know an update is coming.
    private var catalogSyncingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.7)
            Text("Syncing product catalog…")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemBackground))
    }

    private var isStoreSyncing: Bool {
        if case .syncing = storeCoordinator.state { return true }
        return false
    }

    // Shown when no Store rows exist at all. Without stores the pickers
    // can't populate, so scanning will fail. Offer a direct sync action.
    private var emptyStoresBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 4) {
                Text(isStoreSyncing ? "Loading stores…" : "Store list is empty")
                    .font(.subheadline).fontWeight(.medium)
                Text(isStoreSyncing
                     ? "Store picker will populate when this finishes."
                     : "You need stores before you can scan. Tap Sync to download them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !isStoreSyncing {
                Button("Sync") {
                    Task {
                        let container = context.container
                        await StoreSyncCoordinator.shared.run(container: container)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
    }

    // Name shown inside the identity banner at the top of the screen.
    // Mirrors HistoryView.resolvedStoreName so the two tabs' headers
    // agree on which label to use for the same store.
    private var resolvedStoreName: String {
        if !selectedStore.isEmpty { return selectedStore }
        let storeService = StoreService(context: context)
        if let short = storeService.shortName(for: selectedStore, storeNumber: selectedStoreNumber, in: selectedArea),
           !short.isEmpty {
            return short
        }
        return ""
    }

    // Compact session-scoped toolbar: now just the Box picker. The
    // store identity used to live here as a pill, but the tinted
    // header banner above already shows it — keeping it here too
    // duplicated the same label twice on the same screen. Store and
    // store number are locked in at `StorePickerView` and changed via
    // Settings → Change store; the box number is the only thing an AM
    // actively switches mid-session.
    private var storePickerBar: some View {
        let scanInProgress = !store.items.isEmpty
        // Box picker is only gated by an in-progress scan now — store
        // and store number are guaranteed non-empty by LaunchCoordinator.
        let boxDisabled = scanInProgress

        return HStack(spacing: 10) {
            // Box picker (1–10). Only disabled while a scan is in
            // progress so the box can't silently change mid-session.
            Menu {
                ForEach(1...10, id: \.self) { n in
                    Button {
                        selectedBox = n
                    } label: {
                        HStack {
                            Text("Backstock Box \(n)")
                            if selectedBox == n {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                let boxShowsPlaceholder = selectedBox == 0
                HStack(spacing: 4) {
                    Text(boxShowsPlaceholder ? "Backstock Box" : "Backstock Box \(selectedBox)")
                        .fontWeight(boxShowsPlaceholder ? .regular : .medium)
                        .foregroundStyle(boxShowsPlaceholder ? .secondary : .primary)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .disabled(boxDisabled)
            .opacity(boxDisabled ? 0.5 : 1.0)

            Spacer()

            // Change-store button. Same StorePickerView the gate
            // screen uses, presented as a sheet. If there are scanned
            // items in progress we ask first — switching stores
            // clears the session (the new store may have different
            // catalog prices, so carrying items over would be wrong).
            Button {
                if scanInProgress {
                    showChangeStoreConfirm = true
                } else {
                    showStorePicker = true
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption)
                    Text("Change store")
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .foregroundStyle(.tint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func scanErrorBanner(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 14))
            Text(message)
                .font(.caption).foregroundStyle(.primary)
            Spacer()
            Button {
                lastScanErrorMessage = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.1))
        .task(id: message) {
            // Auto-dismiss after 4 seconds so stale messages don't linger.
            try? await Task.sleep(for: .seconds(4))
            if lastScanErrorMessage == message {
                lastScanErrorMessage = nil
            }
        }
    }

    // Green-tinted twin of scanErrorBanner — used for transient
    // confirmations like "Progress saved" or "Draft restored". Same
    // 4-second auto-dismiss behavior.
    private func scanSuccessBanner(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 14))
            Text(message)
                .font(.caption).foregroundStyle(.primary)
            Spacer()
            Button {
                lastSuccessMessage = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.12))
        .task(id: message) {
            try? await Task.sleep(for: .seconds(4))
            if lastSuccessMessage == message {
                lastSuccessMessage = nil
            }
        }
    }

    // Edit-mode banner. Orange-tinted strip indicating the AM is
    // working on an already-submitted box rather than a fresh one. The
    // store + box label echoes the detail screen they came from so
    // there's no ambiguity. The Cancel button hard-stops edit mode
    // (clears items + endEditing()) so the AM can bail without
    // accidentally pushing partial changes back to the cloud.
    private var editModeBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil.circle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 1) {
                Text("Editing existing box")
                    .font(.caption).fontWeight(.semibold)
                    .foregroundStyle(.primary)
                Text(editModeSubline)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Cancel") {
                store.clear()
                store.endEditing()
                lastSuccessMessage = "Edit canceled"
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.orange)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.orange.opacity(0.30)).frame(height: 0.5)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.orange.opacity(0.30)).frame(height: 0.5)
        }
    }

    private var editModeSubline: String {
        let storeBit = store.editingRecordStoreName.isEmpty
            ? "Store #\(store.editingRecordStoreNumber)"
            : "\(store.editingRecordStoreName) #\(store.editingRecordStoreNumber)"
        if let box = store.editingRecordBox {
            return "\(storeBit) · Box \(box)"
        }
        return storeBit
    }

    // Persist the current scan session as a draft. No-ops silently
    // when there's nothing to save or the storage write fails — the
    // UI guards already disable the button when items are empty, and
    // a UserDefaults JSON encode failure for Codable items shouldn't
    // happen in practice.
    private func saveDraft() {
        let ok = store.saveDraft(
            storeName: selectedStore,
            storeNumber: selectedStoreNumber,
            area: selectedArea,
            box: selectedBox
        )
        if ok {
            lastSuccessMessage = "Progress saved — \(store.items.count) item\(store.items.count == 1 ? "" : "s")"
        }
    }

    // Attempt to restore a draft into the current session. Only fires
    // when the box is currently empty — if the AM has already started
    // scanning, we don't want to dump a stale draft on top of their
    // fresh work. The store-side loadDraftIfMatches also guards on
    // store/box equality so a draft from Target Box 1 can't land in
    // Walmart Box 3.
    private func restoreDraftIfAvailable() {
        guard store.items.isEmpty else { return }
        guard selectedBox >= 1, !selectedStoreNumber.isEmpty else { return }
        let savedAt = store.draftSavedAt
        let restored = store.loadDraftIfMatches(
            storeNumber: selectedStoreNumber,
            box: selectedBox
        )
        if restored {
            if let savedAt {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .short
                let ago = formatter.localizedString(for: savedAt, relativeTo: .now)
                lastSuccessMessage = "Draft restored (saved \(ago)) — \(store.items.count) item\(store.items.count == 1 ? "" : "s")"
            } else {
                lastSuccessMessage = "Draft restored — \(store.items.count) item\(store.items.count == 1 ? "" : "s")"
            }
        }
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Subtotal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(store.items.count) line\(store.items.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(Self.currency(store.subtotal))
                .font(.system(size: 34, weight: .medium))
        }
        .padding()
        .background(Color(.secondarySystemBackground))
    }

    private var scanField: some View {
        HStack {
            TextField("Scan or type UPC…", text: $scanBuffer)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { handleScan() }
            Button("Add") { handleScan() }
                .disabled(scanBuffer.isEmpty)
            Button {
                if editMode.isEditing {
                    withAnimation {
                        editMode = .inactive
                        selectedItems.removeAll()
                    }
                }
                showCamera = true
            } label: {
                Image(systemName: "camera.viewfinder")
                    .font(.title3)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Scan with camera")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var itemsList: some View {
        // Display newest-first so the scan you just made is visible at
        // the top of the list without scrolling — especially helpful
        // on long boxes where an append to the bottom would land
        // below the fold. The underlying `store.items` stays in
        // insertion order (oldest-first), so submit/CSV/export stay
        // chronological for anyone reading the saved record.
        List(selection: $selectedItems) {
            ForEach(Array(store.items.reversed())) { item in
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.name).font(.subheadline).fontWeight(.medium)
                            if item.manualOverride {
                                Text("manual")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.2))
                                    .foregroundStyle(.orange)
                                    .clipShape(Capsule())
                            }
                        }
                        HStack(spacing: 6) {
                            Text(item.upc).font(.caption2).monospaced().foregroundStyle(.tertiary)
                            Text("·").font(.caption2).foregroundStyle(.tertiary)
                            Text("\(Self.currency(item.price)) ea").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 8) {
                            Text("\(item.quantity)")
                                .font(.subheadline).fontWeight(.medium)
                                .monospacedDigit()
                                .frame(minWidth: 24, alignment: .trailing)
                            if !editMode.isEditing {
                                Stepper(
                                    "Quantity",
                                    value: Binding(
                                        get: { item.quantity },
                                        set: { store.setQuantity(id: item.id, quantity: $0) }
                                    ),
                                    in: 1...999
                                )
                                .labelsHidden()
                            }
                        }
                        Text(Self.currency(item.lineTotal))
                            .font(.subheadline).fontWeight(.medium)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        store.remove(item)
                    } label: { Label("Remove", systemImage: "trash") }
                }
            }
        }
        .listStyle(.plain)
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            if editMode.isEditing {
                Button(selectedItems.count == store.items.count ? "Deselect all" : "Select all") {
                    if selectedItems.count == store.items.count {
                        selectedItems.removeAll()
                    } else {
                        selectedItems = Set(store.items.map { $0.id })
                    }
                }
                .buttonStyle(.bordered)
                Spacer()
                Button(role: .destructive) {
                    deleteSelected()
                } label: {
                    Text(selectedItems.isEmpty ? "Delete" : "Delete (\(selectedItems.count))")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(selectedItems.isEmpty)
            } else {
                // Only prompt for confirmation when there's actually
                // something to clear — no point in a dialog that says
                // "clear nothing?". When empty, the button is disabled.
                Button("Clear") {
                    if !store.items.isEmpty {
                        showClearConfirm = true
                    }
                }
                .buttonStyle(.bordered)
                .disabled(store.items.isEmpty)
                Button("Save") {
                    saveDraft()
                }
                .buttonStyle(.bordered)
                .disabled(store.items.isEmpty || store.isEditingExistingRecord)
                Spacer()
                // Submit text changes in edit mode — same button, same
                // confirm sheet, but the underlying handler routes
                // through submitEdit() (CloudKit patch) rather than
                // submitNew() (insert ScanSession + upload).
                Button(store.isEditingExistingRecord ? "Save changes" : "Submit") {
                    showSubmitConfirm = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.items.isEmpty)
            }
        }
        .padding()
        .confirmationDialog(
            "Clear all scanned items?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear \(store.items.count) item\(store.items.count == 1 ? "" : "s")", role: .destructive) {
                store.clear()
                // The AM explicitly nuked the box — any saved draft
                // was almost certainly pointing at these same items,
                // so drop it too. Otherwise the next app launch would
                // silently restore what they just asked to erase.
                store.clearDraft()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes every scan from the current box. There's no undo.")
        }
    }

    private func deleteSelected() {
        for id in selectedItems {
            if let item = store.items.first(where: { $0.id == id }) {
                store.remove(item)
            }
        }
        selectedItems.removeAll()
        withAnimation {
            editMode = .inactive
        }
    }

    // Clear the saved store selection if the signed-in AM's area
    // no longer includes it. Handles the "AM switched accounts" case —
    // otherwise a Seattle-North AM signing in after a Seattle-South AM
    // would be left with a stale Seattle-South store pre-selected.
    private func validateStoreSelection() {
        guard !selectedStore.isEmpty else { return }
        let storeService = StoreService(context: context)
        // Use selectedArea rather than empty-scope, so changing the
        // area in Settings invalidates stale picks from the prior area.
        let allowedStores = storeService.distinctStoreNames(in: selectedArea)
        if !allowedStores.contains(selectedStore) {
            selectedStore = ""
            selectedStoreNumber = ""
            return
        }
        let allowedNumbers = storeService.storeNumbers(for: selectedStore, in: selectedArea)
        if !selectedStoreNumber.isEmpty && !allowedNumbers.contains(selectedStoreNumber) {
            selectedStoreNumber = ""
        }
    }

    // MARK: scan handling

    // Called from three places: the Add button, the text field's submit
    // action, and the camera view's callback. Passing nil pulls the UPC
    // from scanBuffer (the keyboard-wedge path); passing a String uses it
    // directly (the camera path). Returns a ScanResult so the camera
    // view can decide whether to auto-close after success.
    @discardableResult
    private func handleScan(_ scannedUPC: String? = nil) -> ScanResult {
        let upc: String
        if let scannedUPC {
            upc = scannedUPC.trimmingCharacters(in: .whitespaces)
        } else {
            upc = scanBuffer.trimmingCharacters(in: .whitespaces)
            scanBuffer = ""
            inputFocused = true
        }
        guard !upc.isEmpty else { return .notFound }

        // Can't scan without both a store and store number selected.
        // The catalog lookup uses the store (retailer chain); the store
        // number is recorded on the submitted session for audit.
        guard !selectedStore.isEmpty, !selectedStoreNumber.isEmpty else {
            AudioService.shared.playNotFound()
            let reason = "Select a store and store number first"
            if showCamera {
                cameraNotFoundUPC = upc
                cameraNotFoundReason = reason
            } else {
                lastScanErrorMessage = reason
            }
            return .notFound
        }

        // If we're in edit mode when a scan arrives, the AM has moved on
        // from editing. Exit cleanly so the new item shows in the normal
        // list view, not as an unselected row in the selection list.
        if editMode.isEditing {
            withAnimation {
                editMode = .inactive
                selectedItems.removeAll()
            }
        }

        // Propagate the current store number and box to the session
        // store so that when the AM submits, the session record carries
        // both for audit. selectedBox == 0 means "not picked" → nil on
        // the persisted record.
        store.currentStoreNumber = selectedStoreNumber
        store.currentBox = selectedBox == 0 ? nil : selectedBox

        let catalog = CatalogService(context: context)
        let result = catalog.lookup(upc: upc, store: selectedStore)

        switch result {
        case .found(let product):
            store.add(.init(
                upc: product.upc,
                name: product.name,
                price: product.price,
                manualOverride: false,
                overrideNote: nil,
                scannedAt: .now
            ))
            cameraNotFoundUPC = nil
            cameraNotFoundReason = nil
            return .added

        case .wrongStore(let availableAt):
            // Catalog has the UPC for some other store(s). Rather than
            // dead-end with a red banner, surface the manual-add sheet
            // pre-filled from the cross-store row so the AM can confirm
            // and add in one tap. Flagged as `manualOverride: true` in
            // the audit log because the price/name aren't authoritative
            // for *this* store.
            AudioService.shared.playNotFound()
            cameraNotFoundUPC = nil
            cameraNotFoundReason = nil
            let representative = catalog.anyProduct(upc: upc)
            let storesList = availableAt.joined(separator: ", ")
            let noteHint = availableAt.count == 1
                ? "From catalog at \(storesList)"
                : "From catalog at: \(storesList)"
            let prompt = ManualUPCPrompt(
                upc: upc,
                prefillName: representative?.name,
                prefillPrice: representative?.price,
                prefillNote: noteHint,
                reason: .otherStore
            )
            if showCamera {
                showCamera = false
                // One runloop turn so the fullScreenCover dismiss can
                // start before the sheet present triggers — same race
                // as the .notInCatalog path below.
                DispatchQueue.main.async {
                    manualOverridePrompt = prompt
                }
            } else {
                manualOverridePrompt = prompt
            }
            return .notFound

        case .notInCatalog:
            AudioService.shared.playNotFound()
            // A UPC not in the catalog has exactly one useful next
            // step: add it manually. Dismiss the camera (if open)
            // and jump straight into the manual-add sheet. The UPC
            // rides along in the Identifiable prompt so the sheet
            // always shows the scanned code, no matter how the
            // cover→sheet transition sequences.
            cameraNotFoundUPC = nil
            cameraNotFoundReason = nil
            let prompt = ManualUPCPrompt(upc: upc)
            if showCamera {
                showCamera = false
                // One runloop turn so the fullScreenCover's dismiss
                // animation can start before the sheet present
                // triggers — presenting a sheet from underneath a
                // dismissing cover on the same tick is racy.
                DispatchQueue.main.async {
                    manualOverridePrompt = prompt
                }
            } else {
                manualOverridePrompt = prompt
            }
            return .notFound
        }
    }

    private func addManualItem(_ override: ManualOverride) {
        store.add(.init(
            upc: override.upc,
            name: override.name,
            price: override.price,
            manualOverride: true,
            overrideNote: override.note,
            scannedAt: .now
        ))
    }

    private func submit() {
        // Edit-mode path: the AM is updating an existing CloudKit
        // record they previously submitted (or someone in their area
        // did). Don't insert a new ScanSession — patch the record in
        // place via CloudSyncService.updateItems and clear edit-mode
        // state on success.
        if store.isEditingExistingRecord {
            submitEdit()
        } else {
            submitNew()
        }
    }

    private func submitNew() {
        let catalog = CatalogService(context: context)
        let lastSync = catalog.lastSyncedAt()
        do {
            let session = try store.submit(into: context, catalogSyncedAt: lastSync)
            showSubmitConfirm = false

            // Advance to the next box number so the AM can keep scanning
            // the next physical box without having to reach for the
            // picker. Cap at 10 (the max the picker offers) — if the AM
            // actually has an 11th box, they'll bump it manually or
            // start a new day at Box 1.
            if selectedBox >= 1 && selectedBox < 10 {
                selectedBox += 1
            }

            // Kick off the CloudKit public-DB upload after local persist.
            // We build the Sendable payload on the main actor (reading
            // SwiftData @Model objects) and then hop to the service actor
            // for the network call, so no @Model ref crosses threads.
            if let session {
                let payload = CloudSyncService.buildPayload(
                    session: session,
                    stores: storesData,
                    products: products,
                    // Fall back to the AM's selectedArea so a Store
                    // row with a missing area column doesn't produce
                    // an `area = ""` record that the read-side filters
                    // silently drop.
                    fallbackArea: selectedArea
                )
                if let payload {
                    Task {
                        do {
                            try await CloudSyncService.shared.upload(payload)
                            // Mark the local record synced so we don't
                            // re-upload it on next launch's retry sweep.
                            session.cloudSyncedAt = .now
                            try? context.save()

                            // Two-step propagation so the new box never
                            // disappears between submit and CKQuery
                            // catching up:
                            //  1. Register with the service-level
                            //     optimistic cache. Any subsequent
                            //     fetchAllMerged (tab switch, pull-to-
                            //     refresh, History view first appear)
                            //     will overlay it until the server
                            //     returns it.
                            //  2. Post a notification so an
                            //     already-mounted History view injects
                            //     it instantly without waiting for its
                            //     next reload cycle.
                            let optimistic = CloudSyncService.makeRecord(from: payload)
                            await CloudSyncService.shared.registerOptimistic(optimistic)
                            await MainActor.run {
                                NotificationCenter.default.post(
                                    name: .teamSessionDidUpdate,
                                    object: nil,
                                    userInfo: ["record": optimistic]
                                )
                            }
                        } catch {
                            // Swallow — cloudSyncedAt stays nil and the
                            // next app launch's retry pass will try again.
                            print("Cloud upload failed for \(session.id): \(error)")
                        }
                    }
                }
            }
        } catch {
            print("Submit failed: \(error)")
        }
    }

    // Push the edited items back to the existing CloudKit record.
    // Mirrors CloudSyncService.buildPayload's per-item enrichment: we
    // look up retailPrice / rank / commodity from the local catalog
    // for each UPC against the record's storeName, so an edit doesn't
    // wipe those fields just because they're not part of InMemoryItem.
    private func submitEdit() {
        guard let recordId = store.editingRecordId else { return }
        showSubmitConfirm = false

        // Snapshot the relevant state on the main actor before hopping
        // to the network task. Items / store name are needed for both
        // the CloudKit payload and the success messaging.
        let storeName = store.editingRecordStoreName
        let cloudItems: [CloudSyncItem] = store.items.map { item in
            let product = products.first { $0.upc == item.upc && $0.store == storeName }
                ?? products.first { $0.upc == item.upc }
            return CloudSyncItem(
                upc: item.upc,
                name: item.name,
                quantity: item.quantity,
                price: NSDecimalNumber(decimal: item.price).doubleValue,
                retailPrice: product?.retailPrice.map { NSDecimalNumber(decimal: $0).doubleValue },
                rank: product?.rank,
                commodity: product?.commodity
            )
        }
        let subtotal = cloudItems.reduce(0.0) { $0 + $1.price * Double($1.quantity) }
        let retailTotal = cloudItems.reduce(0.0) { sum, it in
            sum + (it.retailPrice ?? 0) * Double(it.quantity)
        }
        let itemCount = cloudItems.count

        // Snapshot the rest of the original record metadata too, so
        // we can rebuild a complete TeamBackstockRecord on success
        // without a CloudKit refetch. Post-success we'll push this
        // back onto the History stack so the AM lands on the freshly-
        // saved detail screen instead of staying on a now-empty Scan.
        let storeNumber = store.editingRecordStoreNumber
        let area = store.editingRecordArea
        let status = store.editingRecordStatus
        let submittedAt = store.editingRecordSubmittedAt
        let box = store.editingRecordBox

        Task {
            do {
                try await CloudSyncService.shared.updateItems(
                    sessionUUID: recordId,
                    items: cloudItems,
                    subtotal: subtotal,
                    retailTotal: retailTotal
                )
                await MainActor.run {
                    // Build the fresh record for both the list-update
                    // notification (so the row in StoreHistoryList
                    // reflects the new totals immediately) and the
                    // detail-push notification (so we land back on
                    // the just-saved box).
                    let freshRecord = TeamBackstockRecord(
                        id: recordId,
                        recordName: recordId,
                        area: area,
                        storeName: storeName,
                        storeNumber: storeNumber,
                        box: box,
                        status: status,
                        subtotal: subtotal,
                        retailTotal: retailTotal,
                        submittedAt: submittedAt,
                        items: cloudItems
                    )
                    // Tell HistoryView / any presented detail to
                    // reload — same notification the in-detail edits
                    // (quantity / delete / add) post. We attach the
                    // rebuilt record under userInfo["record"] so
                    // StoreHistoryList's handler can upsert without
                    // a CloudKit refetch (which is eventually
                    // consistent and may not yet show our edit).
                    NotificationCenter.default.post(
                        name: .teamSessionDidUpdate,
                        object: recordId,
                        userInfo: ["record": freshRecord]
                    )
                    store.clear()
                    store.endEditing()
                    lastSuccessMessage = "Box updated — \(itemCount) item\(itemCount == 1 ? "" : "s")"
                    // Hop back to the Backstock tab and push the
                    // detail for this record. RootTabView flips the
                    // tab; HistoryView appends the record to its
                    // navPath. Posted last so the success banner
                    // hits before the navigation re-shows the detail.
                    NotificationCenter.default.post(
                        name: .openBackstockRecord,
                        object: nil,
                        userInfo: ["record": freshRecord]
                    )
                }
            } catch {
                await MainActor.run {
                    // Leave items + edit-mode in place so the AM can
                    // retry without re-loading the record. Surface the
                    // error in the standard scan error banner.
                    lastScanErrorMessage = "Couldn't save changes: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: presentation helpers

    static func currency(_ d: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: d as NSDecimalNumber) ?? "$0.00"
    }
}

// MARK: - Manual override sheet

struct ManualOverride {
    let upc: String
    let name: String
    let price: Decimal
    let note: String?
}

// Identity-bearing trigger for the manual-override sheet. Carrying
// the UPC on the prompt itself (rather than reading from a separate
// @State) means the sheet body always sees the exact UPC that was
// scanned — no risk of a state-propagation race when the sheet is
// presented immediately after dismissing the camera cover.
struct ManualUPCPrompt: Identifiable {
    let id = UUID()
    let upc: String
    // Optional pre-fill when we already know something about the UPC
    // — e.g. it's in the catalog for a *different* store, so we can
    // seed name/price from that record and let the AM accept-as-is.
    // Nil pre-fills mean "true cold" manual entry (UPC not in catalog
    // at all).
    var prefillName: String? = nil
    var prefillPrice: Decimal? = nil
    var prefillNote: String? = nil
    // Routes the sheet's title/copy. .notInCatalog = "UPC not found",
    // .otherStore = "Available at another store" — visually signals
    // why we're prompting so the AM doesn't think the catalog is stale.
    var reason: Reason = .notInCatalog

    enum Reason {
        case notInCatalog
        case otherStore
    }
}

struct ManualPriceSheet: View {
    let upc: String
    let reason: ManualUPCPrompt.Reason
    let onSave: (ManualOverride) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var priceText: String
    @State private var note: String

    init(
        upc: String,
        reason: ManualUPCPrompt.Reason = .notInCatalog,
        prefillName: String? = nil,
        prefillPrice: Decimal? = nil,
        prefillNote: String? = nil,
        onSave: @escaping (ManualOverride) -> Void
    ) {
        self.upc = upc
        self.reason = reason
        self.onSave = onSave
        _name = State(initialValue: prefillName ?? "")
        _priceText = State(initialValue: prefillPrice.map { Self.formatPrice($0) } ?? "")
        _note = State(initialValue: prefillNote ?? "")
    }

    private static func formatPrice(_ value: Decimal) -> String {
        // Plain decimal string — no currency symbol — so it parses
        // cleanly back through NSDecimalNumber on save.
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        f.usesGroupingSeparator = false
        return f.string(from: value as NSDecimalNumber) ?? "\(value)"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("UPC") {
                    Text(upc).monospaced()
                }
                Section {
                    Text(headsUpMessage)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                } header: { Text("Heads up") }
                Section("Product") {
                    TextField("Product name", text: $name)
                    TextField("Price", text: $priceText)
                        .keyboardType(.decimalPad)
                }
                Section("Note (optional)") {
                    TextField("e.g. new SKU, confirmed with store", text: $note, axis: .vertical)
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { save() }
                        .disabled(!isValid)
                }
            }
        }
    }

    private var navTitle: String {
        switch reason {
        case .notInCatalog: return "UPC not found"
        case .otherStore:   return "Not in this store"
        }
    }

    private var headsUpMessage: String {
        switch reason {
        case .notInCatalog:
            return "This item will be flagged as a manual override in the audit log."
        case .otherStore:
            return "This UPC is in the catalog for another store. Adding it here will be flagged as a manual override in the audit log."
        }
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && parsedPrice != nil
    }

    private var parsedPrice: Decimal? {
        let d = NSDecimalNumber(string: priceText)
        return d == .notANumber ? nil : d as Decimal
    }

    private func save() {
        guard let price = parsedPrice else { return }
        onSave(ManualOverride(
            upc: upc,
            name: name.trimmingCharacters(in: .whitespaces),
            price: price,
            note: note.isEmpty ? nil : note
        ))
        dismiss()
    }
}

// MARK: - Submit confirm sheet

struct SubmitSheet: View {
    let subtotal: Decimal
    let store: String
    let storeNumber: String
    let itemCount: Int
    // Differentiates the new-box flow ("Submit backstock?") from the
    // edit-existing-record flow ("Save changes?"). Reuses the same
    // sheet so layout is consistent — only the labels move.
    var isEditing: Bool = false
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(isEditing ? "Save changes?" : "Submit backstock?")
                    .font(.title3).fontWeight(.medium)
                VStack(spacing: 4) {
                    Text(formatCurrency(subtotal))
                        .font(.system(size: 34, weight: .medium))
                    Text("\(itemCount) item\(itemCount == 1 ? "" : "s") at \(store) #\(storeNumber)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(isEditing
                     ? "This updates the existing box for everyone in your area."
                     : "This will record the session to the audit log and clear the scan list.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(isEditing ? "Confirm and save" : "Confirm and submit") {
                    onConfirm()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
            .padding()
            .navigationTitle(isEditing ? "Save changes" : "Submit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func formatCurrency(_ value: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "en_US")
        return f.string(from: value as NSDecimalNumber) ?? "$\(value)"
    }
}

// MARK: - History, session detail, settings (stubs)

// HistoryView shows every submitted backstock session in the AM's
// area, pulled from the CloudKit public database and grouped by store
// so the AM can see "what's in the back of Target #1842" at a glance.
// Local-only sessions aren't shown separately — every local submit
// uploads, and CloudSyncService.retryPending sweeps up any failed
// uploads on next launch, so the cloud feed is authoritative.
struct HistoryView: View {
    // Store table is still queried locally so we can decorate records
    // with the shortName ("TGT #1842") even when the CloudKit record
    // has only storeName + storeNumber.
    @Query private var stores: [Store]

    // Area + store/number are locked in at the gating screens, so the
    // feed is always scoped to the one physical location the AM is
    // working. No cross-store mixing, no toolbar filter to maintain.
    @AppStorage("selectedArea") private var selectedArea: String = ""
    @AppStorage("selectedStore") private var selectedStore: String = ""
    @AppStorage("selectedStoreNumber") private var selectedStoreNumber: String = ""

    // storeNumber -> shortName label (first non-empty shortName wins).
    // Built once per body evaluation; cheap for the roster sizes we expect.
    private var shortNames: [String: String] {
        var map: [String: String] = [:]
        for s in stores where !s.shortName.isEmpty {
            if map[s.storeNumber] == nil {
                map[s.storeNumber] = s.shortName
            }
        }
        return map
    }

    // Name shown inside the centered header block. Prefer the full
    // store name (selectedStore), fall back to the short code, then
    // empty — the storeNumber line carries the identity on its own.
    private var resolvedStoreName: String {
        if !selectedStore.isEmpty { return selectedStore }
        if let short = shortNames[selectedStoreNumber], !short.isEmpty {
            return short
        }
        return ""
    }

    // Bound to the NavigationStack so we can programmatically push
    // a record onto it from the .openBackstockRecord notification
    // (fired by submitEdit after a successful save). Existing
    // NavigationLink(value:) call sites in StoreHistoryList still
    // work — SwiftUI appends to the bound path automatically.
    @State private var navPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navPath) {
            // Header sits above the scoped list, so the AM always
            // sees the store identity while scrolling. The nav title
            // is kept short ("Backstock") since the header carries
            // the store label — avoids duplicating the same text
            // twice on screen.
            VStack(spacing: 0) {
                DetailHeaderView(
                    storeNumber: selectedStoreNumber,
                    storeName: resolvedStoreName,
                    useNameAsHeadline: true,
                    sublines: selectedArea.isEmpty ? [] : [selectedArea],
                    tinted: true
                )
                StoreHistoryList(
                    area: selectedArea,
                    storeNumber: selectedStoreNumber,
                    storeShortNames: shortNames
                )
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            // Force the nav bar chrome to render opaque. Without this
            // the bar stays translucent (because the root view is a
            // VStack, not a ScrollView, so iOS never flips to the
            // "content has scrolled under the bar" opaque state).
            .toolbarBackground(.visible, for: .navigationBar)
            // Custom principal title so the text renders in full
            // `.primary` color. The system's inline title on a tab
            // root renders at a slightly lighter weight/tint than
            // body text, which looked washed out next to the bold
            // "Box 1 contents" title on the pushed detail screen.
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Backstock")
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
            }
            .navigationDestination(for: TeamBackstockRecord.self) { record in
                TeamSessionDetailView(record: record, storeShortNames: shortNames)
            }
        }
        // After submitEdit posts .openBackstockRecord, RootTabView
        // flips the tab to Backstock and we land here. Reset the
        // path to a single push of the freshly-saved record so the
        // AM lands on its detail screen — regardless of what was on
        // the stack before (the user came from "Edit in Scan" which
        // already popped the prior detail). Defensive reset rather
        // than append so a stuck stale entry can't accumulate.
        .onReceive(NotificationCenter.default.publisher(for: .openBackstockRecord)) { note in
            guard let record = note.userInfo?["record"] as? TeamBackstockRecord else { return }
            navPath = NavigationPath()
            navPath.append(record)
        }
    }
}

// Read-only list of every submitted backstock session for a single
// store (the one the AM picked on the gating screen), pulled from the
// CloudKit public database. Sorted by box number ascending so the AM
// can walk the aisle box-by-box. Refreshable via pull-down.
struct StoreHistoryList: View {
    let area: String
    // The specific storeNumber the user is scoped to. Empty would
    // never reach this view (LaunchCoordinator gates on it), but we
    // still fall back gracefully to showing nothing if it slips through.
    let storeNumber: String
    let storeShortNames: [String: String]

    @State private var records: [TeamBackstockRecord] = []
    @State private var loadState: LoadState = .loading
    @State private var errorMessage: String?

    // Pending deletion — drives the confirmation dialog. We hold the
    // whole record (not just the id) so the dialog can name the box
    // being removed ("Delete Box 3?"). Cleared on confirm/cancel.
    @State private var pendingDelete: TeamBackstockRecord?
    // Surface cloud failures from delete attempts. Separate from
    // loadState's errorMessage so a transient delete failure doesn't
    // wipe the list the AM was looking at.
    @State private var deleteErrorMessage: String?

    // Pending merge — populated when the AM drags one box row onto
    // another. The drop handler captures both records (source +
    // target) and surfaces a confirmation before the destructive
    // "delete source / patch target" CloudKit dance kicks off. Same
    // separation rationale as deleteErrorMessage for mergeErrorMessage.
    @State private var pendingMerge: PendingMerge?
    @State private var mergeErrorMessage: String?

    // Drives the "View all backstock" navigation push from the
    // header button into AllBackstockDetailView. The export menu
    // (CSV / Print / Email) lives on that pushed screen now, not
    // here — keeps this list focused on per-box browsing. The
    // find-an-item search + barcode-scan affordance also lives on
    // that screen now (the "Backstock contents" page), where the
    // flat line-items list is the natural place to filter by UPC.
    @State private var showAllBackstock = false

    // Drives the "Remove all empty boxes" confirmation dialog. An
    // empty box is a CloudKit record with `items.isEmpty` — usually
    // a placeholder created by tapping Submit before scanning, or
    // left behind after every line item was removed individually.
    // Cleanup runs the same per-record CloudSyncService.delete flow
    // as the row swipe / context-menu Delete, just in a loop.
    @State private var pendingEmptyBoxesCleanup = false
    @State private var cleanupErrorMessage: String?

    // Identifiable bundle so the confirmationDialog can present off a
    // single source of truth rather than two separate optional state
    // vars (which would race on dismiss).
    struct PendingMerge: Identifiable {
        let id = UUID()
        let source: TeamBackstockRecord
        let target: TeamBackstockRecord
    }

    enum LoadState { case loading, loaded, failed }

    // Records narrowed to the AM's currently-scoped store. We always
    // fetch the area-wide feed, then filter here, rather than issuing
    // a storeNumber-level CloudKit predicate — area is already
    // Queryable in the Dashboard schema, and the client-side filter
    // on a couple hundred rows is negligible. Saves needing to make
    // storeNumber Queryable too.
    private var filteredRecords: [TeamBackstockRecord] {
        guard !storeNumber.isEmpty else { return [] }
        return records.filter { $0.storeNumber == storeNumber }
    }

    // Box-ascending sort so aisle walk-throughs feel natural. Records
    // missing a box sink to the bottom. Ties break on submittedAt
    // newest-first so a re-submission of the same box shows up ahead
    // of the original.
    private var sortedRecords: [TeamBackstockRecord] {
        filteredRecords.sorted { lhs, rhs in
            switch (lhs.box, rhs.box) {
            case let (l?, r?) where l != r: return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.submittedAt > rhs.submittedAt
            }
        }
    }

    // Empty-box bucket — any record with zero line items. Surfaces
    // both true placeholders (Submit-before-scan) and boxes whose
    // contents were all removed one-by-one. Empty stays empty in
    // CloudKit until something deletes it, which is what the
    // cleanup affordance is for.
    private var emptyBoxes: [TeamBackstockRecord] {
        sortedRecords.filter { $0.items.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            // "View all backstock" header button. Sits flush below the
            // tinted store header (rendered by HistoryView's parent
            // VStack) so it reads as part of the header zone. Pushes
            // AllBackstockDetailView with the current sortedRecords
            // slice — same data the per-box list is showing, so any
            // optimistic updates carry over instantly.
            //
            // Hidden when there's nothing to show so the empty / loading
            // / error states don't carry a useless action above them.
            if !sortedRecords.isEmpty {
                Button {
                    showAllBackstock = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "list.bullet.rectangle")
                        Text("View all backstock contents")
                            .fontWeight(.semibold)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(Color(.secondarySystemGroupedBackground))
                }
                .foregroundStyle(.tint)
                .buttonStyle(.plain)
                .overlay(alignment: .bottom) {
                    Divider()
                }
            }

            // "Remove all empty boxes" — only visible when there's
            // actually something to clean up. Styled as a destructive
            // peer to the View all button above: same row chrome,
            // red foreground so it doesn't read as a routine action,
            // no chevron (it's not a navigation push). Routes through
            // a confirmationDialog before issuing any deletes.
            if !emptyBoxes.isEmpty {
                Button {
                    pendingEmptyBoxesCleanup = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "trash")
                        Text("Remove \(emptyBoxes.count) empty box\(emptyBoxes.count == 1 ? "" : "es")")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(Color(.secondarySystemGroupedBackground))
                }
                .foregroundStyle(.red)
                .buttonStyle(.plain)
                .overlay(alignment: .bottom) {
                    Divider()
                }
            }

            Group {
                switch loadState {
                case .loading:
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Loading backstock…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed:
                VStack(spacing: 8) {
                    Image(systemName: "icloud.slash")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("Couldn't load backstock")
                        .font(.headline)
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    Button("Retry") { Task { await reload() } }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                if sortedRecords.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "tray")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        Text("No backstock yet")
                            .font(.headline)
                        Text("Submitted boxes for this store will appear here.")
                            .font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(sortedRecords) { record in
                            NavigationLink(value: record) {
                                StoreHistoryRow(record: record)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    pendingDelete = record
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            // Long-press → "Merge into…" context menu.
                            //
                            // We tried drag-and-drop first (both the
                            // iOS 17 .draggable/.dropDestination pair
                            // and the older .onDrag/.onDrop +
                            // NSItemProvider pair) but SwiftUI's List
                            // swallows row-level drop callbacks for its
                            // own reorder/move semantics — the lift
                            // animation plays but the drop never
                            // commits. Replacing List with
                            // ScrollView+LazyVStack would free up the
                            // drop, but at the cost of swipe-to-delete
                            // and the system row chrome we already
                            // depend on.
                            //
                            // The long-press menu reaches the same
                            // pendingMerge → confirmationDialog →
                            // performMerge flow, just with a tap-driven
                            // entry point. List doesn't intercept
                            // contextMenu, so it actually fires.
                            .contextMenu {
                                rowContextMenu(record: record)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .refreshable { await reload() }
                }
                }
            }
        }
        // "View all items" navigation. Pushes AllBackstockDetailView
        // with the same sortedRecords slice the AM is currently
        // viewing — so any optimistic updates / box renumbers /
        // merges are reflected instantly without a re-fetch.
        .navigationDestination(isPresented: $showAllBackstock) {
            AllBackstockDetailView(
                records: sortedRecords,
                storeShortNames: storeShortNames,
                storeNumber: storeNumber
            )
        }
        // Reload whenever either the area OR the scoped store changes
        // — switching stores from Settings should re-show the list for
        // the new store without needing a manual pull-to-refresh.
        .task(id: "\(area)|\(storeNumber)") {
            await reload()
        }
        // When a detail-screen edit commits (change quantity, remove
        // item, change box number), TeamSessionDetailView posts
        // `.teamSessionDidUpdate`. Reload so this summary list reflects
        // the new subtotal / item count / box number when the user
        // navigates back.
        //
        // Submit-from-ScanView posts the same notification but attaches
        // the freshly-built TeamBackstockRecord under userInfo["record"].
        // We inject it directly rather than calling reload() — CloudKit
        // public-DB CKQuery is eventually consistent and a refetch
        // immediately after upload often misses the just-saved record,
        // which was the original "submitted boxes don't show" bug.
        .onReceive(NotificationCenter.default.publisher(for: .teamSessionDidUpdate)) { note in
            handleTeamSessionUpdate(note)
        }
        .confirmationDialog(
            deletePrompt,
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { record in
            Button("Delete", role: .destructive) {
                Task { await performDelete(record) }
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: { _ in
            Text("This removes the box from the shared backstock feed for everyone in your area. This can't be undone.")
        }
        .alert(
            "Couldn't delete box",
            isPresented: Binding(
                get: { deleteErrorMessage != nil },
                set: { if !$0 { deleteErrorMessage = nil } }
            ),
            presenting: deleteErrorMessage
        ) { _ in
            Button("OK", role: .cancel) { deleteErrorMessage = nil }
        } message: { msg in
            Text(msg)
        }
        // Merge confirmation. Dragging Box N onto Box M lands here:
        // the source's items get folded into the target (sum quantities
        // on UPC collisions; otherwise append) and the source record
        // is deleted. Destructive enough to warrant an explicit
        // confirmation — accidental drag-drops on a busy list shouldn't
        // silently lose a box.
        .confirmationDialog(
            mergePromptTitle,
            isPresented: Binding(
                get: { pendingMerge != nil },
                set: { if !$0 { pendingMerge = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingMerge
        ) { merge in
            Button("Merge into \(boxLabel(merge.target))", role: .destructive) {
                Task { await performMerge(merge) }
            }
            Button("Cancel", role: .cancel) {
                pendingMerge = nil
            }
        } message: { merge in
            Text("\(boxLabel(merge.source))'s items will be added to \(boxLabel(merge.target)). \(boxLabel(merge.source)) will be deleted from the shared feed. This can't be undone.")
        }
        .alert(
            "Couldn't merge boxes",
            isPresented: Binding(
                get: { mergeErrorMessage != nil },
                set: { if !$0 { mergeErrorMessage = nil } }
            ),
            presenting: mergeErrorMessage
        ) { _ in
            Button("OK", role: .cancel) { mergeErrorMessage = nil }
        } message: { msg in
            Text(msg)
        }
        // "Remove all empty boxes" confirmation. We name the count
        // explicitly so the AM has a chance to bail if it's higher
        // than they expected ("wait, 12 empty boxes? where did those
        // come from").
        .confirmationDialog(
            emptyBoxes.count == 1
                ? "Remove 1 empty box?"
                : "Remove \(emptyBoxes.count) empty boxes?",
            isPresented: $pendingEmptyBoxesCleanup,
            titleVisibility: .visible
        ) {
            Button(
                emptyBoxes.count == 1 ? "Remove empty box" : "Remove \(emptyBoxes.count) empty boxes",
                role: .destructive
            ) {
                Task { await performEmptyBoxesCleanup() }
            }
            Button("Cancel", role: .cancel) {
                pendingEmptyBoxesCleanup = false
            }
        } message: {
            Text("This deletes every box with zero items from the shared backstock feed for everyone in your area. Boxes with items will be left alone. This can't be undone.")
        }
        .alert(
            "Couldn't remove empty boxes",
            isPresented: Binding(
                get: { cleanupErrorMessage != nil },
                set: { if !$0 { cleanupErrorMessage = nil } }
            ),
            presenting: cleanupErrorMessage
        ) { _ in
            Button("OK", role: .cancel) { cleanupErrorMessage = nil }
        } message: { msg in
            Text(msg)
        }
    }

    // Title for the merge confirmationDialog. Falls back to a generic
    // string when pendingMerge is nil (the dialog is dismissed) so the
    // accessibility label still reads sensibly.
    private var mergePromptTitle: String {
        guard let merge = pendingMerge else { return "Merge boxes?" }
        return "Merge \(boxLabel(merge.source)) into \(boxLabel(merge.target))?"
    }

    // "Box 5" when the box number is set, otherwise a date-tagged
    // fallback so we don't show "Box nil" — older records may have
    // landed in CloudKit before the box field existed.
    private func boxLabel(_ record: TeamBackstockRecord) -> String {
        if let box = record.box {
            return "Box \(box)"
        }
        return "Box (\(record.submittedAt.formatted(date: .abbreviated, time: .omitted)))"
    }


    @MainActor
    private func reload() async {
        loadState = .loading
        errorMessage = nil
        do {
            // fetchAllMerged folds in any just-uploaded records that
            // CKQuery hasn't surfaced yet, so a reload triggered by
            // tab-switch right after Submit doesn't drop the new box.
            let fetched = try await CloudSyncService.shared.fetchAllMerged(
                area: area.isEmpty ? nil : area
            )
            records = fetched
            loadState = .loaded
        } catch {
            errorMessage = error.localizedDescription
            loadState = .failed
        }
    }

    // Handle a .teamSessionDidUpdate notification. Extracted from the
    // .onReceive closure because keeping the logic inline pushed the
    // body's modifier chain past the SwiftUI type-checker's complexity
    // budget. Two paths:
    //   1. userInfo carries a fresh record (Submit-from-ScanView path)
    //      — inject directly, no full reload, no CKQuery race.
    //   2. No userInfo (edit/delete/merge/box-change path) — refetch.
    @MainActor
    private func handleTeamSessionUpdate(_ note: Notification) {
        if let record = note.userInfo?["record"] as? TeamBackstockRecord {
            // Only inject for the area we're showing — defense in
            // depth. In practice an AM only ever sees their own
            // area, but a stale notification shouldn't pollute.
            guard area.isEmpty || record.area == area else { return }
            if let idx = records.firstIndex(where: { $0.id == record.id }) {
                records[idx] = record
            } else {
                records.append(record)
            }
            // If this is the very first submission (list was empty
            // / loading / failed), flip to .loaded so the row
            // actually renders instead of the placeholder state.
            loadState = .loaded
        } else {
            Task { await reload() }
        }
    }

    // Title for the delete confirmation — names the specific box so
    // an AM who swiped the wrong row has a chance to catch it before
    // confirming. Falls back to a generic label when the record has
    // no box number.
    private var deletePrompt: String {
        guard let record = pendingDelete else { return "Delete box?" }
        if let box = record.box {
            return "Delete Box \(box)?"
        }
        return "Delete this box?"
    }

    // Optimistic delete: remove from the local array immediately so the
    // row disappears without a round-trip flicker, then push the delete
    // to CloudKit. On failure, restore the record and surface the error.
    @MainActor
    private func performDelete(_ record: TeamBackstockRecord) async {
        pendingDelete = nil
        let originalIndex = records.firstIndex(where: { $0.id == record.id })
        if let idx = originalIndex {
            records.remove(at: idx)
        }
        do {
            try await CloudSyncService.shared.delete(sessionUUID: record.id)
        } catch {
            // Put it back where it was (or at the end if we lost the
            // index) so the user doesn't think it's gone.
            if let idx = originalIndex {
                records.insert(record, at: min(idx, records.count))
            } else {
                records.append(record)
            }
            deleteErrorMessage = error.localizedDescription
        }
    }

    // Bulk-cleanup of every empty box currently visible in the list.
    // We snapshot the targets up front so a record dropping into
    // `emptyBoxes` mid-loop (unlikely — `items` doesn't change while
    // we're awaiting) doesn't widen the deletion set. Optimistic
    // local removal first so the rows disappear immediately, then
    // issue CloudKit deletes one at a time. On any failure we
    // restore *only* the records that didn't successfully delete —
    // the ones that did succeed stay gone.
    @MainActor
    private func performEmptyBoxesCleanup() async {
        pendingEmptyBoxesCleanup = false
        let targets = emptyBoxes
        guard !targets.isEmpty else { return }

        // Snapshot for rollback. Tracks which targets actually
        // deleted, so the alert path can put the rest back.
        let targetIds = Set(targets.map(\.id))
        records.removeAll { targetIds.contains($0.id) }

        var failed: [TeamBackstockRecord] = []
        var firstError: String?
        for record in targets {
            do {
                try await CloudSyncService.shared.delete(sessionUUID: record.id)
            } catch {
                failed.append(record)
                if firstError == nil {
                    firstError = error.localizedDescription
                }
            }
        }

        if !failed.isEmpty {
            // Put the failed ones back. They'll re-sort into place
            // via sortedRecords on the next render.
            records.append(contentsOf: failed)
            cleanupErrorMessage = failed.count == targets.count
                ? (firstError ?? "Network error.")
                : "\(targets.count - failed.count) of \(targets.count) removed. \(failed.count) couldn't be deleted: \(firstError ?? "network error")."
        }
    }

    // Re-number a submitted box. Optimistic local update first so
    // the chip reflects the new number instantly, then patch the
    // CloudKit record. On failure we roll back to the original box
    // value and surface the error through deleteErrorMessage's alert
    // (reusing it rather than adding yet another @State for one-off
    // failures). Posts .teamSessionDidUpdate so any open detail view
    // for this record refreshes its header chip.
    @MainActor
    private func performBoxChange(record: TeamBackstockRecord, newBox: Int) async {
        guard record.box != newBox,
              let idx = records.firstIndex(where: { $0.id == record.id })
        else { return }
        let originalBox = records[idx].box
        records[idx].box = newBox
        do {
            try await CloudSyncService.shared.updateBox(
                sessionUUID: record.id,
                box: newBox
            )
            // Tell any open detail view (and the History list itself
            // if the user has navigated away and back) to refresh.
            // No userInfo so listeners do a full reload — cheap, and
            // avoids needing to construct a partial-update payload.
            NotificationCenter.default.post(name: .teamSessionDidUpdate, object: nil)
        } catch {
            records[idx].box = originalBox
            deleteErrorMessage = "Couldn't change box number: \(error.localizedDescription)"
        }
    }

    // Drag-to-merge handler. Folds source.items into target.items
    // (summing quantities on UPC collisions, target's metadata wins),
    // pushes the patched target to CloudKit, then deletes the source.
    // Optimistic local update with full snapshot rollback if either
    // network call fails — we don't want to leave the AM staring at a
    // half-merged state where the items are duplicated AND the source
    // is still around.
    //
    // Order matters: we update the target first. If that succeeds but
    // the delete fails, the AM at worst has the merged target plus a
    // (now-stale) source they can manually delete; nothing is lost.
    // If we deleted source first and the target update failed, the
    // source's items would simply vanish.
    @MainActor
    private func performMerge(_ merge: PendingMerge) async {
        pendingMerge = nil
        let merged = mergeItemsByUPC(target: merge.target.items, source: merge.source.items)
        let subtotal = merged.reduce(0.0) { $0 + $1.price * Double($1.quantity) }
        let retailTotal = merged.reduce(0.0) { sum, it in
            sum + (it.retailPrice ?? 0) * Double(it.quantity)
        }

        // Snapshot the whole array — easier to roll back than tracking
        // the source's original index plus the target's pre-merge
        // items.
        let snapshot = records

        // Optimistic local update: patch target, drop source.
        if let targetIdx = records.firstIndex(where: { $0.id == merge.target.id }) {
            records[targetIdx].items = merged
            records[targetIdx].subtotal = subtotal
            records[targetIdx].retailTotal = retailTotal
        }
        records.removeAll { $0.id == merge.source.id }

        do {
            try await CloudSyncService.shared.updateItems(
                sessionUUID: merge.target.id,
                items: merged,
                subtotal: subtotal,
                retailTotal: retailTotal
            )
            try await CloudSyncService.shared.delete(sessionUUID: merge.source.id)
            // Wake any open detail screens so they refresh if the user
            // navigates back.
            NotificationCenter.default.post(name: .teamSessionDidUpdate, object: merge.target.id)
        } catch {
            records = snapshot
            mergeErrorMessage = error.localizedDescription
        }
    }

    // Combine two item lists by UPC. On collision, sum quantities and
    // keep the target's per-line metadata (price, name, retail, rank,
    // commodity). Target-wins is the natural read of "merge X into Y" —
    // Y's identity is preserved. Items unique to source are appended
    // in source order so multi-pack adds keep their relative ordering.
    // MARK: Export-all helpers (CSV / Print / Email)
    //
    // These walk every record currently in the History view and emit a
    // single grouped-by-box document. The per-box equivalents on
    // TeamSessionDetailView exist for drill-in detail; these are for
    // when an AM wants the whole store's backstock as one file.

    // Per-row long-press menu. Extracted from the inline
    // `.contextMenu { … }` for the same type-checker reason as
    // exportMenuContents — keeping it inline pushes the row builder
    // past the SwiftUI complexity budget. Has two sections:
    //   • "Change Box #" submenu (1–10, current box disabled)
    //   • "Merge {this box} into…" with a button per other box
    @ViewBuilder
    private func rowContextMenu(record: TeamBackstockRecord) -> some View {
        Menu {
            ForEach(1...10, id: \.self) { box in
                Button("Box \(box)") {
                    Task { await performBoxChange(record: record, newBox: box) }
                }
                .disabled(record.box == box)
            }
        } label: {
            Label("Change Box #", systemImage: "shippingbox")
        }

        Divider()

        let mergeTargets = sortedRecords.filter { $0.id != record.id }
        if mergeTargets.isEmpty {
            Text("No other boxes to merge into")
        } else {
            // Header so it's obvious this menu is about merging the
            // long-pressed box into another, not the other way around.
            // Disabled Text item renders as a section label.
            Text("Merge \(boxLabel(record)) into…")
            ForEach(mergeTargets) { target in
                Button {
                    pendingMerge = PendingMerge(source: record, target: target)
                } label: {
                    Label(boxLabel(target), systemImage: "arrow.triangle.merge")
                }
            }
        }

        Divider()

        // Destructive delete sits at the bottom, separated by a divider
        // so an errant tap from the merge list above doesn't land on
        // it. Routes through the same `pendingDelete` confirmation
        // flow as the swipe-action delete — same alert copy, same
        // CloudKit roundtrip, same optimistic-removal behavior.
        Button(role: .destructive) {
            pendingDelete = record
        } label: {
            Label("Delete \(boxLabel(record))", systemImage: "trash")
        }
    }

    private func mergeItemsByUPC(target: [CloudSyncItem],
                                 source: [CloudSyncItem]) -> [CloudSyncItem] {
        var result = target
        for src in source {
            if let idx = result.firstIndex(where: { $0.upc == src.upc }) {
                let existing = result[idx]
                result[idx] = CloudSyncItem(
                    upc: existing.upc,
                    name: existing.name,
                    quantity: existing.quantity + src.quantity,
                    price: existing.price,
                    retailPrice: existing.retailPrice,
                    rank: existing.rank,
                    commodity: existing.commodity
                )
            } else {
                result.append(src)
            }
        }
        return result
    }
}

// History-row-shaped summary for a TeamBackstockRecord. Shows date,
// total, item count, and a compact store/box label. Read-only —
// records in the cloud feed are always submitted sessions.
struct StoreHistoryRow: View {
    let record: TeamBackstockRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Line 1: date + accent-colored total. Matches the color
            // rhythm on the box-contents line items, so a box's row
            // in the history list reads the same color language as
            // the rows you see when you drill in.
            HStack(alignment: .firstTextBaseline) {
                Text(record.submittedAt, format: .dateTime.month().day().hour().minute())
                    .font(.subheadline).fontWeight(.semibold)
                Spacer()
                Text(currency(record.subtotal))
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundStyle(Color.accentColor)
                    .monospacedDigit()
            }
            // Line 2: items/units caption on the left, Box chip on
            // the right. The Box chip is the other quick-scan anchor
            // in this list (AMs navigate by "what's in box 3?"), so
            // it gets the same accent-capsule treatment as the chips
            // on the box-contents rows.
            HStack(spacing: 6) {
                Text(itemsSummary)
                    .font(.caption).foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                if let box = record.box {
                    Text("Box \(box)")
                        .font(.caption2).fontWeight(.medium)
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.14))
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.vertical, 4)
    }

    // "2 items" or "2 items · 4 units" — skip the units clause when
    // it equals the line count (every line had a quantity of 1), to
    // avoid redundant "2 items · 2 units".
    private var itemsSummary: String {
        let lines = record.items.count
        let units = record.items.reduce(0) { $0 + $1.quantity }
        if lines == units {
            return "\(lines) items"
        }
        return "\(lines) items · \(units) units"
    }

    private func currency(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: value)) ?? "$\(value)"
    }
}


struct HistoryRow: View {
    let session: ScanSession
    // Lookup built by HistoryView. Missing keys → no shortname available,
    // fall back to the generic "Store #..." label.
    let storeShortNames: [String: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(session.startedAt, format: .dateTime.month().day().hour().minute())
                    .fontWeight(.medium)
                Spacer()
                Text(ScanView.currency(session.totalAmount))
                    .fontWeight(.medium)
            }
            HStack {
                Text(itemsSummary)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                StatusPill(status: session.status)
            }
        }
        .padding(.vertical, 4)
    }

    // Items summary includes a compact store label when the session
    // has a storeNumber. Prefers the stores.csv `shortName` ("TGT #1842")
    // when one is mapped, otherwise falls back to "Store #1842" so rows
    // from older sessions or un-shortnamed stores still read cleanly.
    // Appends "Box N" when the session carries a box number.
    private var itemsSummary: String {
        let lines = session.items.count
        let units = session.items.reduce(0) { $0 + $1.quantity }
        var parts: [String] = [
            lines == units ? "\(lines) items" : "\(lines) items · \(units) units"
        ]
        if let storeNumber = session.storeNumber, !storeNumber.isEmpty {
            let label = storeShortNames[storeNumber].map { "\($0) #\(storeNumber)" }
                ?? "Store #\(storeNumber)"
            parts.append(label)
        }
        if let box = session.box {
            parts.append("Box \(box)")
        }
        return parts.joined(separator: " · ")
    }
}

struct StatusPill: View {
    let status: SessionStatus

    var body: some View {
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background)
            .foregroundStyle(foreground)
            .clipShape(Capsule())
    }

    private var label: String {
        switch status {
        case .active: "Active"
        case .submitted: "Submitted"
        case .abandoned: "Abandoned"
        }
    }

    private var background: Color {
        switch status {
        case .submitted: .green.opacity(0.15)
        case .abandoned: .gray.opacity(0.15)
        case .active: .blue.opacity(0.15)
        }
    }

    private var foreground: Color {
        switch status {
        case .submitted: .green
        case .abandoned: .gray
        case .active: .blue
        }
    }
}

// Shared centered-column header used by HistoryView and
// TeamSessionDetailView. Keeps the two surfaces visually identical:
// big prominent number up top, date, then a "Store #NNN / Store Name
// / sublines" stack. Every field is optional so the same component
// works for a list header (no amount, no date, just the store) and a
// detail header (everything).
//
// The design matches the local SessionDetailView / AMCreditTracker
// session detail header, so an AM moving between all three screens
// sees one consistent layout.
struct DetailHeaderView: View {
    var primaryAmount: String? = nil
    var secondaryDate: Date? = nil
    var statusPill: String? = nil
    var storeNumber: String
    var storeName: String
    // When true, the headline line shows "<storeName> #<storeNumber>"
    // and the separate storeName subline is suppressed. Used on the
    // History screen where the AM prefers the real store name over
    // the generic "Store" label — "Target #860" reads better than
    // "Store #860" with "Target" underneath.
    var useNameAsHeadline: Bool = false
    var sublines: [String] = []
    // When true, the header gets an accent-tinted background, an
    // accent-colored primary amount, and a bottom accent divider.
    // Used on the box-contents detail screen to give it a visual
    // lift over the flat white list header on the History tab.
    var tinted: Bool = false
    // When true, ratchets down vertical padding, inter-line spacing,
    // and primary/headline font sizes so the banner doesn't eat as
    // much vertical real estate. Used on the box-contents and
    // backstock-contents detail screens, where the AM is here to
    // see a long line-item list — the header just needs to anchor
    // identity, not dominate the screen.
    var compact: Bool = false

    // Composes the top "identity" line. If the caller opted into
    // the name-headline style and we actually have a name, use it;
    // otherwise fall back to the generic "Store #NNN" label.
    private var headline: String {
        if useNameAsHeadline, !storeName.isEmpty {
            return storeNumber.isEmpty ? storeName : "\(storeName) #\(storeNumber)"
        }
        return storeNumber.isEmpty ? "" : "Store #\(storeNumber)"
    }

    var body: some View {
        VStack(spacing: compact ? 2 : 6) {
            if let amount = primaryAmount {
                Text(amount)
                    .font(compact ? .title2 : .largeTitle).fontWeight(.bold)
                    .foregroundStyle(tinted ? Color.accentColor : .primary)
                    .monospacedDigit()
            }
            if let date = secondaryDate {
                Text(date, format: .dateTime.month(.wide).day().year().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let pill = statusPill {
                Text(pill)
                    .font(.caption).fontWeight(.medium)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Color(.secondarySystemFill))
                    .clipShape(Capsule())
                    .padding(.top, 2)
            }
            if !headline.isEmpty {
                Text(headline)
                    .font(compact ? .subheadline : .title3).fontWeight(.semibold)
                    .multilineTextAlignment(.center)
                    .padding(.top, primaryAmount == nil ? 0 : (compact ? 2 : 6))
            }
            // Only show storeName as its own line when we did NOT
            // already fold it into the headline above — otherwise
            // we'd print it twice.
            if !useNameAsHeadline, !storeName.isEmpty {
                Text(storeName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            ForEach(sublines, id: \.self) { line in
                Text(line)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, compact ? 10 : 18)
        // Tinted variant gets a soft accent wash + a 2pt accent
        // divider along the bottom edge so the header reads as a
        // "banner" rather than a flat block of page background.
        .background(
            tinted
            ? AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color.accentColor.opacity(0.14),
                        Color.accentColor.opacity(0.04)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            : AnyShapeStyle(Color(.systemBackground))
        )
        .overlay(alignment: .bottom) {
            if tinted {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.55))
                    .frame(height: 2)
            }
        }
    }
}

// Read-only detail view for a CloudKit-fetched team session. Mirrors
// SessionDetailView's layout (header / line items / totals) but drops
// all editing affordances — sort, filter, export, print, email —
// because this device isn't the source of truth for team records.
// Identifiable wrapper for the per-item edit sheet. CloudSyncItem
// itself doesn't carry an id — within a single record its UPC is
// effectively unique (ScanSessionStore.add dedupes on UPC), but
// wrapping here keeps the sheet-presentation identity separate from
// record-row identity and avoids accidentally leaking a new protocol
// conformance on CloudSyncItem.
struct PendingItemEdit: Identifiable {
    let id = UUID()
    let item: CloudSyncItem
}

struct TeamSessionDetailView: View {
    // @State so the detail view can edit the record in place and
    // reflect the change without waiting on a full CloudKit refetch.
    // Custom init wires the incoming record through State.initialValue.
    @State private var record: TeamBackstockRecord
    let storeShortNames: [String: String]

    init(record: TeamBackstockRecord, storeShortNames: [String: String]) {
        _record = State(initialValue: record)
        self.storeShortNames = storeShortNames
    }

    // Sort / filter / search state. Mirrors the local SessionDetailView
    // so AMs get the same muscle memory on both surfaces. Filter mode
    // (.manualOnly) is technically always empty on team records (the
    // cloud feed doesn't carry `manualOverride`) — we keep the menu
    // for parity but surface only .all as a useful option.
    @State private var sortOrder: ScanSortOrder = .rank
    @State private var commoditySearch: String = ""

    // Item-level edit plumbing — long-press a row → context menu →
    // Change quantity (opens pendingItemEdit sheet) or Remove
    // (drives pendingItemDelete confirmationDialog). itemErrorMessage
    // surfaces a transient alert when a cloud write fails so we can
    // roll back the local edit.
    @State private var pendingItemEdit: PendingItemEdit?
    @State private var pendingItemDelete: CloudSyncItem?
    @State private var itemErrorMessage: String?

    // Edit-in-scan-view flow. The toolbar pencil button asks for
    // confirmation if there are pending in-flight scans (otherwise
    // editing this box would silently nuke them), then loads the
    // record into ScanSessionStore and flips the tab to Scan.
    @State private var showEditConfirm: Bool = false
    @State private var showEditOverwriteWarning: Bool = false
    @Environment(ScanSessionStore.self) private var scanStore
    @Environment(\.dismiss) private var dismissDetail

    // Sheet plumbing for Export / Email / Print.
    // We key the share sheet off an Identifiable wrapper rather than
    // an (Bool, URL?) pair. Setting two @State vars in sequence from
    // inside a Menu button races with the menu's own dismissal — the
    // sheet would sometimes present before the URL had propagated,
    // showing a blank activity view. One atomic state change fixes it.
    @State private var shareItem: ShareURL?
    @State private var mailPayload: TeamMailPayload?

    private var storeLabel: String {
        if let short = storeShortNames[record.storeNumber], !short.isEmpty {
            return "\(short) #\(record.storeNumber)"
        }
        if !record.storeName.isEmpty {
            return "\(record.storeName) #\(record.storeNumber)"
        }
        return "Store #\(record.storeNumber)"
    }

    // Nav title — prefer "Box N contents" so a drilled-in record is
    // self-identifying ("what am I looking at?"). Falls back to a
    // generic label if the record somehow has no box number attached
    // (older records from before the box field existed).
    private var navTitle: String {
        if let box = record.box {
            return "Box \(box) contents"
        }
        return "Box contents"
    }

    private var isFiltered: Bool {
        sortOrder != .rank || !commoditySearch.isEmpty
    }

    // Apply the current commodity search + sort to the record's items.
    // Kept pure/returnable so both the UI list AND the export helpers
    // consume the same filtered view — "what you see is what you get"
    // when you hit Export/Print/Email.
    private func displayedItems() -> [CloudSyncItem] {
        var filtered = record.items
        if !commoditySearch.isEmpty {
            let q = commoditySearch.lowercased()
            filtered = filtered.filter { ($0.commodity ?? "").lowercased().contains(q) }
        }
        switch sortOrder {
        case .rank:
            return filtered.sorted { (($0.rank ?? .max)) < (($1.rank ?? .max)) }
        case .scanOrder:
            // CloudSyncItem doesn't carry a scan timestamp (the cloud
            // payload is denormalized after submit). Fall back to the
            // record's original item order, which matches insertion.
            return filtered
        case .nameAZ:
            return filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .nameZA:
            return filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                lineItems
                totals
            }
            .padding(.bottom, 40)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Sort menu (leading): mirrors SessionDetailView so AMs get
            // the same controls on every line-items surface. We skip a
            // Filter section here because CloudSyncItem doesn't carry
            // the manualOverride flag — the only meaningful filter on
            // cloud records is the commodity-search field below.
            ToolbarItem(placement: .navigationBarLeading) {
                Menu {
                    Section("Sort") {
                        ForEach(ScanSortOrder.allCases, id: \.self) { order in
                            Button {
                                sortOrder = order
                            } label: {
                                if sortOrder == order {
                                    Label(order.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(order.rawValue)
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: isFiltered
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                }
            }
            // 3-dot menu on the right: Edit, Export CSV, Print, Email.
            // "Edit in Scan view" lives at the top of the menu — it's
            // the only entry that mutates the box, so we separate it
            // from the read-only export actions below it with a Divider.
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        if !scanStore.items.isEmpty && !scanStore.isEditingExistingRecord {
                            // Unsaved scans would be wiped by loading
                            // this box — confirm before clobbering.
                            showEditOverwriteWarning = true
                        } else {
                            startEditingInScanView()
                        }
                    } label: {
                        Label("Edit in Scan view", systemImage: "pencil")
                    }
                    Divider()
                    Button {
                        if let url = buildCSVURL() {
                            shareItem = ShareURL(url: url)
                        }
                    } label: {
                        Label("Export CSV", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        printRecord()
                    } label: {
                        Label("Print", systemImage: "printer")
                    }
                    Button {
                        emailRecord()
                    } label: {
                        Label("Email", systemImage: "envelope")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $shareItem) { wrap in
            TeamActivityView(items: [wrap.url])
        }
        .sheet(item: $pendingItemEdit) { edit in
            QuantityEditSheet(item: edit.item) { newQty in
                Task { await performQuantityEdit(item: edit.item, newQuantity: newQty) }
            }
        }
        // Heads-up before clobbering an in-flight scan session with
        // this box's contents. The AM is more likely to want their
        // current scans preserved than silently lost — give them an
        // out.
        .confirmationDialog(
            "Replace current scan session?",
            isPresented: $showEditOverwriteWarning,
            titleVisibility: .visible
        ) {
            Button("Replace and edit this box", role: .destructive) {
                startEditingInScanView()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("You have \(scanStore.items.count) item\(scanStore.items.count == 1 ? "" : "s") in your current scan session. Loading this box for editing will replace them.")
        }
        .fullScreenCover(item: $mailPayload) { payload in
            TeamMailComposerView(payload: payload)
                .ignoresSafeArea()
        }
        // Delete confirmation — names the item so the AM can catch a
        // mis-tap. Fires the optimistic remove + cloud push.
        .confirmationDialog(
            deleteItemPrompt,
            isPresented: Binding(
                get: { pendingItemDelete != nil },
                set: { if !$0 { pendingItemDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingItemDelete
        ) { item in
            Button("Remove from box", role: .destructive) {
                Task { await performItemDelete(item: item) }
            }
            Button("Cancel", role: .cancel) {
                pendingItemDelete = nil
            }
        } message: { _ in
            Text("Everyone in your area will see the updated box contents.")
        }
        // Error alert shared by both quantity-edit and item-delete
        // paths. On rollback the local state is already restored; we
        // just surface what went wrong.
        .alert(
            "Couldn't update box contents",
            isPresented: Binding(
                get: { itemErrorMessage != nil },
                set: { if !$0 { itemErrorMessage = nil } }
            ),
            presenting: itemErrorMessage
        ) { _ in
            Button("OK", role: .cancel) { itemErrorMessage = nil }
        } message: { msg in
            Text(msg)
        }
    }

    private var header: some View {
        // Centered vertical stack matching the SessionDetailView /
        // AMCreditTracker style: big prominent total up top, date
        // below, then a store-number / store-name / box stack. Keeping
        // the two surfaces (local + team) visually consistent so an AM
        // jumping between them doesn't re-read the layout each time.
        DetailHeaderView(
            primaryAmount: currency(record.subtotal),
            secondaryDate: record.submittedAt,
            storeNumber: record.storeNumber,
            storeName: resolvedStoreName,
            useNameAsHeadline: true,
            // Box is already in the nav title ("Box N contents"),
            // so repeating it in the header subline is redundant.
            sublines: [],
            tinted: true,
            compact: true
        )
    }

    // Prefer the record's own storeName; fall back to the shortName
    // lookup so older records (or those without a denormalized name)
    // still surface something readable.
    private var resolvedStoreName: String {
        if !record.storeName.isEmpty { return record.storeName }
        if let short = storeShortNames[record.storeNumber], !short.isEmpty {
            return short
        }
        return ""
    }

    private var lineItems: some View {
        let sorted = displayedItems()
        let total = record.items.count
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                // Reflect the active sort so the header is honest about
                // what order the rows are in. Lowercased for caption-style
                // prose ("sorted by rank", not "sorted by Rank").
                Text("Line items (sorted by \(sortOrder.rawValue.lowercased()))")
                    .font(.caption).fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Spacer()
                // Show "N of M" when a filter is narrowing the list so
                // the AM can see what they're hiding. Plain count when
                // nothing's filtered.
                if isFiltered {
                    Text("\(sorted.count) of \(total)")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text("\(sorted.count) line\(sorted.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 4)

            // Commodity search — full-width accent-tinted strip with
            // hairline top/bottom borders. The container runs edge-to-
            // edge (like the header banner), with inner padding on the
            // text content so the field doesn't crowd the screen edge.
            HStack(spacing: 8) {
                Image(systemName: "tag")
                    .foregroundStyle(Color.accentColor)
                    .font(.caption)
                TextField("Filter by commodity", text: $commoditySearch)
                    .font(.subheadline)
                    .autocorrectionDisabled()
                if !commoditySearch.isEmpty {
                    Button {
                        commoditySearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Color.accentColor.opacity(0.08))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.30))
                    .frame(height: 0.5)
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.30))
                    .frame(height: 0.5)
            }
            .padding(.bottom, 8)

            VStack(spacing: 0) {
                ForEach(Array(sorted.enumerated()), id: \.element) { idx, item in
                    teamItemRow(item: item)
                        // Make the row's full bounds hit-testable for the
                        // long-press. Without this, the Spacer() and
                        // empty padding regions inside teamItemRow don't
                        // receive gestures, so a long-press only fires
                        // when it lands directly on the name / UPC / price
                        // text. .contentShape(Rectangle()) widens the
                        // gesture surface to the entire row rectangle.
                        .contentShape(Rectangle())
                        // Long-press → standard iOS context menu with
                        // the two edit affordances. Matches the History
                        // long-press-to-edit-box pattern so the detail
                        // screens feel cohesive.
                        .contextMenu {
                            Button {
                                pendingItemEdit = PendingItemEdit(item: item)
                            } label: {
                                Label("Change quantity", systemImage: "number")
                            }
                            Button(role: .destructive) {
                                pendingItemDelete = item
                            } label: {
                                Label("Remove item", systemImage: "trash")
                            }
                        }
                    if idx < sorted.count - 1 {
                        Divider().padding(.leading, 20)
                    }
                }
            }
            .background(Color(.systemBackground))
        }
    }

    private func teamItemRow(item: CloudSyncItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Line 1: name + UPC + quantity chip. Moving UPC up here
            // frees line 2 for the commodity chip, which often runs
            // long (FROZEN DINNER, HEALTH & BEAUTY, etc.) and was
            // getting clipped when it had to share a row with UPC +
            // rank + price.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.name)
                    .font(.subheadline).fontWeight(.semibold)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Text(item.upc)
                    .monospaced()
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                // Quantity chip — accent-tinted when > 1 so multi-pack
                // lines pop in a list full of single-unit scans.
                if item.quantity > 1 {
                    Text("× \(item.quantity)")
                        .font(.caption).fontWeight(.semibold)
                        .monospacedDigit()
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.14))
                        .clipShape(Capsule())
                }
            }
            // Line 2: commodity + rank chips, line total, retail.
            // Commodity now has the full leading edge to breathe.
            HStack(spacing: 6) {
                if let commodity = item.commodity, !commodity.isEmpty {
                    Text(commodity)
                        .font(.caption2).fontWeight(.medium)
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(Capsule())
                        .lineLimit(1)
                }
                // Rank badge. Coloured by quality so the eye goes to
                // the best picks: top-20 green, 21-50 neutral blue,
                // 51+ amber (worth questioning).
                if let rank = item.rank {
                    Text("Rank \(rank)")
                        .font(.caption2).fontWeight(.medium)
                        .foregroundStyle(rankColor(rank))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(rankColor(rank).opacity(0.12))
                        .clipShape(Capsule())
                }
                Spacer()
                // Line total in accent color — the number the AM
                // actually cares about on this row.
                Text(currency(item.price * Double(item.quantity)))
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundStyle(Color.accentColor)
                    .monospacedDigit()
                if let retail = item.retailPrice {
                    Text("(retail \(currency(retail)))")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // Merchandising-rank → color. Top ranks are highlighted in green
    // (prime picks), mid-range stays in the app's neutral accent
    // (blue), and tail ranks get amber so an AM can spot them when
    // scanning a dense list.
    private func rankColor(_ rank: Int) -> Color {
        switch rank {
        case ..<21:  return .green
        case 21..<51: return .accentColor
        default:      return .orange
        }
    }

    private var totals: some View {
        // Distinctive "totals banner" at the bottom of the scroll,
        // mirroring the tinted header up top. Same accent gradient
        // + accent top border, so the scroll reads as "tinted
        // bookends around a white line-item stack" — the two
        // numbers the AM cares about (top-of-page subtotal + this
        // total) now live inside matching colored frames.
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Total")
                    .font(.title3).fontWeight(.semibold)
                Spacer()
                Text(currency(record.subtotal))
                    .font(.title3).fontWeight(.bold)
                    .foregroundStyle(Color.accentColor)
                    .monospacedDigit()
            }
            if record.retailTotal > 0 {
                // Retail subline kept understated — it's reference,
                // not the headline number.
                HStack(alignment: .firstTextBaseline) {
                    Text("Total retail")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(currency(record.retailTotal))
                        .font(.subheadline).fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.04),
                    Color.accentColor.opacity(0.14)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.accentColor.opacity(0.55))
                .frame(height: 2)
        }
        .padding(.top, 12)
    }

    private func currency(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: value)) ?? "$\(value)"
    }

    // MARK: Item edit flow

    // Title for the item-delete confirmationDialog. Names the item so
    // a mis-tap is catchable.
    private var deleteItemPrompt: String {
        guard let item = pendingItemDelete else { return "Remove item?" }
        return "Remove \"\(item.name)\" from this box?"
    }

    // Optimistic quantity bump. Find the line by UPC (our effective
    // in-box identity — ScanSessionStore.add dedupes on UPC at submit
    // time, so there's at most one per record). Replace it with a new
    // CloudSyncItem carrying the updated quantity, recompute totals,
    // push to CloudKit, and on failure revert.
    @MainActor
    private func performQuantityEdit(item: CloudSyncItem, newQuantity: Int) async {
        guard newQuantity != item.quantity else { return }
        guard let idx = record.items.firstIndex(where: { $0.upc == item.upc }) else { return }
        let snapshot = record
        let updated = CloudSyncItem(
            upc: item.upc,
            name: item.name,
            quantity: newQuantity,
            price: item.price,
            retailPrice: item.retailPrice,
            rank: item.rank,
            commodity: item.commodity
        )
        record.items[idx] = updated
        recomputeTotals()
        do {
            try await CloudSyncService.shared.updateItems(
                sessionUUID: record.id,
                items: record.items,
                subtotal: record.subtotal,
                retailTotal: record.retailTotal
            )
            NotificationCenter.default.post(name: .teamSessionDidUpdate, object: record.id)
        } catch {
            record = snapshot
            itemErrorMessage = error.localizedDescription
        }
    }

    // Optimistic remove. Drops the row from the local items array,
    // recomputes totals, pushes the new item set to CloudKit, and
    // reverts on failure.
    @MainActor
    private func performItemDelete(item: CloudSyncItem) async {
        pendingItemDelete = nil
        let snapshot = record
        record.items.removeAll { $0.upc == item.upc }
        recomputeTotals()
        do {
            try await CloudSyncService.shared.updateItems(
                sessionUUID: record.id,
                items: record.items,
                subtotal: record.subtotal,
                retailTotal: record.retailTotal
            )
            NotificationCenter.default.post(name: .teamSessionDidUpdate, object: record.id)
        } catch {
            record = snapshot
            itemErrorMessage = error.localizedDescription
        }
    }

    // Seed the in-memory scan session with this record's contents,
    // flip to the Scan tab, and pop the detail view so the AM lands
    // directly in the editing UI. The selected store / store-number /
    // box pickers on the Scan view are AppStorage-backed — we write
    // those here so the headers and submit context match the record
    // being edited.
    @MainActor
    private func startEditingInScanView() {
        scanStore.loadForEditing(
            recordId: record.id,
            storeName: record.storeName,
            storeNumber: record.storeNumber,
            box: record.box,
            area: record.area,
            status: record.status,
            submittedAt: record.submittedAt,
            items: record.items
        )
        // Sync the AppStorage-backed pickers so the Scan view's
        // headline / store labels match the record. Reading these
        // through UserDefaults is fine — the @AppStorage wrappers in
        // ScanView observe the same keys and re-render automatically.
        UserDefaults.standard.set(record.storeName, forKey: "selectedStore")
        UserDefaults.standard.set(record.storeNumber, forKey: "selectedStoreNumber")
        if let box = record.box {
            UserDefaults.standard.set(box, forKey: "selectedBox")
        }
        NotificationCenter.default.post(name: .switchToScanTab, object: nil)
        // Pop the detail screen so coming back doesn't show stale
        // contents — when the edit completes, the user lands on Scan
        // with the success banner.
        dismissDetail()
    }

    // Keep subtotal and retailTotal derived from items. Called after
    // any local items mutation so the header / totals block match the
    // row set the AM is looking at, and so the CloudKit payload we
    // push up is internally consistent.
    private func recomputeTotals() {
        record.subtotal = record.items.reduce(0.0) { $0 + $1.price * Double($1.quantity) }
        record.retailTotal = record.items.reduce(0.0) { sum, it in
            guard let retail = it.retailPrice else { return sum }
            return sum + retail * Double(it.quantity)
        }
    }

    // Serializes the currently-visible items (after sort + commodity
    // filter) to a CSV in the temp directory. "What you see is what
    // you export" — the AM can narrow to one commodity and ship just
    // that slice. Returns nil if the write fails.
    private func buildCSVURL() -> URL? {
        let sorted = displayedItems()
        var lines = ["#,Name,UPC,Qty,Unit Price,Line Total,Commodity,Rank"]
        func esc(_ s: String) -> String {
            "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        // Two-decimal format keeps prices as proper currency in Excel /
        // Numbers — bare Double interpolation drops trailing zeros, so
        // 4.00 ends up rendered as "4" and breaks the column's numeric
        // alignment (and the AM's expectation of cents).
        func money(_ v: Double) -> String { String(format: "%.2f", v) }
        for (idx, item) in sorted.enumerated() {
            let lineTotal = item.price * Double(item.quantity)
            lines.append([
                "\(idx + 1)",
                esc(item.name),
                item.upc,
                "\(item.quantity)",
                money(item.price),
                money(lineTotal),
                esc(item.commodity ?? ""),
                item.rank.map(String.init) ?? ""
            ].joined(separator: ","))
        }
        let csv = lines.joined(separator: "\n")
        // Name includes the record's store + box so multiple exports
        // don't collide in the temp dir and the filename is meaningful
        // once it lands in Mail / Files.
        let boxPart = record.box.map { "-box\($0)" } ?? ""
        let name = "team-\(record.storeNumber)\(boxPart)-\(record.id.prefix(8)).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    // Renders the record as HTML and hands it to the system print panel.
    // Mirrors SessionDetailView.printSession but walks CloudSyncItem
    // instead of ScannedItem (no manual-override concept here).
    private func printRecord() {
        let sorted   = displayedItems()
        let dateStr  = record.submittedAt.formatted(date: .long, time: .shortened)
        let boxLine  = record.box.map { " · Box \($0)" } ?? ""

        let rows = sorted.enumerated().map { idx, item -> String in
            let commodity = (item.commodity?.isEmpty == false)
                ? " <span class='tag'>\(item.commodity!)</span>" : ""
            let lineTotal = item.price * Double(item.quantity)
            return """
            <tr>
              <td>\(idx + 1)</td>
              <td>\(item.name)\(commodity)<br><small>\(item.upc)</small></td>
              <td>\(item.quantity)</td>
              <td>\(currency(item.price))</td>
              <td>\(currency(lineTotal))</td>
            </tr>
            """
        }.joined()

        let html = """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>
          body { font-family: -apple-system, sans-serif; font-size: 13px; margin: 32px; }
          h2 { margin-bottom: 4px; }
          .meta { color: #666; margin-bottom: 20px; font-size: 12px; }
          table { width: 100%; border-collapse: collapse; }
          th { text-align: left; border-bottom: 2px solid #000; padding: 6px 8px; font-size: 12px; }
          td { padding: 6px 8px; border-bottom: 1px solid #ddd; vertical-align: top; }
          td:nth-child(n+3), th:nth-child(n+3) { text-align: right; }
          small { color: #888; font-family: monospace; }
          .tag { background: #eef; padding: 1px 5px; border-radius: 4px; font-size: 11px; }
          tfoot td { font-weight: bold; border-top: 2px solid #000; }
        </style></head><body>
        <h2>Jacent Backstock Tracker</h2>
        <div class="meta">\(dateStr) · \(storeLabel)\(boxLine) · \(currency(record.subtotal))</div>
        <table>
          <thead><tr><th>#</th><th>Product</th><th>Qty</th><th>Unit</th><th>Total</th></tr></thead>
          <tbody>\(rows)</tbody>
          <tfoot><tr><td colspan="4">Total</td><td>\(currency(record.subtotal))</td></tr></tfoot>
        </table>
        </body></html>
        """

        let formatter = UIMarkupTextPrintFormatter(markupText: html)
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        info.jobName = "Backstock \(storeLabel)\(boxLine)"
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printFormatter = formatter
        controller.present(animated: true)
    }

    // Builds the email payload and opens the composer. Falls back to
    // the share sheet when mail isn't configured (simulator) so the
    // CSV can still leave the device.
    private func emailRecord() {
        let sorted   = displayedItems()
        let dateStr  = record.submittedAt.formatted(date: .long, time: .shortened)
        let boxLine  = record.box.map { " · Box \($0)" } ?? ""

        let subject = "Backstock — \(storeLabel)\(boxLine) — \(dateStr)"

        var body = """
        Jacent Backstock Tracker
        \(dateStr)
        \(storeLabel)\(boxLine)
        Total: \(currency(record.subtotal))
        Items: \(sorted.count) lines

        """
        for (idx, item) in sorted.enumerated() {
            let qty = item.quantity > 1 ? " (×\(item.quantity))" : ""
            let lineTotal = item.price * Double(item.quantity)
            let commodity = (item.commodity?.isEmpty == false) ? " [\(item.commodity!)]" : ""
            body += "\n\(idx + 1). \(item.name)\(qty) — \(currency(lineTotal))  [\(item.upc)]\(commodity)"
        }
        body += "\n\nTotal: \(currency(record.subtotal))\n"

        let csv = buildCSVURL()

        if MFMailComposeViewController.canSendMail() {
            mailPayload = TeamMailPayload(subject: subject, body: body, attachment: csv)
        } else if let csv {
            shareItem = ShareURL(url: csv)
        }
    }
}

// Identifiable wrapper for a URL so SwiftUI's `.sheet(item:)` can
// present the share sheet from a single atomic state change. See the
// comment on `shareItem` in TeamSessionDetailView for the why.
struct ShareURL: Identifiable {
    let id = UUID()
    let url: URL
}

// "View all items" companion to TeamSessionDetailView — same visual
// language (header banner, line item rows, totals strip), but the
// rows are flattened across every submitted box for the current
// store. Each row carries a Box # chip so the AM still knows which
// physical box the line item lives in. Read-only: editing a row
// here would have to route to the right CloudKit record per item,
// which is unnecessarily messy for a view designed for "scan the
// whole store at a glance." If they need to edit, they tap into the
// box from the History list.
struct AllBackstockDetailView: View {
    // @State so the pick-list "Remove from backstock" action (and any
    // future per-record edits initiated from this screen) can patch
    // the visible records in place via .teamSessionDidUpdate userInfo
    // — without requiring a pop-and-re-push to see the new totals.
    // Initialized from the parent's snapshot via the custom init below.
    @State private var records: [TeamBackstockRecord]
    let storeShortNames: [String: String]
    let storeNumber: String

    init(records: [TeamBackstockRecord], storeShortNames: [String: String], storeNumber: String) {
        _records = State(initialValue: records)
        self.storeShortNames = storeShortNames
        self.storeNumber = storeNumber
    }

    @State private var sortOrder: ScanSortOrder = .rank
    // Unified find-an-item search. Substring match across UPC, item
    // name, and commodity in one field — replaces the previous
    // commodity / name pair. Single field is enough because almost
    // every "where is X?" query is naturally one of those three, and
    // the AM doesn't have to think about which box to type into.
    // Pre-fillable from a barcode scan via the toolbar scan button
    // (see showScanner / fullScreenCover below).
    @State private var searchText: String = ""
    @State private var showScanner: Bool = false

    // Export-all sheets. Shared CSV-on-disk goes through ShareURL
    // (Quick Look / share sheet), and the email path uses the same
    // TeamMailPayload wrapper as the per-box export so the system
    // mail composer behaves identically across both surfaces. These
    // moved here from StoreHistoryList so the export action lives on
    // the screen that actually shows "all backstock" — matches user
    // expectation that the menu is about *what's currently visible*.
    @State private var shareItem: ShareURL?
    @State private var mailPayload: TeamMailPayload?

    // Pick-list integration. The store is a singleton injected at the
    // App entry; we read it via @Environment so changes from anywhere
    // (the sheet, the bookmark buttons) trigger fresh row evaluations.
    @Environment(PickListStore.self) private var pickList
    @State private var showPickList: Bool = false

    // Drives the "how many to pick" sheet on flag-add. Identifiable
    // wrapper so SwiftUI's `sheet(item:)` re-presents cleanly when the
    // AM opens the picker, cancels, then picks a different row.
    @State private var pendingPick: PendingPick?

    struct PendingPick: Identifiable {
        let flat: FlatItem
        var id: String { "\(flat.recordId):\(flat.item.upc)" }
    }

    // Flattened item + box info. Box is denormalized onto each row
    // because we no longer have the parent record context once the
    // list is sorted by name / price / etc. recordId is on hand for
    // a stable identity (UPC alone isn't unique across boxes —
    // same UPC may exist in multiple boxes).
    struct FlatItem: Hashable {
        let item: CloudSyncItem
        let box: Int?
        let recordId: String
    }

    // Records arrive pre-sorted by box-asc from StoreHistoryList. We
    // preserve that order in the flatten step so .scanOrder reads
    // box-by-box top-to-bottom — a sensible "natural" order when no
    // explicit sort is selected.
    private var allItems: [FlatItem] {
        records.flatMap { rec in
            rec.items.map { FlatItem(item: $0, box: rec.box, recordId: rec.id) }
        }
    }

    private var grandTotal: Double {
        records.reduce(0.0) { $0 + $1.subtotal }
    }

    private var grandRetail: Double {
        records.reduce(0.0) { $0 + $1.retailTotal }
    }

    private var totalLineCount: Int {
        records.reduce(0) { $0 + $1.items.count }
    }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    private var isFiltered: Bool {
        sortOrder != .rank || !trimmedSearch.isEmpty
    }

    // Mirrors TeamSessionDetailView.displayedItems — same sort modes —
    // so AMs jumping between the two views see consistent behavior.
    // .scanOrder here means "natural" (box-asc, then within-box
    // order). The search field runs a single substring match across
    // UPC, name, and commodity (OR-ed), so typing a UPC narrows by
    // UPC, typing "shopping bag" narrows by name, and typing "TOYS"
    // narrows by commodity — all in one field.
    //
    // The UPC branch strips leading zeros from BOTH sides before
    // comparing — the scanner often returns 13-digit codes
    // (`0637118500117`) for items the catalog stores as 12-digit
    // UPC-A (`637118500117`). Without this normalization, a scan
    // that should hit returns "0 of N" because the literal substring
    // doesn't match. Mirrors the candidate-ladder logic in
    // CatalogService.upcCandidates.
    private func displayedItems() -> [FlatItem] {
        var filtered = allItems
        let q = trimmedSearch.lowercased()
        if !q.isEmpty {
            let qUPC = Self.stripLeadingZeros(q)
            filtered = filtered.filter { flat in
                let itemUPC = Self.stripLeadingZeros(flat.item.upc.lowercased())
                let name = flat.item.name.lowercased()
                let commodity = (flat.item.commodity ?? "").lowercased()
                return itemUPC.contains(qUPC)
                    || name.contains(q)
                    || commodity.contains(q)
            }
        }
        switch sortOrder {
        case .rank:
            return filtered.sorted { ($0.item.rank ?? .max) < ($1.item.rank ?? .max) }
        case .scanOrder:
            return filtered
        case .nameAZ:
            return filtered.sorted { $0.item.name.localizedCaseInsensitiveCompare($1.item.name) == .orderedAscending }
        case .nameZA:
            return filtered.sorted { $0.item.name.localizedCaseInsensitiveCompare($1.item.name) == .orderedDescending }
        }
    }

    private var resolvedStoreName: String {
        if let first = records.first, !first.storeName.isEmpty {
            return first.storeName
        }
        if let short = storeShortNames[storeNumber], !short.isEmpty {
            return short
        }
        return ""
    }

    /// Drop a single leading "0" if the string is purely digits. Used
    /// to normalize UPCs for substring search so the 12-vs-13-digit
    /// inconsistency between scanners and catalog rows doesn't drop
    /// otherwise-valid matches. Non-digit strings pass through
    /// unchanged so name / commodity searches aren't disturbed.
    private static func stripLeadingZeros(_ s: String) -> String {
        guard !s.isEmpty, s.allSatisfy({ $0.isNumber }) else { return s }
        let stripped = String(s.drop(while: { $0 == "0" }))
        return stripped.isEmpty ? s : stripped
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                lineItems
                totals
            }
            .padding(.bottom, 40)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Backstock contents")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Sort menu (leading): mirrors TeamSessionDetailView /
            // SessionDetailView. No Filter section — neither
            // CloudSyncItem nor the flattened FlatItem carries a
            // manual-override flag, so the only meaningful filter here
            // is the unified search field below the header.
            ToolbarItem(placement: .navigationBarLeading) {
                Menu {
                    Section("Sort") {
                        ForEach(ScanSortOrder.allCases, id: \.self) { order in
                            Button {
                                sortOrder = order
                            } label: {
                                if sortOrder == order {
                                    Label(order.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(order.rawValue)
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: isFiltered
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                }
            }
            // Pick-list toolbar entry — visible only when there's at
            // least one flagged item. The badge text shows the
            // count so the AM can tell at a glance how many items
            // are queued. Tapping presents the PickListSheet, which
            // is where the AM checks items off as they pull them.
            if !pickList.items.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showPickList = true
                    } label: {
                        Label("\(pickList.pendingCount)",
                              systemImage: "bookmark.fill")
                            .foregroundStyle(Color.jacentYellow)
                            .font(.subheadline.weight(.semibold))
                    }
                    .accessibilityLabel("Open pick list (\(pickList.items.count) items)")
                }
            }
            // Ellipsis menu: Export CSV / Print / Email — same three
            // actions that used to live on the StoreHistoryList screen,
            // moved here because the natural mental model is "I'm
            // looking at all backstock; export *this*." The CSV/print/
            // email payloads are still grouped by box so the document
            // structure is unchanged from before.
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    exportMenuContents
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showPickList) {
            // Hand the sheet the same records slice the line items
            // are rendered from. The "Remove from backstock" action
            // needs them to compute new quantities + subtotals before
            // pushing the update to CloudKit.
            PickListSheet(availableRecords: records)
        }
        // Patch local records when a per-record update lands —
        // typically from PickListSheet's "Remove from backstock"
        // action, which fires one notification per affected record
        // with the freshly-rebuilt TeamBackstockRecord under
        // userInfo["record"]. Records whose items array becomes
        // empty are dropped from the list so the AM doesn't see a
        // ghost row with zero items.
        .onReceive(NotificationCenter.default.publisher(for: .teamSessionDidUpdate)) { note in
            guard let updated = note.userInfo?["record"] as? TeamBackstockRecord else { return }
            if let idx = records.firstIndex(where: { $0.id == updated.id }) {
                if updated.items.isEmpty {
                    records.remove(at: idx)
                } else {
                    records[idx] = updated
                }
            }
        }
        .sheet(item: $pendingPick) { pick in
            PickQuantitySheet(
                item: pick.flat.item,
                box: pick.flat.box,
                maxQuantity: pick.flat.item.quantity
            ) { chosen in
                addToPickList(flat: pick.flat, quantity: chosen)
            }
        }
        .sheet(item: $shareItem) { wrap in
            TeamActivityView(items: [wrap.url])
        }
        .fullScreenCover(item: $mailPayload) { payload in
            TeamMailComposerView(payload: payload)
                .ignoresSafeArea()
        }
        // Barcode-scan path for the unified search field. We don't
        // care about catalog feedback here (this is a backstock find,
        // not a fresh scan) — every detection just pre-fills the
        // search field and dismisses, returning .added to signal the
        // detection was consumed.
        .fullScreenCover(isPresented: $showScanner) {
            CameraScannerView(notFoundUPC: nil, notFoundReason: nil) { upc in
                searchText = upc
                showScanner = false
                return .added
            }
        }
    }

    // MARK: Export-all helpers (CSV / Print / Email)
    //
    // Lifted from StoreHistoryList. Walks every record currently
    // displayed and emits one grouped-by-box document. The per-box
    // equivalents on TeamSessionDetailView still exist for drill-in
    // detail; these are for "I want the whole store as one file."

    // Menu body extracted into a @ViewBuilder for the same SwiftUI
    // type-checker reason as the per-row context menu above — keeping
    // the inline Menu { Button… Button… Button… } pushed the toolbar
    // builder past the "unable to type-check this expression" budget.
    @ViewBuilder
    private var exportMenuContents: some View {
        Button {
            if let url = buildAllStoreCSVURL() {
                shareItem = ShareURL(url: url)
            }
        } label: {
            Label("Export CSV", systemImage: "square.and.arrow.up")
        }
        .disabled(records.isEmpty)

        Button {
            printAllRecords()
        } label: {
            Label("Print", systemImage: "printer")
        }
        .disabled(records.isEmpty)

        Button {
            emailAllRecords()
        } label: {
            Label("Email", systemImage: "envelope")
        }
        .disabled(records.isEmpty)
    }

    // Resolves the store header used in filenames + document titles.
    // Prefers the full store name from the first record (they all share
    // it within one store-scoped list), falls back to short name then
    // bare "Store #...".
    private var exportStoreLabel: String {
        if let first = records.first, !first.storeName.isEmpty {
            return "\(first.storeName) #\(first.storeNumber)"
        }
        if let short = storeShortNames[storeNumber], !short.isEmpty {
            return "\(short) #\(storeNumber)"
        }
        return "Store #\(storeNumber)"
    }

    // Write a CSV of every line item in every box. Each row carries a
    // Box column up front so the file is easy to filter / pivot in
    // Excel without losing the box grouping. Sort order follows the
    // pre-sorted (box-asc) record order so the export reads the same
    // way the AM scrolled the box list.
    private func buildAllStoreCSVURL() -> URL? {
        guard !records.isEmpty else { return nil }
        var lines = ["Box,Submitted,#,Name,UPC,Qty,Unit Price,Line Total,Commodity,Rank"]
        func esc(_ s: String) -> String {
            "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        // Force two decimals so 4.00 renders as "4.00" (not "4") in
        // Excel / Numbers. Same fix mirrored in the per-box CSV.
        func money(_ v: Double) -> String { String(format: "%.2f", v) }
        for record in records {
            let boxText = record.box.map { "Box \($0)" } ?? "Unboxed"
            let submitted = record.submittedAt.formatted(date: .abbreviated, time: .shortened)
            for (idx, item) in record.items.enumerated() {
                let lineTotal = item.price * Double(item.quantity)
                lines.append([
                    esc(boxText),
                    esc(submitted),
                    "\(idx + 1)",
                    esc(item.name),
                    item.upc,
                    "\(item.quantity)",
                    money(item.price),
                    money(lineTotal),
                    esc(item.commodity ?? ""),
                    item.rank.map(String.init) ?? ""
                ].joined(separator: ","))
            }
        }
        let csv = lines.joined(separator: "\n")
        let safeStore = storeNumber.isEmpty ? "store" : storeNumber
        let stamp = Date().formatted(.iso8601.year().month().day())
        let name = "backstock-\(safeStore)-\(stamp).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    // Render every box as its own HTML section with a small header
    // (box label, time, subtotal) and a per-box item table. A single
    // grand-total row caps the document. Print panel handles paging.
    private func printAllRecords() {
        guard !records.isEmpty else { return }

        let sections = records.map { record -> String in
            let boxLabel = record.box.map { "Box \($0)" } ?? "Unboxed"
            let when = record.submittedAt.formatted(date: .abbreviated, time: .shortened)
            let rows = record.items.enumerated().map { idx, item -> String in
                let commodityTag = (item.commodity?.isEmpty == false)
                    ? " <span class='tag'>\(item.commodity!)</span>" : ""
                let lineTotal = item.price * Double(item.quantity)
                return """
                <tr>
                  <td>\(idx + 1)</td>
                  <td>\(item.name)\(commodityTag)<br><small>\(item.upc)</small></td>
                  <td>\(item.quantity)</td>
                  <td>\(currency(item.price))</td>
                  <td>\(currency(lineTotal))</td>
                </tr>
                """
            }.joined()
            return """
            <h3>\(boxLabel) <span class='meta'>· \(when) · \(currency(record.subtotal))</span></h3>
            <table>
              <thead><tr><th>#</th><th>Product</th><th>Qty</th><th>Unit</th><th>Total</th></tr></thead>
              <tbody>\(rows)</tbody>
            </table>
            """
        }.joined(separator: "<div style='height: 18px'></div>")

        let html = """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>
          body { font-family: -apple-system, sans-serif; font-size: 13px; margin: 32px; }
          h2 { margin-bottom: 4px; }
          h3 { margin-bottom: 4px; margin-top: 0; }
          .meta { color: #666; font-weight: normal; font-size: 12px; }
          .summary { color: #666; margin-bottom: 24px; font-size: 12px; }
          table { width: 100%; border-collapse: collapse; margin-bottom: 4px; }
          th { text-align: left; border-bottom: 2px solid #000; padding: 6px 8px; font-size: 12px; }
          td { padding: 6px 8px; border-bottom: 1px solid #ddd; vertical-align: top; }
          td:nth-child(n+3), th:nth-child(n+3) { text-align: right; }
          small { color: #888; font-family: monospace; }
          .tag { background: #eef; padding: 1px 5px; border-radius: 4px; font-size: 11px; }
          .grand { margin-top: 20px; padding-top: 8px; border-top: 2px solid #000; font-weight: bold; text-align: right; }
        </style></head><body>
        <h2>Jacent Backstock Tracker</h2>
        <div class="summary">\(exportStoreLabel) · \(records.count) box\(records.count == 1 ? "" : "es") · \(Date().formatted(date: .long, time: .shortened))</div>
        \(sections)
        <div class="grand">Grand total: \(currency(grandTotal))</div>
        </body></html>
        """

        let formatter = UIMarkupTextPrintFormatter(markupText: html)
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        info.jobName = "Backstock — \(exportStoreLabel)"
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printFormatter = formatter
        controller.present(animated: true)
    }

    // Open a mail composer with a plain-text grouped-by-box body and
    // the same CSV attached. Falls back to the share sheet on devices
    // that aren't configured for Mail (most simulators) so the file
    // can still leave the device.
    private func emailAllRecords() {
        guard !records.isEmpty else { return }

        let stamp = Date().formatted(date: .long, time: .shortened)
        let subject = "Backstock — \(exportStoreLabel) — \(stamp)"

        var body = """
        Jacent Backstock Tracker
        \(stamp)
        \(exportStoreLabel)
        \(records.count) box\(records.count == 1 ? "" : "es") · Grand total: \(currency(grandTotal))

        """
        for record in records {
            let boxLabel = record.box.map { "Box \($0)" } ?? "Unboxed"
            let when = record.submittedAt.formatted(date: .abbreviated, time: .shortened)
            body += "\n— \(boxLabel) · \(when) · \(currency(record.subtotal)) —\n"
            for (idx, item) in record.items.enumerated() {
                let qty = item.quantity > 1 ? " (×\(item.quantity))" : ""
                let lineTotal = item.price * Double(item.quantity)
                let commodityTag = (item.commodity?.isEmpty == false) ? " [\(item.commodity!)]" : ""
                body += "  \(idx + 1). \(item.name)\(qty) — \(currency(lineTotal))  [\(item.upc)]\(commodityTag)\n"
            }
        }
        body += "\nGrand total: \(currency(grandTotal))\n"

        let csv = buildAllStoreCSVURL()

        if MFMailComposeViewController.canSendMail() {
            mailPayload = TeamMailPayload(subject: subject, body: body, attachment: csv)
        } else if let csv {
            shareItem = ShareURL(url: csv)
        }
    }

    private var header: some View {
        DetailHeaderView(
            primaryAmount: currency(grandTotal),
            secondaryDate: nil,
            storeNumber: storeNumber,
            storeName: resolvedStoreName,
            useNameAsHeadline: true,
            // Box count subline in lieu of a date — there's no single
            // submittedAt for a "view all" page, but "5 boxes" is a
            // useful at-a-glance scope indicator.
            sublines: ["\(records.count) box\(records.count == 1 ? "" : "es")"],
            tinted: true,
            compact: true
        )
    }

    private var lineItems: some View {
        let sorted = displayedItems()
        let total = totalLineCount
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                // Header reflects the active sort. Mirrors
                // TeamSessionDetailView so the two screens stay in sync.
                Text("Line items (sorted by \(sortOrder.rawValue.lowercased()))")
                    .font(.caption).fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Spacer()
                if isFiltered {
                    Text("\(sorted.count) of \(total)")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text("\(sorted.count) line\(sorted.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 4)

            // Unified find-an-item bar — substring-matches the typed
            // text against UPC, name, AND commodity in one shot. The
            // trailing barcode button opens the same CameraScannerView
            // the scan flow uses; on a successful detection the UPC
            // pre-fills `searchText` and the scanner dismisses, so the
            // AM lands back here with the list already narrowed.
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.accentColor)
                    .font(.caption)
                TextField("Search by UPC, name, or commodity", text: $searchText)
                    .font(.subheadline)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    showScanner = true
                } label: {
                    Image(systemName: "barcode.viewfinder")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Scan a barcode")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Color.accentColor.opacity(0.08))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.30))
                    .frame(height: 0.5)
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.30))
                    .frame(height: 0.5)
            }
            .padding(.bottom, 8)

            VStack(spacing: 0) {
                ForEach(Array(sorted.enumerated()), id: \.offset) { idx, flat in
                    flatItemRow(flat: flat)
                    if idx < sorted.count - 1 {
                        Divider().padding(.leading, 20)
                    }
                }
            }
            .background(Color(.systemBackground))
        }
    }

    // Same row anatomy as TeamSessionDetailView.teamItemRow, with a
    // Box # chip prepended on the second line so the AM can tell at
    // a glance which physical box each line lives in.
    private func flatItemRow(flat: FlatItem) -> some View {
        let item = flat.item
        // Pick-list flag state for this specific (record, item) pair.
        // Computed every render so toggles from the sheet immediately
        // invert the row icon without a manual reload.
        let isFlagged = pickList.isFlagged(recordId: flat.recordId, upc: item.upc)
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.name)
                        .font(.subheadline).fontWeight(.semibold)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Text(item.upc)
                        .monospaced()
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if item.quantity > 1 {
                        Text("× \(item.quantity)")
                            .font(.caption).fontWeight(.semibold)
                            .monospacedDigit()
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.14))
                            .clipShape(Capsule())
                    }
                }
                HStack(spacing: 6) {
                    // Box # chip — leading edge of line 2 so it's the
                    // first thing the eye picks up when scanning down.
                    // Same accent treatment as the History row's Box
                    // chip for visual consistency.
                    if let box = flat.box {
                        Text("Box \(box)")
                            .font(.caption2).fontWeight(.semibold)
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.14))
                            .clipShape(Capsule())
                    }
                    if let commodity = item.commodity, !commodity.isEmpty {
                        Text(commodity)
                            .font(.caption2).fontWeight(.medium)
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(Capsule())
                            .lineLimit(1)
                    }
                    if let rank = item.rank {
                        Text("Rank \(rank)")
                            .font(.caption2).fontWeight(.medium)
                            .foregroundStyle(rankColor(rank))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(rankColor(rank).opacity(0.12))
                            .clipShape(Capsule())
                    }
                    Spacer()
                    Text(currency(item.price * Double(item.quantity)))
                        .font(.subheadline).fontWeight(.semibold)
                        .foregroundStyle(Color.accentColor)
                        .monospacedDigit()
                    if let retail = item.retailPrice {
                        Text("(retail \(currency(retail)))")
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            // Bookmark column — toggles this (record, item) on/off
            // the pick list. Filled bookmark with Jacent yellow when
            // flagged so the at-a-glance visual is "I added this to
            // my pull list." Plain outline + secondary tint when not.
            Button {
                togglePickList(flat: flat)
            } label: {
                Image(systemName: isFlagged ? "bookmark.fill" : "bookmark")
                    .font(.title3)
                    .foregroundStyle(isFlagged ? Color.jacentYellow : Color.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isFlagged ? "Remove from pick list" : "Add to pick list")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    /// Tapping the bookmark on a flagged row removes every queued
    /// unit for that (record, upc) pair at once. Tapping on an
    /// unflagged row opens the quantity-pick sheet so the AM can
    /// say "I need 2 of these 5" — that count becomes N individual
    /// rows on the pick list. The qty=1 case shortcuts the sheet
    /// since there's nothing to choose.
    private func togglePickList(flat: FlatItem) {
        if pickList.isFlagged(recordId: flat.recordId, upc: flat.item.upc) {
            pickList.removeAllFor(recordId: flat.recordId, upc: flat.item.upc)
            return
        }
        if flat.item.quantity <= 1 {
            addToPickList(flat: flat, quantity: 1)
        } else {
            pendingPick = PendingPick(flat: flat)
        }
    }

    /// Append N individual pick-list rows from the FlatItem row
    /// context. Each row is one physical unit the AM will check off
    /// independently as they pull it from the box. Pulls storeName
    /// from the owning record so the sheet can show where each unit
    /// lives even after the AM has navigated away from the per-
    /// store screen.
    private func addToPickList(flat: FlatItem, quantity: Int) {
        guard let record = records.first(where: { $0.id == flat.recordId }) else { return }
        // Clamp defensively — the sheet's Stepper already enforces
        // this, but the qty=1 shortcut path skips the sheet, and a
        // future caller might pass something looser.
        let count = max(1, min(quantity, flat.item.quantity))
        let template = PickListItem(
            id: UUID(),                 // overwritten per-row inside addRows
            recordId: record.id,
            upc: flat.item.upc,
            name: flat.item.name,
            box: flat.box,
            storeName: record.storeName,
            storeNumber: record.storeNumber,
            price: flat.item.price,
            commodity: flat.item.commodity,
            addedAt: .now,
            picked: false
        )
        pickList.addRows(template: template, count: count)
    }

    private func rankColor(_ rank: Int) -> Color {
        switch rank {
        case ..<21:   return .green
        case 21..<51: return .accentColor
        default:      return .orange
        }
    }

    private var totals: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Total")
                    .font(.title3).fontWeight(.semibold)
                Spacer()
                Text(currency(grandTotal))
                    .font(.title3).fontWeight(.bold)
                    .foregroundStyle(Color.accentColor)
                    .monospacedDigit()
            }
            if grandRetail > 0 {
                HStack(alignment: .firstTextBaseline) {
                    Text("Total retail")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(currency(grandRetail))
                        .font(.subheadline).fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.04),
                    Color.accentColor.opacity(0.14)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.accentColor.opacity(0.55))
                .frame(height: 2)
        }
        .padding(.top, 12)
    }

    private func currency(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: value)) ?? "$\(value)"
    }
}

// Notification fired by TeamSessionDetailView whenever an edit
// (quantity, delete, box-number) changes the record. StoreHistoryList
// listens and reloads so its summary (date / subtotal / Box chip)
// stays in sync with what the detail screen just committed. Object
// payload is the sessionUUID so a future consumer could key off it.
extension Notification.Name {
    static let teamSessionDidUpdate = Notification.Name("teamSessionDidUpdate")
    // Posted when the AM kicks off "Edit in Scan view" from a box
    // detail screen. RootTabView listens and flips its selected tab
    // to Scan so the loaded items show up immediately. The notification
    // carries no payload — the items + edit-mode flags are already
    // sitting on the shared ScanSessionStore by the time we post.
    static let switchToScanTab = Notification.Name("switchToScanTab")
    // Posted by submitEdit (and any future "save and return to detail"
    // entry point) after a successful CloudKit update. Carries the
    // freshly-rebuilt TeamBackstockRecord under userInfo["record"].
    // Drives a two-step nav: RootTabView flips to the Backstock tab,
    // HistoryView pushes the record onto its NavigationStack so the
    // AM lands back on the box they were editing — now showing the
    // saved state.
    static let openBackstockRecord = Notification.Name("openBackstockRecord")
}

// Pick-list sheet. AM-facing checklist of every item flagged from
// search results — they leave this open while walking the floor and
// tap a row to mark it picked. Unpicked items stay bold; picked
// items get strikethrough + dimmed so the unpicked rows visually
// pop. Pull-to-remove on each row (swipe). Toolbar exposes "Clear
// picked" (when any are checked off) and "Clear all".
struct PickListSheet: View {
    @Environment(PickListStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Records currently visible on the parent screen — used by the
    /// "Remove from backstock" action to look up live quantities and
    /// recompute subtotals before pushing back to CloudKit. Picked
    /// items whose recordId isn't in this slice (e.g. queued from a
    /// different store) are left alone with a warning.
    let availableRecords: [TeamBackstockRecord]

    @State private var pendingRemove: Bool = false
    @State private var isProcessing: Bool = false
    @State private var errorMessage: String?
    @State private var showError: Bool = false

    // Group by box for readability — when an AM is walking from box
    // to box they'd rather see the items grouped than scattered.
    // Within a group we preserve insertion order (chronological flag
    // order) so the most-recently-flagged items sort to the bottom
    // of their box's section.
    private var grouped: [(boxLabel: String, items: [PickListItem])] {
        let buckets = Dictionary(grouping: store.items) { item in
            item.box.map { "Box \($0)" } ?? "Unboxed"
        }
        return buckets
            .sorted { lhs, rhs in
                // Numeric box sort, with "Unboxed" pinned last.
                if lhs.key == "Unboxed" { return false }
                if rhs.key == "Unboxed" { return true }
                let l = Int(lhs.key.replacingOccurrences(of: "Box ", with: "")) ?? .max
                let r = Int(rhs.key.replacingOccurrences(of: "Box ", with: "")) ?? .max
                return l < r
            }
            .map { (boxLabel: $0.key, items: $0.value) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "bookmark")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("No items flagged")
                            .font(.headline)
                        Text("Tap the bookmark on any backstock item to add it here.")
                            .font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        // Tally line at the top — pending count is what
                        // the AM cares about while walking; total is for
                        // context.
                        Section {
                            HStack {
                                Text("\(store.pendingCount) to pull")
                                    .font(.subheadline).fontWeight(.semibold)
                                Spacer()
                                if store.pickedCount > 0 {
                                    Text("\(store.pickedCount) picked")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .listRowBackground(Color.clear)
                        }

                        ForEach(grouped, id: \.boxLabel) { group in
                            Section(group.boxLabel) {
                                ForEach(group.items) { item in
                                    pickRow(item: item)
                                        .swipeActions(edge: .trailing) {
                                            Button(role: .destructive) {
                                                store.remove(item.id)
                                            } label: {
                                                Label("Remove", systemImage: "trash")
                                            }
                                        }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Pick list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        // Top-level destructive action: takes every
                        // checked-off item, decrements its quantity in
                        // the source box (or drops the line if it
                        // hits zero), and removes the entry from the
                        // pick list. Replaces the previous "Clear
                        // picked" affordance — clearing without
                        // updating the source data was a footgun.
                        Button(role: .destructive) {
                            pendingRemove = true
                        } label: {
                            Label("Remove from backstock (\(store.pickedCount))",
                                  systemImage: "tray.and.arrow.up")
                        }
                        .disabled(store.pickedCount == 0 || isProcessing)

                        Button(role: .destructive) {
                            store.clearAll()
                        } label: {
                            Label("Clear all", systemImage: "trash")
                        }
                        .disabled(store.items.isEmpty || isProcessing)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .confirmationDialog(
                "Remove \(store.pickedCount) item\(store.pickedCount == 1 ? "" : "s") from backstock?",
                isPresented: $pendingRemove,
                titleVisibility: .visible
            ) {
                Button("Remove from backstock", role: .destructive) {
                    Task { await removePickedFromBackstock() }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This decrements the picked items' quantities in their source boxes. Lines that reach zero are removed entirely. Everyone in your area will see the update.")
            }
            .alert(
                "Couldn't remove all items",
                isPresented: $showError,
                presenting: errorMessage
            ) { _ in
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { msg in
                Text(msg)
            }
            .overlay {
                if isProcessing {
                    Color.black.opacity(0.18).ignoresSafeArea()
                    ProgressView("Updating backstock…")
                        .padding(20)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }

    /// Apply every checked-off pick to the cloud. Aggregates by
    /// (recordId, upc) so picking 3 of the same SKU decrements once
    /// by 3 instead of three race-prone single-unit updates. Items
    /// whose source record isn't in `availableRecords` (queued from
    /// a different store the AM has since left) stay on the list and
    /// surface as a warning at the end.
    @MainActor
    private func removePickedFromBackstock() async {
        let picked = store.items.filter(\.picked)
        guard !picked.isEmpty else { return }

        // recordId → upc → number of picked units
        var byRecord: [String: [String: Int]] = [:]
        for p in picked {
            byRecord[p.recordId, default: [:]][p.upc, default: 0] += 1
        }

        isProcessing = true
        defer { isProcessing = false }

        var processedIDs: Set<UUID> = []
        var failures: [String] = []
        var skippedOrphans: Int = 0

        for (recordId, upcCounts) in byRecord {
            guard let record = availableRecords.first(where: { $0.id == recordId }) else {
                // Item was flagged from a different store the AM no
                // longer has loaded. Leave it on the list — they can
                // navigate back to that store and run the action
                // again. Tally for the warning summary.
                skippedOrphans += picked.filter { $0.recordId == recordId }.count
                continue
            }

            // Build the post-removal items array. Every UPC in
            // upcCounts gets its quantity decremented by the picked
            // count; lines that reach ≤ 0 are dropped entirely.
            var newItems: [CloudSyncItem] = []
            for item in record.items {
                let removed = upcCounts[item.upc] ?? 0
                let remaining = item.quantity - removed
                if remaining > 0 {
                    newItems.append(CloudSyncItem(
                        upc: item.upc,
                        name: item.name,
                        quantity: remaining,
                        price: item.price,
                        retailPrice: item.retailPrice,
                        rank: item.rank,
                        commodity: item.commodity
                    ))
                }
            }

            let newSubtotal = newItems.reduce(0.0) { $0 + $1.price * Double($1.quantity) }
            let newRetail = newItems.reduce(0.0) {
                $0 + ($1.retailPrice ?? 0) * Double($1.quantity)
            }

            do {
                try await CloudSyncService.shared.updateItems(
                    sessionUUID: record.id,
                    items: newItems,
                    subtotal: newSubtotal,
                    retailTotal: newRetail
                )
                // Stage every picked id from this record for removal
                // — succeed-together semantics so the local list
                // mirrors the cloud state.
                for p in picked where p.recordId == recordId {
                    processedIDs.insert(p.id)
                }

                // Per-record .teamSessionDidUpdate notification with
                // the freshly-rebuilt TeamBackstockRecord. The
                // AllBackstockDetailView listener (and the
                // StoreHistoryList one) patch in place from this so
                // the AM sees the new totals immediately on the
                // screen they were already on, without a pop-and-
                // re-push.
                var updatedRecord = record
                updatedRecord.items = newItems
                updatedRecord.subtotal = newSubtotal
                updatedRecord.retailTotal = newRetail
                NotificationCenter.default.post(
                    name: .teamSessionDidUpdate,
                    object: nil,
                    userInfo: ["record": updatedRecord]
                )
            } catch {
                let label = record.box.map { "Box \($0)" } ?? "Unboxed"
                failures.append("\(label): \(error.localizedDescription)")
            }
        }

        // Prune the local pick list to match what the cloud now reflects.
        for id in processedIDs {
            store.remove(id)
        }

        // Surface anything that didn't go through.
        var lines: [String] = []
        if !failures.isEmpty {
            lines.append("Some boxes couldn't be updated:\n" + failures.joined(separator: "\n"))
        }
        if skippedOrphans > 0 {
            lines.append("\(skippedOrphans) item\(skippedOrphans == 1 ? "" : "s") were flagged from a different store and were left on the list.")
        }
        if !lines.isEmpty {
            errorMessage = lines.joined(separator: "\n\n")
            showError = true
        } else {
            // Clean run — close the sheet so the AM lands back on the
            // (now-fresh) line items list.
            dismiss()
        }
    }

    private func pickRow(item: PickListItem) -> some View {
        Button {
            store.setPicked(item.id, picked: !item.picked)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: item.picked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.picked ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.subheadline)
                        .fontWeight(item.picked ? .regular : .semibold)
                        .foregroundStyle(item.picked ? Color.secondary : Color.primary)
                        .strikethrough(item.picked)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(item.upc)
                            .monospaced()
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        if let commodity = item.commodity, !commodity.isEmpty {
                            Text("·").font(.caption2).foregroundStyle(.tertiary)
                            Text(commodity)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(currency(item.price))
                            .font(.caption).foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func currency(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: value)) ?? "$\(value)"
    }
}

// Asks "how many of this item do you want to pull?" before flagging
// a backstock row to the pick list. Default is 1 (the most common
// case — an AM rarely needs the entire box's stock at once). Capped
// at the box's available quantity so the picked qty can't exceed
// what's actually there. Skipped entirely on qty=1 rows since
// there's nothing to choose.
struct PickQuantitySheet: View {
    let item: CloudSyncItem
    let box: Int?
    let maxQuantity: Int
    let onAdd: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var quantity: Int = 1

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.name)
                            .font(.headline)
                        HStack(spacing: 6) {
                            if let box {
                                Text("Box \(box)")
                                    .font(.caption2).fontWeight(.medium)
                                    .foregroundStyle(Color.accentColor)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.14))
                                    .clipShape(Capsule())
                            }
                            Text(item.upc)
                                .monospaced()
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(maxQuantity) in box")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    Stepper(value: $quantity, in: 1...max(1, maxQuantity)) {
                        HStack {
                            Text("Quantity to pull")
                            Spacer()
                            Text("\(quantity)")
                                .font(.title3.monospacedDigit())
                                .fontWeight(.semibold)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                } footer: {
                    Text("Capped at \(maxQuantity) — the number in this box.")
                }
            }
            .navigationTitle("Add to pick list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        onAdd(quantity)
                        dismiss()
                    } label: {
                        Text("Add")
                            .fontWeight(.semibold)
                    }
                }
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }
}

// Small modal sheet for editing a line-item's quantity. Opens from
// TeamSessionDetailView's context menu ("Change quantity"). Uses a
// Stepper over a TextField because quantities are almost always
// small integer deltas (1 → 2 → 3) and a Stepper keeps thumbs on
// the button without popping the keyboard.
struct QuantityEditSheet: View {
    let item: CloudSyncItem
    let onSave: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var quantity: Int

    init(item: CloudSyncItem, onSave: @escaping (Int) -> Void) {
        self.item = item
        self.onSave = onSave
        _quantity = State(initialValue: item.quantity)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name)
                            .font(.headline)
                        Text(item.upc)
                            .font(.caption2).monospaced()
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                Section("Quantity") {
                    Stepper(value: $quantity, in: 1...99) {
                        Text("\(quantity)")
                            .font(.title3).fontWeight(.semibold)
                            .monospacedDigit()
                    }
                }
                Section {
                    // Preview the new line total so the AM can sanity-
                    // check before saving — pricing is per-unit, so a
                    // bump from 2 to 3 changes the subtotal by one
                    // unit price, not zero.
                    HStack {
                        Text("New line total")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(currency(item.price * Double(quantity)))
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                }
            }
            .navigationTitle("Change quantity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(quantity)
                        dismiss()
                    }
                    .disabled(quantity == item.quantity)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func currency(_ d: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "en_US")
        return f.string(from: d as NSNumber) ?? "$0.00"
    }
}


// File-level twins of SessionDetailView's private helpers. Lifted out
// so TeamSessionDetailView (in a different part of the file) can share
// the same pattern. Same behavior as the local versions — only the
// payload type name differs to avoid colliding with SessionDetailView's
// nested `MailPayload`.
struct TeamMailPayload: Identifiable {
    let id = UUID()
    let subject: String
    let body: String
    let attachment: URL?
}

struct TeamActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uvc: UIActivityViewController, context: Context) {}
}

struct TeamMailComposerView: UIViewControllerRepresentable {
    let payload: TeamMailPayload
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setSubject(payload.subject)
        vc.setMessageBody(payload.body, isHTML: false)
        if let url = payload.attachment,
           let data = try? Data(contentsOf: url) {
            vc.addAttachmentData(data, mimeType: "text/csv", fileName: url.lastPathComponent)
        }
        return vc
    }

    func updateUIViewController(_ vc: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: { dismiss() }) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let dismiss: () -> Void
        init(dismiss: @escaping () -> Void) { self.dismiss = dismiss }
        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult,
                                   error: Error?) {
            dismiss()
        }
    }
}

struct SessionDetailView: View {
    let sessionID: UUID
    @Query private var sessions: [ScanSession]

    @Query private var allProducts: [Product]
    // Used to resolve the session's storeNumber to its shortName for
    // display in the header. Falls back to "Store #..." if no shortName
    // is mapped (same rule as HistoryRow).
    @Query private var allStores: [Store]

    @State private var shareURL: URL?
    @State private var showShare = false
    @State private var mailPayload: MailPayload?
    @State private var sortOrder: ScanSortOrder   = .rank
    @State private var filterMode: ScanFilterMode = .all
    @State private var commoditySearch: String    = ""

    init(sessionID: UUID) {
        self.sessionID = sessionID
        _sessions = Query(filter: #Predicate<ScanSession> { $0.id == sessionID })
    }

    private var isFiltered: Bool {
        filterMode != .all || sortOrder != .rank || !commoditySearch.isEmpty
    }

    // Looks up the commodity for a UPC from the current catalog.
    // Commodity wasn't denormalized onto ScannedItem at scan time, so we
    // resolve it live. Acceptable for filtering; historical accuracy of
    // the commodity field isn't critical.
    private func commodity(for upc: String) -> String? {
        allProducts.first { $0.upc == upc }?.commodity
    }

    // Looks up the merchandising rank for a UPC. Like commodity, not
    // denormalized onto ScannedItem — resolved live from the current
    // catalog. Missing / unranked items get Int.max so they sort last.
    private func rank(for upc: String) -> Int {
        allProducts.first { $0.upc == upc }?.rank ?? Int.max
    }

    // Looks up the retail (shelf) price for a UPC. Returns nil when
    // the catalog row doesn't carry one, so the UI can silently omit
    // the "retail" badge rather than show a placeholder.
    private func retailPrice(for upc: String) -> Decimal? {
        allProducts.first { $0.upc == upc }?.retailPrice
    }

    // Resolves the session's storeNumber to a compact header label.
    // Prefers the stores.csv `shortName` ("TGT #1842"); if no Store
    // row is found or its shortName is empty, falls back to the
    // generic "Store #1842" — same rule as HistoryRow, so the two
    // surfaces stay in sync.
    private func storeLabel(for storeNumber: String) -> String {
        if let match = allStores.first(where: { $0.storeNumber == storeNumber }),
           !match.shortName.isEmpty {
            return "\(match.shortName) #\(storeNumber)"
        }
        return "Store #\(storeNumber)"
    }


    private func displayedItems(for session: ScanSession) -> [ScannedItem] {
        let base = session.items.sorted { $0.scannedAt < $1.scannedAt }
        var filtered: [ScannedItem]
        switch filterMode {
        case .all:        filtered = base
        case .manualOnly: filtered = base.filter { $0.manualOverride }
        }
        if !commoditySearch.isEmpty {
            let q = commoditySearch.lowercased()
            filtered = filtered.filter { (commodity(for: $0.upc) ?? "").lowercased().contains(q) }
        }
        switch sortOrder {
        case .rank:
            // Rank ascending (lower is better), ties broken by the
            // session's scan order so the list stays stable.
            return filtered.sorted { a, b in
                let ra = rank(for: a.upc)
                let rb = rank(for: b.upc)
                if ra != rb { return ra < rb }
                return a.scannedAt < b.scannedAt
            }
        case .scanOrder:  return filtered
        case .nameAZ:     return filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .nameZA:     return filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        }
    }

    var body: some View {
        if let session = sessions.first {
            ScrollView {
                VStack(spacing: 0) {
                    headerSection(session: session)
                    lineItemsSection(session: session)
                    totalsSection(session: session)
                    metadataSection(session: session)
                }
                .padding(.bottom, 40)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Session detail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Section("Sort") {
                            ForEach(ScanSortOrder.allCases, id: \.self) { order in
                                Button {
                                    sortOrder = order
                                } label: {
                                    if sortOrder == order {
                                        Label(order.rawValue, systemImage: "checkmark")
                                    } else {
                                        Text(order.rawValue)
                                    }
                                }
                            }
                        }
                        Section("Filter") {
                            ForEach(ScanFilterMode.allCases, id: \.self) { mode in
                                Button {
                                    filterMode = mode
                                } label: {
                                    if filterMode == mode {
                                        Label(mode.rawValue, systemImage: "checkmark")
                                    } else {
                                        Text(mode.rawValue)
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: isFiltered
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            shareURL = csvURL(for: session)
                            showShare = shareURL != nil
                        } label: {
                            Label("Export CSV", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            printSession(session)
                        } label: {
                            Label("Print", systemImage: "printer")
                        }
                        Button {
                            emailSession(session)
                        } label: {
                            Label("Email", systemImage: "envelope")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showShare) {
                if let url = shareURL {
                    ActivityView(items: [url])
                }
            }
            .fullScreenCover(item: $mailPayload) { payload in
                MailComposerView(payload: payload)
                    .ignoresSafeArea()
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)
                Text("Session not found")
                    .font(.headline)
                Text("This session may have been deleted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Sections

    private func headerSection(session: ScanSession) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(formatCurrency(session.totalAmount))
                    .font(.title3).fontWeight(.semibold)
                Text(session.submittedAt ?? session.startedAt,
                     format: .dateTime.month(.wide).day().year().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if session.status != .submitted {
                    StatusPill(status: session.status)
                }
                if let storeNumber = session.storeNumber, !storeNumber.isEmpty {
                    Text(storeLabel(for: storeNumber))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let box = session.box {
                    Text("Box \(box)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(.systemBackground))
    }

    private func lineItemsSection(session: ScanSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Line items")
                    .font(.caption).fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Spacer()
                if isFiltered {
                    let shown = displayedItems(for: session).count
                    let total = session.items.count
                    Text("\(shown) of \(total)")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 4)

            // Commodity search field — full-width accent-tinted strip
            // with hairline top/bottom borders. Twins the
            // TeamSessionDetailView filter bar.
            HStack(spacing: 8) {
                Image(systemName: "tag")
                    .foregroundStyle(Color.accentColor)
                    .font(.caption)
                TextField("Filter by commodity", text: $commoditySearch)
                    .font(.subheadline)
                    .autocorrectionDisabled()
                if !commoditySearch.isEmpty {
                    Button {
                        commoditySearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color.accentColor.opacity(0.08))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.30))
                    .frame(height: 0.5)
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.30))
                    .frame(height: 0.5)
            }
            .padding(.top, 4)
            .padding(.bottom, 8)

            // Active sort/filter indicator + Clear
            if isFiltered {
                HStack(spacing: 8) {
                    if !commoditySearch.isEmpty {
                        Label(commoditySearch, systemImage: "tag")
                            .font(.caption2).foregroundStyle(.tint)
                    }
                    if filterMode != .all {
                        Label(filterMode.rawValue, systemImage: "line.3.horizontal.decrease")
                            .font(.caption2).foregroundStyle(.tint)
                    }
                    if sortOrder != .rank {
                        Label(sortOrder.rawValue, systemImage: "arrow.up.arrow.down")
                            .font(.caption2).foregroundStyle(.tint)
                    }
                    Spacer()
                    Button("Clear all") {
                        sortOrder       = .rank
                        filterMode      = .all
                        commoditySearch = ""
                    }
                    .font(.caption2).foregroundStyle(.tint)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }

            let items = displayedItems(for: session)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                    lineItemRow(item: item, index: idx + 1)
                    if idx < items.count - 1 {
                        Divider().padding(.leading, 20)
                    }
                }
            }
            .background(Color(.systemBackground))
        }
    }


    private func lineItemRow(item: ScannedItem, index: Int) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(index)")
                .font(.caption).fontWeight(.medium)
                .foregroundStyle(.tertiary)
                .frame(width: 24, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.name)
                        .font(.subheadline).fontWeight(.medium)
                    if item.manualOverride {
                        Text("manual")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    }
                }
                HStack(spacing: 6) {
                    Text(item.upc)
                        .font(.caption2).monospaced()
                        .foregroundStyle(.tertiary)
                    if let com = commodity(for: item.upc) {
                        Text("·").font(.caption2).foregroundStyle(.tertiary)
                        Text(com)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    // Rank badge — skipped for items that don't carry
                    // one (rank(for:) returns Int.max as sentinel).
                    let r = rank(for: item.upc)
                    if r != Int.max {
                        Text("·").font(.caption2).foregroundStyle(.tertiary)
                        Text("Rank \(r)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if let note = item.overrideNote, !note.isEmpty {
                    Text(note)
                        .font(.caption).italic()
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    if item.quantity > 1 {
                        Text("\(item.quantity) × \(formatCurrency(item.price))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(formatCurrency(item.price))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    // Retail price, pulled live from the catalog. Shown
                    // parenthetically so the credit price (above) stays
                    // the primary number. Skipped when the catalog row
                    // doesn't carry a retailPrice.
                    if let rp = retailPrice(for: item.upc) {
                        Text("(retail \(formatCurrency(rp)))")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            Text(formatCurrency(item.lineTotal))
                .font(.subheadline).fontWeight(.medium)
                .monospacedDigit()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func totalsSection(session: ScanSession) -> some View {
        let totalUnits = session.items.reduce(0) { $0 + $1.quantity }
        // Sum retailPrice × quantity for every line where the catalog
        // carries a retail price. Items without a retail price contribute
        // zero — the badge above each line already signals "no retail on
        // file," so we don't double-warn here.
        let retailTotal: Decimal = session.items.reduce(Decimal(0)) { acc, item in
            guard let rp = retailPrice(for: item.upc) else { return acc }
            return acc + rp * Decimal(item.quantity)
        }
        return VStack(spacing: 0) {
            totalsRow(label: "Line items", value: "\(session.items.count)")
            Divider().padding(.leading, 20)
            totalsRow(label: "Total units", value: "\(totalUnits)")
            Divider().padding(.leading, 20)
            totalsRow(label: "Total", value: formatCurrency(session.totalAmount), emphasize: true)
            // Retail total is only meaningful when at least one item
            // had a retailPrice. A zero total most likely means the
            // catalog hasn't been synced with the retail column yet.
            if retailTotal > 0 {
                Divider().padding(.leading, 20)
                totalsRow(label: "Total retail", value: formatCurrency(retailTotal))
            }
        }
        .background(Color(.systemBackground))
        .padding(.top, 20)
    }

    private func totalsRow(label: String, value: String, emphasize: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(emphasize ? .subheadline : .caption)
                .fontWeight(emphasize ? .medium : .regular)
                .foregroundStyle(emphasize ? .primary : .secondary)
            Spacer()
            Text(value)
                .font(emphasize ? .subheadline : .caption)
                .fontWeight(emphasize ? .medium : .regular)
                .monospacedDigit()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func metadataSection(session: ScanSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Audit metadata")
                .font(.caption).fontWeight(.medium)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 8)
            VStack(spacing: 0) {
                metadataRow(label: "Session ID", value: session.id.uuidString)
                Divider().padding(.leading, 20)
                metadataRow(
                    label: "Scan started",
                    value: session.startedAt.formatted(date: .abbreviated, time: .shortened)
                )
                if let submitted = session.submittedAt {
                    Divider().padding(.leading, 20)
                    metadataRow(
                        label: "Submitted",
                        value: submitted.formatted(date: .abbreviated, time: .shortened)
                    )
                }
                if let catalogDate = session.catalogSyncedAt {
                    Divider().padding(.leading, 20)
                    metadataRow(
                        label: "Catalog synced",
                        value: catalogDate.formatted(date: .abbreviated, time: .shortened)
                    )
                }
                if let notes = session.notes, !notes.isEmpty {
                    Divider().padding(.leading, 20)
                    metadataRow(label: "Notes", value: notes)
                }
            }
            .background(Color(.systemBackground))
        }
    }

    private func metadataRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.caption).monospaced()
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    private func formatCurrency(_ value: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "en_US")
        return f.string(from: value as NSDecimalNumber) ?? "$\(value)"
    }

    // Writes a CSV to the temp directory and returns its URL, or nil on failure.
    private func csvURL(for session: ScanSession) -> URL? {
        let sorted = session.items.sorted { $0.scannedAt < $1.scannedAt }
        var lines = ["#,Name,UPC,Qty,Unit Price,Line Total,Manual,Note"]
        // ScannedItem stores price as Decimal — format directly with
        // NSDecimalNumber so we don't lose precision through a Double
        // round-trip on the way to "%.2f".
        let priceFmt: NumberFormatter = {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.minimumFractionDigits = 2
            f.maximumFractionDigits = 2
            f.usesGroupingSeparator = false   // CSV: no thousands commas
            return f
        }()
        func money(_ d: Decimal) -> String {
            priceFmt.string(from: NSDecimalNumber(decimal: d)) ?? "0.00"
        }
        for (idx, item) in sorted.enumerated() {
            func esc(_ s: String) -> String { "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            lines.append([
                "\(idx + 1)",
                esc(item.name),
                item.upc,
                "\(item.quantity)",
                money(item.price),
                money(item.lineTotal),
                item.manualOverride ? "yes" : "no",
                esc(item.overrideNote ?? "")
            ].joined(separator: ","))
        }
        let csv = lines.joined(separator: "\n")
        let name = "session-\(session.id.uuidString.prefix(8)).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    // Renders the session as HTML and sends it to the system print panel.
    private func printSession(_ session: ScanSession) {
        let sorted = session.items.sorted { $0.scannedAt < $1.scannedAt }
        let dateStr = (session.submittedAt ?? session.startedAt)
            .formatted(date: .long, time: .shortened)
        let storeLine = session.storeNumber.map { " · \(storeLabel(for: $0))" } ?? ""

        let rows = sorted.enumerated().map { idx, item -> String in
            let tag = item.manualOverride
                ? " <span class='tag'>manual</span>" : ""
            let note = item.overrideNote.map { "<br><em>\($0)</em>" } ?? ""
            return """
            <tr>
              <td>\(idx + 1)</td>
              <td>\(item.name)\(tag)\(note)<br><small>\(item.upc)</small></td>
              <td>\(item.quantity)</td>
              <td>\(formatCurrency(item.price))</td>
              <td>\(formatCurrency(item.lineTotal))</td>
            </tr>
            """
        }.joined()

        let html = """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>
          body { font-family: -apple-system, sans-serif; font-size: 13px; margin: 32px; }
          h2 { margin-bottom: 4px; }
          .meta { color: #666; margin-bottom: 20px; font-size: 12px; }
          table { width: 100%; border-collapse: collapse; }
          th { text-align: left; border-bottom: 2px solid #000; padding: 6px 8px; font-size: 12px; }
          td { padding: 6px 8px; border-bottom: 1px solid #ddd; vertical-align: top; }
          td:nth-child(n+3), th:nth-child(n+3) { text-align: right; }
          small { color: #888; font-family: monospace; }
          .tag { background: #fff3cd; padding: 1px 5px; border-radius: 4px; font-size: 11px; }
          tfoot td { font-weight: bold; border-top: 2px solid #000; }
        </style></head><body>
        <h2>Jacent Backstock Tracker</h2>
        <div class="meta">\(dateStr)\(storeLine) · \(formatCurrency(session.totalAmount))</div>
        <table>
          <thead><tr><th>#</th><th>Product</th><th>Qty</th><th>Unit</th><th>Total</th></tr></thead>
          <tbody>\(rows)</tbody>
          <tfoot><tr><td colspan="4">Total</td><td>\(formatCurrency(session.totalAmount))</td></tr></tfoot>
        </table>
        </body></html>
        """

        let formatter = UIMarkupTextPrintFormatter(markupText: html)
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        info.jobName = "Backstock Session \(dateStr)"
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printFormatter = formatter
        controller.present(animated: true)
    }

    // Prepares the mail payload and opens the composer. Falls back to
    // the system share sheet on devices without a configured mail account
    // (e.g. the simulator) so the user can still hand the CSV off.
    private func emailSession(_ session: ScanSession) {
        let sorted  = session.items.sorted { $0.scannedAt < $1.scannedAt }
        let dateStr = (session.submittedAt ?? session.startedAt)
            .formatted(date: .long, time: .shortened)
        let storeLine = session.storeNumber.map { " · \(storeLabel(for: $0))" } ?? ""

        let subject = "Backstock session — \(dateStr)"

        var body = """
        Jacent Backstock Tracker session
        \(dateStr)\(storeLine)
        Total: \(formatCurrency(session.totalAmount))
        Items: \(session.items.count) lines

        """
        for (idx, item) in sorted.enumerated() {
            let qty = item.quantity > 1 ? " (×\(item.quantity))" : ""
            let note = item.overrideNote.map { " — \($0)" } ?? ""
            body += "\n\(idx + 1). \(item.name)\(qty) — \(formatCurrency(item.lineTotal))  [\(item.upc)]\(note)"
        }
        body += "\n\nTotal: \(formatCurrency(session.totalAmount))\n"

        let csv = csvURL(for: session)

        if MFMailComposeViewController.canSendMail() {
            mailPayload = MailPayload(subject: subject, body: body, attachment: csv)
        } else if let csv {
            // Simulator / no mail account — hand the CSV to the share
            // sheet so the user can pick Mail (or anything else) manually.
            shareURL  = csv
            showShare = true
        }
    }

    private struct ActivityView: UIViewControllerRepresentable {
        let items: [Any]
        func makeUIViewController(context: Context) -> UIActivityViewController {
            UIActivityViewController(activityItems: items, applicationActivities: nil)
        }
        func updateUIViewController(_ uvc: UIActivityViewController, context: Context) {}
    }

    struct MailPayload: Identifiable {
        let id = UUID()
        let subject: String
        let body: String
        let attachment: URL?
    }

    private struct MailComposerView: UIViewControllerRepresentable {
        let payload: MailPayload
        @Environment(\.dismiss) private var dismiss

        func makeUIViewController(context: Context) -> MFMailComposeViewController {
            let vc = MFMailComposeViewController()
            vc.mailComposeDelegate = context.coordinator
            vc.setSubject(payload.subject)
            vc.setMessageBody(payload.body, isHTML: false)
            if let url = payload.attachment,
               let data = try? Data(contentsOf: url) {
                vc.addAttachmentData(data, mimeType: "text/csv", fileName: url.lastPathComponent)
            }
            return vc
        }

        func updateUIViewController(_ vc: MFMailComposeViewController, context: Context) {}

        func makeCoordinator() -> Coordinator { Coordinator(dismiss: { dismiss() }) }

        final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
            let dismiss: () -> Void
            init(dismiss: @escaping () -> Void) { self.dismiss = dismiss }
            func mailComposeController(_ controller: MFMailComposeViewController,
                                       didFinishWith result: MFMailComposeResult,
                                       error: Error?) {
                dismiss()
            }
        }
    }
}

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @State private var isSyncing = false
    @State private var lastSyncMessage: String = ""
    @State private var isStoreSyncing = false
    @State private var lastStoreSyncMessage: String = ""
    // The AM's current area. Changing it clears the saved store
    // selection so the Scan tab doesn't try to reuse a store from
    // the previous area on next launch.
    @AppStorage("selectedArea") private var selectedArea: String = ""
    @AppStorage("selectedStore") private var selectedStore: String = ""
    @AppStorage("selectedStoreNumber") private var selectedStoreNumber: String = ""
    @Environment(ScanSessionStore.self) private var sessionStore
    @State private var showAreaPicker = false
    @State private var showStorePicker = false

    // Short label for the current store row. Prefers the full chain
    // name; falls back to the short ticker, then a raw "#…".
    private var storeRowLabel: String {
        guard !selectedStoreNumber.isEmpty else { return "Not set" }
        if !selectedStore.isEmpty {
            return "\(selectedStore) #\(selectedStoreNumber)"
        }
        return "Store #\(selectedStoreNumber)"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Area") {
                    Button {
                        showAreaPicker = true
                    } label: {
                        HStack {
                            Text("Current area")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(selectedArea.isEmpty ? "Not set" : selectedArea)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                Section("Store") {
                    Button {
                        showStorePicker = true
                    } label: {
                        HStack {
                            Text("Current store")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(storeRowLabel)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                Section("Product catalog") {
                    // TODO: live sync status row + "Sync now" + "View log"
                    Button(isSyncing ? "Syncing…" : "Sync now") {
                        Task { await runSync() }
                    }
                    .disabled(isSyncing)
                    if !lastSyncMessage.isEmpty {
                        Text(lastSyncMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Stores") {
                    Button(isStoreSyncing ? "Syncing…" : "Sync now") {
                        Task { await runStoreSync() }
                    }
                    .disabled(isStoreSyncing)
                    if !lastStoreSyncMessage.isEmpty {
                        Text(lastStoreSyncMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showAreaPicker) {
                AreaPickerView {
                    // Changing area invalidates the prior store + number
                    // since they belong to the old area's store set.
                    // Clearing them re-triggers LaunchCoordinator's
                    // StorePickerView gate so the AM lands on store
                    // selection on their next return to Scan/History.
                    selectedStore = ""
                    selectedStoreNumber = ""
                    // Any in-progress scan session belongs to the old
                    // store, so wipe it to avoid mis-attribution on
                    // submit.
                    sessionStore.clear()
                }
            }
            .sheet(isPresented: $showStorePicker) {
                StorePickerView {
                    // Switching stores mid-day is rare but legitimate
                    // (e.g., an AM covering two stores back-to-back).
                    // Clear the in-progress session so the new store's
                    // submit doesn't inherit the old store's items.
                    sessionStore.clear()
                    // After saving the new store selection, send the
                    // AM straight to Scan — that's almost always why
                    // they came to Settings (start scanning at the
                    // new store), so skip the extra tap.
                    NotificationCenter.default.post(name: .switchToScanTab, object: nil)
                }
            }
        }
    }

    private func runSync() async {
        isSyncing = true
        defer { isSyncing = false }
        // Google Drive share URL for catalog.csv.
        // Either share link format works — the SyncService normalizes it.
        guard let url = URL(string: "https://drive.google.com/file/d/1izR-bDANhkOBlOyvgB9k4gCHOUSn6x5n") else { return }
        let service = SyncService(sourceURL: url)
        let container = context.container
        let record = await service.sync(into: container)
        await MainActor.run {
            context.insert(record)
            try? context.save()
            lastSyncMessage = record.status == .success
                ? "Synced \(record.productCount) products."
                : "Sync failed: \(record.errorMessage ?? "unknown error")"
        }
    }

    private func runStoreSync() async {
        isStoreSyncing = true
        defer { isStoreSyncing = false }
        let container = context.container
        await StoreSyncCoordinator.shared.run(container: container)
        await MainActor.run {
            switch StoreSyncCoordinator.shared.state {
            case .succeeded(let count):
                lastStoreSyncMessage = "Synced \(count) stores."
            case .failed(let message):
                lastStoreSyncMessage = "Sync failed: \(message)"
            default:
                lastStoreSyncMessage = ""
            }
        }
    }
}

// MARK: - Camera scanner (fallback when no hand scanner available)

// Wraps Apple's DataScannerViewController (iOS 16+) in a UIViewController
// representable. Batch mode: stays open and calls onScan for each unique
// barcode detected until the AM taps Done.
//
// Requires Info.plist entry:
//   NSCameraUsageDescription: "Scan product barcodes when a hand scanner
//   isn't available."
//
// Supported symbologies match Apple's Vision framework: UPC-A, UPC-E,
// EAN-13, EAN-8, Code 128, Code 39, QR. Jacent products use UPC-A
// primarily — the extras cost nothing to leave enabled.
//
// UPC FORMAT FLEXIBILITY: DataScannerViewController can report a given
// barcode as either UPC-A (12 digits) or EAN-13 (13 digits with leading
// zero) depending on the device and scanner settings. Rather than
// normalize here, we pass the raw value through — CatalogService.lookup
// tries both formats against the catalog so matching works regardless
// of which representation the catalog uses.

// Result of handing a scanned UPC to the parent. Lets the camera decide
// what to do next — auto-close on success, keep scanning on not-found.
enum ScanResult {
    case added
    case notFound
}

struct CameraScannerView: View {
    let notFoundUPC: String?
    let notFoundReason: String?
    let onScan: (String) -> ScanResult

    @Environment(\.dismiss) private var dismiss
    @State private var lastScannedUPC: String?
    @State private var scanCount: Int = 0
    @State private var isSupported = DataScannerViewController.isSupported
        && DataScannerViewController.isAvailable

    var body: some View {
        ZStack(alignment: .bottom) {
            if isSupported {
                DataScannerRepresentable { upc in
                    handleDetection(upc)
                }
                .ignoresSafeArea()
            } else {
                // Older devices or unavailable hardware. Fall back to
                // a message — the AM can still use the text field.
                VStack(spacing: 12) {
                    Image(systemName: "camera.metering.unknown")
                        .font(.system(size: 48)).foregroundStyle(.secondary)
                    Text("Camera scanning unavailable")
                        .font(.headline)
                    Text("Your device doesn't support live barcode scanning. Please use a hand scanner or type the UPC manually.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            }

            VStack {
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .padding()
                }
                Spacer()
                if isSupported {
                    scanStatusBar
                }
            }
        }
    }

    private var scanStatusBar: some View {
        VStack(spacing: 4) {
            if let lastScannedUPC, notFoundUPC == lastScannedUPC {
                // Show the specific reason (not in catalog / wrong store /
                // no store selected) with the scanned UPC for context.
                Text(notFoundReason ?? "Not in catalog")
                    .font(.caption).fontWeight(.medium)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                Text(lastScannedUPC)
                    .font(.caption2).monospaced()
                    .foregroundStyle(.white.opacity(0.85))
            } else if let lastScannedUPC {
                Text("Added: \(lastScannedUPC)")
                    .font(.caption).monospaced()
                    .foregroundStyle(.white)
            } else {
                Text("Point at a barcode")
                    .font(.caption).foregroundStyle(.white)
            }
            Text("\(scanCount) scanned this session")
                .font(.caption2).foregroundStyle(.white.opacity(0.75))
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.55))
    }

    // Debounce: the DataScanner fires continuously while a barcode is in
    // view. We only want to register a scan once per unique code, with a
    // short cooldown so the AM can re-scan the same item intentionally.
    @State private var recentlyScanned: [String: Date] = [:]

    private func handleDetection(_ upc: String) {
        let trimmed = upc.trimmingCharacters(in: .whitespaces)
        let now = Date()
        if let last = recentlyScanned[trimmed], now.timeIntervalSince(last) < 2.0 {
            return
        }
        recentlyScanned[trimmed] = now
        lastScannedUPC = trimmed
        scanCount += 1
        // ScanSessionStore.add() or handleScan()'s not-found branch
        // plays the appropriate sound, so we don't double-chirp here.
        let result = onScan(trimmed)
        if result == .added {
            // Small delay so the AM briefly sees the "Added: [UPC]"
            // confirmation before the camera dismisses. Feels less
            // abrupt than closing instantly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                dismiss()
            }
        }
    }
}

// UIViewControllerRepresentable wrapping DataScannerViewController. This
// is a minimal bridge — Apple's scanner handles autofocus, highlighting
// detected codes, and low-light adaptation automatically.
struct DataScannerRepresentable: UIViewControllerRepresentable {
    let onBarcode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [
                .barcode(symbologies: [.upce, .ean13, .ean8, .code128, .code39, .qr])
            ],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onBarcode: onBarcode) }

    class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onBarcode: (String) -> Void
        init(onBarcode: @escaping (String) -> Void) { self.onBarcode = onBarcode }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let code) = item, let payload = code.payloadStringValue {
                    onBarcode(payload)
                }
            }
        }
    }
}

// MARK: - Background refresh hook (optional)

// Register this task identifier in Info.plist under
// "Permitted background task scheduler identifiers":
//   com.jacent.backstock.catalog-sync
//
// Then in your AppDelegate / App init:
//
//   BGTaskScheduler.shared.register(
//       forTaskWithIdentifier: "com.jacent.backstock.catalog-sync",
//       using: nil
//   ) { task in
//       Task {
//           let url = URL(string: "https://drive.google.com/file/d/1izR-bDANhkOBlOyvgB9k4gCHOUSn6x5n")!
//           let svc = SyncService(sourceURL: url)
//           _ = await svc.sync(into: sharedContainer)
//           task.setTaskCompleted(success: true)
//       }
//   }
//
// And schedule it after successful foreground syncs:
//
//   let req = BGAppRefreshTaskRequest(identifier: "com.jacent.backstock.catalog-sync")
//   req.earliestBeginDate = Date(timeIntervalSinceNow: 6 * 60 * 60)
//   try? BGTaskScheduler.shared.submit(req)
