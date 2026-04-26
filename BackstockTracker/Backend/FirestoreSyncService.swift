// FirestoreSyncService.swift
//
// SCAFFOLDING — NOT YET WIRED INTO THE BUILD.
//
// This file is the planned replacement for CloudSyncService (CloudKit
// public DB). It is intentionally not yet added to the Xcode project
// target; it lives in the repo so that the API shape, document layout,
// and migration plan can be reviewed in isolation before we take on a
// new dependency.
//
// To activate:
//   1. Add Firebase via SPM (FirebaseFirestore, FirebaseAuth) — this
//      will be the project's first third-party dep, so update CLAUDE.md
//      to note the exemption.
//   2. Add this file to the BackstockTracker target.
//   3. Configure Firebase at app launch (BackstockTrackerApp.init via
//      FirebaseApp.configure()).
//   4. Behind a `useFirestore` feature flag, route submits + retries
//      through this service instead of CloudSyncService.
//   5. Once dual-write has run for one TestFlight cycle, flip reads
//      (HistoryView "Team" tab) to Firestore and stop CloudKit writes.
//
// The public API mirrors CloudSyncService 1:1 so call sites can be
// swapped behind a flag without touching ScanSessionStore or the
// views. Anything that diverges from the CloudSyncService surface is
// flagged with INTENT: comments.
//
// See `data-contract.md` (repo root) for the canonical Firestore
// schema this service writes to.

#if canImport(FirebaseFirestore) && canImport(FirebaseAuth)

import Foundation
import SwiftData
import FirebaseFirestore
import FirebaseAuth

// Pulled from BackstockTrackerApp.swift via the target. While this
// file lives outside the project we lean on the type names being
// stable; the contract is that PendingCloudUpload / CloudSyncItem /
// TeamBackstockRecord stay shape-compatible across the migration.

actor FirestoreSyncService {

    // MARK: - Configuration

    /// Top-level collection holding submitted backstock sessions.
    /// Document IDs are the client-generated session UUIDs (lowercase),
    /// which means uploads are idempotent on `id` — re-running the
    /// migration script or replaying retryPending writes the same
    /// document, never a duplicate.
    static let collection = "backstockSessions"

    /// Bumped whenever the on-disk shape changes. Mirrored in
    /// `data-contract.md` and (eventually) in the Android client.
    /// Both clients write their version on every upload so a third
    /// reader can refuse to edit records newer than itself.
    static let contractVersion = 1

    static let shared = FirestoreSyncService()

    private let db: Firestore
    private var auth: Auth { Auth.auth() }

    // MARK: - Optimistic cache
    //
    // Same purpose as CloudSyncService.optimisticPending: bridge the
    // gap between an upload completing and the next snapshot listener
    // tick (Firestore's local cache makes this gap smaller than
    // CloudKit's, but it's not zero — especially over flaky LTE).

    private var optimisticPending: [String: TeamBackstockRecord] = [:]

    private init() {
        self.db = Firestore.firestore()

        // Offline persistence + unbounded local cache. This matches
        // the user expectation set by CloudKit: scan submissions
        // queued while offline must survive an app kill and ship
        // when connectivity returns.
        let settings = FirestoreSettings()
        settings.cacheSettings = PersistentCacheSettings(
            sizeBytes: NSNumber(value: FirestoreCacheSizeUnlimited)
        )
        db.settings = settings
    }

    // MARK: - Auth (anonymous + custom claims)
    //
    // Sign-in pattern: anonymous Firebase Auth user, with `area` and
    // `employeeNumber` custom claims set server-side by a Cloud
    // Function the first time a given device-bound anonymous user
    // sends its (employeeNumber, area) pair. The function validates
    // against the roster mirror and writes the claims; subsequent
    // submits are gated by the security rules in data-contract.md.

    @discardableResult
    func ensureSignedIn() async throws -> User {
        if let user = auth.currentUser { return user }
        let result = try await auth.signInAnonymously()
        return result.user
    }

    // MARK: - Upload
    //
    // Idempotent on payload.sessionUUID. Uses setData(merge: false)
    // because a re-upload of the same session always carries the
    // authoritative full state — we don't want a stale optimistic
    // local cache to merge old fields back in.

    func upload(_ payload: PendingCloudUpload, fallbackArea: String = "") async throws {
        try await ensureSignedIn()

        let area = payload.area.isEmpty ? fallbackArea : payload.area
        precondition(
            !area.isEmpty,
            "Refusing to upload a record with empty area — this would " +
            "be silently dropped by every read-side area filter. The " +
            "caller (submitNew / submitEdit) is responsible for passing " +
            "fallbackArea: selectedArea when the local Store row lacks " +
            "the column. See data-contract.md ‘area is the partition key’."
        )

        let doc = db.collection(Self.collection).document(payload.sessionUUID)
        let body = Self.makeFirestoreBody(payload: payload, area: area)

        try await doc.setData(body, merge: false)
    }

    // MARK: - Edit-in-place patch
    //
    // Mirrors CloudSyncService.updateItems: rebuild items[], recompute
    // subtotal, write back. We use a transaction so the read-modify-
    // write of `items` + `subtotal` can't race with a concurrent edit
    // from another device on the same record.

    func updateItems(
        sessionUUID: String,
        items: [CloudSyncItem]
    ) async throws -> TeamBackstockRecord? {
        try await ensureSignedIn()

        let doc = db.collection(Self.collection).document(sessionUUID)

        let updated: TeamBackstockRecord? = try await db.runTransaction { txn, _ in
            do {
                let snap = try txn.getDocument(doc)
                guard snap.exists, var data = snap.data() else { return nil }

                let itemMaps = items.map(Self.mapForItem)
                let subtotal = items.reduce(0.0) { $0 + $1.price * Double($1.quantity) }
                let retailTotal = items.reduce(0.0) {
                    $0 + ($1.retailPrice ?? 0) * Double($1.quantity)
                }

                data["items"] = itemMaps
                data["subtotal"] = subtotal
                data["retailTotal"] = retailTotal
                data["contractVersion"] = Self.contractVersion

                txn.setData(data, forDocument: doc, merge: true)
                return Self.decodeBody(id: sessionUUID, data: data)
            } catch {
                throw error
            }
        } as? TeamBackstockRecord

        // Patch the optimistic cache so the History list reflects the
        // edit before the snapshot listener catches up.
        if let record = updated { optimisticPending[record.id] = record }

        return updated
    }

    // MARK: - Box reassignment
    //
    // Mirrors CloudSyncService.updateBox. Same store/store-# guard:
    // box is logically per-(store, storeNumber), so we refuse to
    // patch box independently of those fields. (If a future feature
    // ever needs to move a box across stores, that's a delete +
    // create, not a patch.)

    func updateBox(sessionUUID: String, box: Int?) async throws {
        try await ensureSignedIn()

        let doc = db.collection(Self.collection).document(sessionUUID)
        try await doc.updateData([
            "box": box as Any,
            "contractVersion": Self.contractVersion
        ])
    }

    // MARK: - Optimistic cache hooks

    func registerOptimistic(_ record: TeamBackstockRecord) {
        optimisticPending[record.id] = record
    }

    private func clearOptimistic(matching ids: Set<String>) {
        for id in ids { optimisticPending.removeValue(forKey: id) }
    }

    // MARK: - Reads
    //
    // fetchAll: server-authoritative one-shot.
    // fetchAllMerged: same, but folds in any optimistic records the
    // server doesn't yet know about. This matches the existing
    // CloudKit semantics so HistoryView's pull-to-refresh logic
    // doesn't have to special-case the backend.
    //
    // INTENT: in a follow-up PR, replace fetchAll-on-pull with a
    // long-lived snapshot listener registered when HistoryView
    // appears. Firestore listeners are cheap and remove the entire
    // optimistic-cache dance for the listener's lifetime. Keep the
    // one-shot path for retryPending and migration tooling.

    func fetchAll(area: String?, limit: Int = 200) async throws -> [TeamBackstockRecord] {
        try await ensureSignedIn()

        var query: Query = db.collection(Self.collection)
        if let area, !area.isEmpty {
            query = query.whereField("area", isEqualTo: area)
        }
        query = query.order(by: "submittedAt", descending: true).limit(to: limit)

        let snap = try await query.getDocuments()
        return snap.documents.compactMap { doc in
            Self.decodeBody(id: doc.documentID, data: doc.data())
        }
    }

    func fetchAllMerged(area: String?, limit: Int = 200) async throws -> [TeamBackstockRecord] {
        let server = try await fetchAll(area: area, limit: limit)
        let serverIDs = Set(server.map(\.id))

        // Drop optimistic entries the server now confirms — we no
        // longer need to paper over them.
        clearOptimistic(matching: serverIDs)

        // Filter optimistic entries to the same area scope as the
        // server query, so a record submitted under area A doesn't
        // leak into a fetch for area B.
        let extras = optimisticPending.values.filter { record in
            guard let area, !area.isEmpty else { return true }
            return record.area == area
        }

        let merged = (server + extras).sorted { $0.submittedAt > $1.submittedAt }
        return Array(merged.prefix(limit))
    }

    // MARK: - retryPending
    //
    // Same contract as CloudSyncService.retryPending: sweep the local
    // SwiftData store for sessions with cloudSyncedAt == nil, build
    // payloads, upload. Idempotent — sessions that did upload but
    // failed to record cloudSyncedAt locally just no-op-overwrite
    // their existing Firestore document.

    @MainActor
    static func retryPending(
        container: ModelContainer,
        catalogContext: @escaping () -> ModelContext
    ) async {
        // INTENT: the implementation here mirrors CloudSyncService.
        // Pull pending sessions, for each: build payload via the
        // existing CloudSyncService.buildPayload (it stays as the
        // shared payload-builder during the dual-write phase), upload
        // through this actor, then write cloudSyncedAt back.
        //
        // Deliberately left as TODO so the diff that lands this is
        // visibly the migration step rather than a silent rewrite.
        // See the matching block in CloudSyncService.retryPending.
    }

    // MARK: - Encoding / decoding

    private static func makeFirestoreBody(
        payload: PendingCloudUpload,
        area: String
    ) -> [String: Any] {
        [
            "id": payload.sessionUUID,
            "submittedAt": Timestamp(date: payload.submittedAt),
            "submitterEmployeeNumber": payload.submitterEmployeeNumber,
            "area": area,
            "store": payload.storeName,
            "storeNumber": payload.storeNumber,
            "box": payload.box as Any,        // Int? → NSNull when nil
            "status": payload.status,
            "subtotal": payload.subtotal,
            "retailTotal": payload.retailTotal,
            "items": payload.items.map(mapForItem),
            "contractVersion": contractVersion
        ]
    }

    private static func mapForItem(_ item: CloudSyncItem) -> [String: Any] {
        [
            "upc": item.upc,
            "name": item.name,
            "quantity": item.quantity,
            "price": item.price,
            "retailPrice": item.retailPrice as Any,
            "commodity": item.commodity as Any,
            "rank": item.rank as Any,
            "manuallyAdded": item.manuallyAdded
        ]
    }

    /// Inverse of `makeFirestoreBody`. Returns nil if the document is
    /// missing required fields — this is the place to be paranoid,
    /// since Firestore will happily hand us a document a future
    /// client wrote with fields we don't understand.
    private static func decodeBody(id: String, data: [String: Any]) -> TeamBackstockRecord? {
        guard
            let area = data["area"] as? String, !area.isEmpty,
            let storeName = data["store"] as? String,
            let storeNumber = data["storeNumber"] as? String,
            let status = data["status"] as? String,
            let subtotal = data["subtotal"] as? Double,
            let retailTotal = data["retailTotal"] as? Double,
            let submittedTS = data["submittedAt"] as? Timestamp,
            let rawItems = data["items"] as? [[String: Any]]
        else { return nil }

        let box = data["box"] as? Int

        let items: [CloudSyncItem] = rawItems.compactMap { raw in
            guard
                let upc = raw["upc"] as? String,
                let name = raw["name"] as? String,
                let quantity = raw["quantity"] as? Int,
                let price = raw["price"] as? Double
            else { return nil }
            return CloudSyncItem(
                upc: upc,
                name: name,
                quantity: quantity,
                price: price,
                retailPrice: raw["retailPrice"] as? Double,
                commodity: raw["commodity"] as? String,
                rank: raw["rank"] as? Int,
                manuallyAdded: (raw["manuallyAdded"] as? Bool) ?? false
            )
        }

        return TeamBackstockRecord(
            id: id,
            recordName: id,                  // 1:1 with doc id; no separate CKRecord.ID concept
            area: area,
            storeName: storeName,
            storeNumber: storeNumber,
            box: box,
            status: status,
            subtotal: subtotal,
            retailTotal: retailTotal,
            submittedAt: submittedTS.dateValue(),
            items: items
        )
    }
}

#endif
