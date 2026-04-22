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

// MARK: - App entry

@main
struct BackstockTrackerApp: App {
    // Shared SwiftData container. All five @Model types registered here.
    let container: ModelContainer = {
        do {
            let schema = Schema([
                Product.self,
                ScanSession.self,
                ScannedItem.self,
                CatalogSync.self,
                AreaManager.self,
                AreaManagerSync.self,
                Store.self,
                StoreSync.self
            ])
            let config = ModelConfiguration(schema: schema)
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("ModelContainer failed: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            LaunchCoordinator()
                .environment(ScanSessionStore())
                .task {
                    // Prime the audio service so its session config runs
                    // during launch, not on first scan.
                    _ = AudioService.shared
                    // AM roster syncs on app launch only. The catalog
                    // has its own schedule (foreground + BGAppRefresh).
                    await syncAreaManagersOnLaunch()
                }
        }
        .modelContainer(container)
    }

    private func syncAreaManagersOnLaunch() async {
        // Run all four syncs in parallel. Roster blocks the UI
        // (LaunchCoordinator waits on it). The others run non-blocking —
        // the UI loads immediately and each table populates in the
        // background while the AM picks their identity.
        async let roster: Void = RosterSyncCoordinator.shared.run(container: container)
        async let catalog: Void = CatalogSyncCoordinator.shared.run(container: container)
        async let stores: Void = StoreSyncCoordinator.shared.run(container: container)
        _ = await (roster, catalog, stores)
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
    var catalogSyncedAt: Date?           // catalog freshness at session time

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
         catalogSyncedAt: Date? = nil) {
        self.id = id
        self.employeeNumber = employeeNumber
        self.startedAt = startedAt
        self.submittedAt = nil
        self.totalAmount = 0
        self.statusRaw = status.rawValue
        self.notes = nil
        self.storeNumber = storeNumber
        self.catalogSyncedAt = catalogSyncedAt
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

// MARK: - Session store (in-memory, observable)

// The active scan session lives in memory while an AM is scanning.
// Only on submit does it get persisted as a ScanSession. Abandoned
// sessions stay out of the audit log unless explicitly saved.
@Observable
final class ScanSessionStore {
    struct InMemoryItem: Identifiable, Hashable {
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

    var subtotal: Decimal {
        items.reduce(0) { $0 + $1.lineTotal }
    }

    func add(_ item: InMemoryItem) {
        items.append(item)
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

    // Persist the active session to SwiftData.
    @MainActor
    func submit(into context: ModelContext, catalogSyncedAt: Date?) throws {
        guard !items.isEmpty else { return }

        let session = ScanSession(
            employeeNumber: currentEmployeeNumber,
            status: .submitted,
            storeNumber: currentStoreNumber,
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

// Root gate: waits for the roster to sync, then shows the main app.
// Once at least one AreaManager is in SwiftData, RootTabView takes over.
struct LaunchCoordinator: View {
    @Query private var managers: [AreaManager]

    var body: some View {
        Group {
            if managers.isEmpty {
                LoadingRosterView()
            } else {
                RootTabView()
            }
        }
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
    var body: some View {
        TabView {
            ScanView()
                .tabItem { Label("Scan", systemImage: "barcode.viewfinder") }
            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
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
    case priceHigh = "Price: High–Low"
    case priceLow  = "Price: Low–High"
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

    @State private var showManualOverride = false
    @State private var missingUPC: String = ""
    @State private var showSubmitConfirm = false
    @State private var showCamera = false
    @State private var editMode: EditMode = .inactive
    @State private var selectedItems: Set<UUID> = []

    // Camera-facing state so the camera view can show a 'not found'
    // flash when a scanned UPC isn't in the catalog.
    @State private var cameraNotFoundUPC: String?
    // Reason text accompanying cameraNotFoundUPC — distinguishes between
    // "not in catalog" and "wrong store" cases.
    @State private var cameraNotFoundReason: String?

    // Error message shown in the manual-entry path when a scan is rejected
    // because of store mismatch (doesn't go through the override sheet).
    @State private var lastScanErrorMessage: String?

    // Selected store and store number persist across launches. AMs
    // typically spend a full day at one store, so remembering the last
    // selection is a kindness. Empty strings mean "not yet selected."
    @AppStorage("selectedStore") private var selectedStore: String = ""
    @AppStorage("selectedStoreNumber") private var selectedStoreNumber: String = ""

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
                itemsList
                actionBar
            }
            .environment(\.editMode, $editMode)
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("Jacent Backstock Tracker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
            }
            .sheet(isPresented: $showManualOverride) {
                ManualPriceSheet(upc: missingUPC) { override in
                    addManualItem(override)
                }
            }
            .sheet(isPresented: $showSubmitConfirm) {
                SubmitSheet(
                    subtotal: store.subtotal,
                    store: selectedStore,
                    storeNumber: selectedStoreNumber,
                    itemCount: store.items.count
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

    // Two dependent pickers: store (retailer chain) and store number.
    // Picking a store filters the store-number picker to just the
    // numbered locations for that chain.
    private var storePickerBar: some View {
        let storeService = StoreService(context: context)
        let storeNames = storeService.distinctStoreNames(in: "")
        let availableNumbers = selectedStore.isEmpty
            ? []
            : storeService.storeNumbers(for: selectedStore, in: "")

        return HStack(spacing: 10) {
            // Store name picker
            Menu {
                ForEach(storeNames, id: \.self) { name in
                    Button {
                        if selectedStore != name {
                            selectedStore = name
                            // Reset store number when the chain changes —
                            // the previous number won't apply to the new
                            // chain, and we want the AM to pick explicitly.
                            selectedStoreNumber = ""
                        }
                    } label: {
                        HStack {
                            Text(name)
                            if selectedStore == name {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selectedStore.isEmpty ? "Store" : selectedStore)
                        .fontWeight(selectedStore.isEmpty ? .regular : .medium)
                        .foregroundStyle(selectedStore.isEmpty ? .secondary : .primary)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .disabled(!store.items.isEmpty)
            .opacity(store.items.isEmpty ? 1.0 : 0.5)

            // Store number picker, dependent on the selected store
            Menu {
                ForEach(availableNumbers, id: \.self) { num in
                    Button {
                        selectedStoreNumber = num
                    } label: {
                        HStack {
                            Text(num)
                            if selectedStoreNumber == num {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selectedStoreNumber.isEmpty ? "Store #" : "#\(selectedStoreNumber)")
                        .fontWeight(selectedStoreNumber.isEmpty ? .regular : .medium)
                        .foregroundStyle(selectedStoreNumber.isEmpty ? .secondary : .primary)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .disabled(selectedStore.isEmpty || availableNumbers.isEmpty || !store.items.isEmpty)
            .opacity((selectedStore.isEmpty || !store.items.isEmpty) ? 0.5 : 1.0)

            Spacer()
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
        List(selection: $selectedItems) {
            ForEach(store.items) { item in
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
                Button("Clear") { store.clear() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Submit") {
                    showSubmitConfirm = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.items.isEmpty)
            }
        }
        .padding()
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
        let allowedStores = storeService.distinctStoreNames(in: "")
        if !allowedStores.contains(selectedStore) {
            selectedStore = ""
            selectedStoreNumber = ""
            return
        }
        let allowedNumbers = storeService.storeNumbers(for: selectedStore, in: "")
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

        // Propagate the current store number to the session store so
        // that when the AM submits, the session record carries the
        // correct store number for audit.
        store.currentStoreNumber = selectedStoreNumber

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
            AudioService.shared.playNotFound()
            missingUPC = upc
            let storesList = availableAt.joined(separator: ", ")
            let reason = availableAt.count == 1
                ? "Not in this store — available at \(storesList)"
                : "Not in this store — available at: \(storesList)"
            if showCamera {
                cameraNotFoundUPC = upc
                cameraNotFoundReason = reason
            } else {
                lastScanErrorMessage = reason
            }
            return .notFound

        case .notInCatalog:
            AudioService.shared.playNotFound()
            missingUPC = upc
            if showCamera {
                cameraNotFoundUPC = upc
                cameraNotFoundReason = "Not in catalog"
            } else {
                showManualOverride = true
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
        let catalog = CatalogService(context: context)
        let lastSync = catalog.lastSyncedAt()
        do {
            try store.submit(into: context, catalogSyncedAt: lastSync)
            showSubmitConfirm = false
        } catch {
            print("Submit failed: \(error)")
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

struct ManualPriceSheet: View {
    let upc: String
    let onSave: (ManualOverride) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var priceText: String = ""
    @State private var note: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("UPC") {
                    Text(upc).monospaced()
                }
                Section {
                    Text("This item will be flagged as a manual override in the audit log.")
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
            .navigationTitle("UPC not found")
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
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Submit backstock?")
                    .font(.title3).fontWeight(.medium)
                VStack(spacing: 4) {
                    Text(formatCurrency(subtotal))
                        .font(.system(size: 34, weight: .medium))
                    Text("\(itemCount) item\(itemCount == 1 ? "" : "s") at \(store) #\(storeNumber)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("This will record the session to the audit log and clear the scan list.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Confirm and submit") {
                    onConfirm()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
            .padding()
            .navigationTitle("Submit")
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

struct HistoryView: View {
    @Query(sort: \ScanSession.startedAt, order: .reverse) private var sessions: [ScanSession]
    // All stores are loaded once here and passed down as a lookup map
    // keyed by storeNumber. Avoids each HistoryRow issuing its own query.
    @Query private var stores: [Store]

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

    var body: some View {
        NavigationStack {
            List(sessions) { session in
                NavigationLink(value: session.id) {
                    HistoryRow(session: session, storeShortNames: shortNames)
                }
            }
            .navigationTitle("History")
            .navigationDestination(for: UUID.self) { id in
                SessionDetailView(sessionID: id)
            }
        }
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
    private var itemsSummary: String {
        let lines = session.items.count
        let units = session.items.reduce(0) { $0 + $1.quantity }
        let base = lines == units
            ? "\(lines) items"
            : "\(lines) items · \(units) units"
        guard let storeNumber = session.storeNumber, !storeNumber.isEmpty else {
            return base
        }
        let label = storeShortNames[storeNumber].map { "\($0) #\(storeNumber)" }
            ?? "Store #\(storeNumber)"
        return "\(base) · \(label)"
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
        case .priceHigh:  return filtered.sorted { $0.price > $1.price }
        case .priceLow:   return filtered.sorted { $0.price < $1.price }
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

            // Commodity search field
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "tag")
                        .foregroundStyle(.secondary)
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
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 8)
            }

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
        for (idx, item) in sorted.enumerated() {
            func esc(_ s: String) -> String { "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            lines.append([
                "\(idx + 1)",
                esc(item.name),
                item.upc,
                "\(item.quantity)",
                "\(item.price)",
                "\(item.lineTotal)",
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

    var body: some View {
        NavigationStack {
            Form {
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
                Section("Source") {
                    LabeledContent("Type", value: "Google Drive")
                    LabeledContent("Access", value: "Anyone with link")
                }
            }
            .navigationTitle("Settings")
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
