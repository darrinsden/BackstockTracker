# Backstock Tracker — data contract

This document is the source of truth for the data shapes that Backstock
Tracker clients (iOS today, Android in progress) must agree on. **Any
field added, removed, or repurposed here requires bumping a contract
version and coordinating both clients.**

The intent is that someone reading this doc plus the Drive CSVs plus
the Firestore schema below has everything they need to write a third
client (web dashboard, ETL job, internal tool) without reading either
app's source.

## Versioning

`contractVersion: 1` — current.

The version number lives in three mirrored places:

- this file (the human-readable spec)
- `BackstockTrackerApp.swift` constant `dataContractVersion`
- the Android `BackstockContract` Kotlin object (forthcoming)

Rules:

- A **breaking change** (renamed field, retyped field, removed required
  field, semantic change) increments the integer.
- A **backwards-compatible addition** (new optional field) does not.
- Clients write their `contractVersion` into every Firestore record
  they create. A reader that sees a version newer than its own may
  show the record but must not edit or re-submit it.

---

## Reference data — Google Drive CSVs

All four CSVs are hosted on Google Drive with "Anyone with link can
view" sharing. Both clients fetch the `uc?export=download&id=...`
form and parse identically. Refresh is full-replace (atomic), not
delta. Empty-cell handling: trim whitespace, then treat empty string
as "not provided" for optional fields.

UTF-8, `\n` line endings, double-quote escaping per RFC 4180.
Header row required and consumed (column order is the contract; header
text is informational).

### `area_managers.csv` &nbsp; — &nbsp; Drive id `1rOFqR8IDo4lEJmT39tHtw7JsLggOauxf`

| # | Field | Type | Required | Notes |
|---|---|---|---|---|
| 1 | `employeeNumber` | string | ✓ | Primary key, exact match |
| 2 | `firstName` | string | ✓ | |
| 3 | `lastName` | string | ✓ | |
| 4 | `territory` | string | ✓ | Broad region (e.g. "Pacific NW") |
| 5 | `area` | string | ✓ | AM's specific slice within territory |
| 6 | `email` | string | optional | |

`area` is **case-sensitive exact match** everywhere it appears in this
contract. "Seattle-North" ≠ "Seattle North" ≠ "seattle-north".

### `catalog.csv` &nbsp; — &nbsp; Drive id `1izR-bDANhkOBlOyvgB9k4gCHOUSn6x5n`

| # | Field | Type | Required | Notes |
|---|---|---|---|---|
| 1 | `upc` | string | ✓ | 12-digit UPC-A; **preserve leading zeros** |
| 2 | `name` | string | ✓ | |
| 3 | `price` | decimal | ✓ | Backstock credit price, USD, dollars |
| 4 | `commodity` | string | optional | Aisle / department label |
| 5 | `store` | string | optional | Chain name; enables per-store pricing |
| 6 | `retailPrice` | decimal | optional | Shelf price, USD, dollars |
| 7 | `rank` | int | optional | Display priority; lower = more prominent |

The composite `(upc, store)` is the logical primary key. Same UPC may
carry different prices at different chains. Clients enforce this at
sync time via full-replace.

UPC normalization — clients **must** try lookup in this order, returning
the first hit:

1. The UPC as scanned (typically 12-digit UPC-A)
2. UPC-13 with a leading zero stripped (some scanners emit 13 digits
   with a leading 0 for UPC-A codes)
3. UPC-13 without modification (true EAN-13)

Failure to follow this ladder will surface as "not in catalog" errors
on perfectly valid scans.

### `stores.csv` &nbsp; — &nbsp; Drive id `1WtggB4_n1G2avUV4q0Di4VRjG2ZdrEh3`

| # | Field | Type | Required | Notes |
|---|---|---|---|---|
| 1 | `store` | string | ✓ | Chain name (e.g. "Target", "Walmart") |
| 2 | `storeNumber` | string | ✓ | Per-chain identifier; treat as opaque string |
| 3 | `area` | string | optional¹ | AM's area; used for picker filtering |
| 4 | `shortName` | string | optional | Display label for tight UI surfaces |

¹ When the `area` column is absent or empty, clients **must fail open**
(show all stores). When present, clients **must filter** the store
picker to the signed-in AM's `area`. If the AM switches identity,
any stale store selection that no longer matches the new AM's area
must be cleared.

### `territory_managers.csv` &nbsp; — &nbsp; Drive id `1eJ7rQLkO9uCwATuPfPCxvSX-jIRnggss`

| # | Field | Type | Required |
|---|---|---|---|
| 1 | `territory` | string | ✓ |
| 2 | `email` | string | ✓ |

Used by the over-limit submit flow to pre-fill the approval mail
recipient. Lookup is by the signed-in AM's `territory`.

---

## Submitted sessions — Firestore

Collection: `backstockSessions`
Document ID: client-generated UUIDv4 (lowercase, hyphenated, no braces)

```jsonc
{
  "id": "550e8400-e29b-41d4-a716-446655440000", // matches doc id
  "submittedAt": Timestamp,
  "submitterEmployeeNumber": "12345",
  "area": "Seattle-North",   // gate field; team-feed queries filter on this
  "store": "Target",
  "storeNumber": "1842",
  "box": 3,                   // 1..10; null for legacy "unboxed" records
  "status": "submitted",      // "submitted" | "overLimit"
  "subtotal": 47.83,          // sum of items[].price * items[].quantity
  "items": [
    {
      "upc": "012345678905",
      "name": "Synthetic Lubricant 5W-30",
      "quantity": 2,
      "price": 12.99,
      "retailPrice": 18.99,   // null if unknown
      "commodity": "AUTO",    // null if unknown
      "rank": 47,             // null if unknown
      "manuallyAdded": false
    }
  ],
  "contractVersion": 1
}
```

### Field semantics

- `submitterEmployeeNumber` is logged for audit but **never displayed**
  to other AMs. Anonymity in the team feed is a product requirement,
  not just a UI default — readers must not surface this field.
- `area` is the partition key for everything. Empty area = the record
  is invisible to the team feed. Both clients must refuse to upload
  records with an empty area.
- `box` is per-store-number. "Box 3 at Target #1842" is a different
  physical box from "Box 3 at Walmart #221". Editors must enforce this
  on save (no cross-store box reassignment).
- `subtotal` is denormalized for cheap list rendering. It MUST equal
  the sum of `items[].price * items[].quantity` to within ±$0.01;
  consumers may treat any larger discrepancy as a corrupt record.
- `status` of `overLimit` means the session crossed the $149.99 hard
  limit and was approved out of band via mail to the territory manager.
  These records are persisted but should be visually distinguished
  from normal submissions.

### Indexes

| Index | Backs |
|---|---|
| `area ASC, submittedAt DESC` | Team feed listener |
| `area ASC, store ASC, storeNumber ASC, box ASC, submittedAt DESC` | Per-box history view |
| `area ASC, status ASC, submittedAt DESC` | Status filter chips (planned) |

### Security rules (sketch)

```
match /backstockSessions/{id} {
  // Reads: caller must be authenticated and have a matching area claim.
  allow read: if request.auth != null
              && request.auth.token.area == resource.data.area;

  // Writes: caller's claims must match the new record's area and
  // submitter. contractVersion must be present.
  allow create: if request.auth != null
                && request.resource.data.area == request.auth.token.area
                && request.resource.data.submitterEmployeeNumber
                   == request.auth.token.employeeNumber
                && request.resource.data.contractVersion is int;

  // Updates: same constraints as create, plus the area / submitter /
  // contractVersion are immutable.
  allow update: if request.auth != null
                && request.resource.data.area == resource.data.area
                && request.resource.data.submitterEmployeeNumber
                   == resource.data.submitterEmployeeNumber
                && request.resource.data.contractVersion
                   == resource.data.contractVersion;

  // Deletes: not allowed from clients. Empty-box cleanup goes through
  // a callable Cloud Function with audit logging.
  allow delete: if false;
}
```

### Authentication

Anonymous Firebase Auth. Custom claims `area` and `employeeNumber` are
set by a Cloud Function on first sign-in, validated against
`area_managers.csv` (mirrored into Firestore as `roster/{employeeNumber}`
on each catalog sync). When the roster changes — AM moved areas, AM
removed — the function must rotate the affected claims at next sign-in.

The roster is the source of truth for which `(employeeNumber, area)`
pairs are valid. A client whose claims don't match any roster row
must be denied writes.

---

## Migration from CloudKit

The legacy iOS-only path uses CloudKit record type `BackstockSession`
in `iCloud.com.jacent.BackstockTracker.publicCloudDatabase`. Field
mapping is 1:1 with the Firestore shape above except:

| CloudKit | Firestore | Transform |
|---|---|---|
| `submittedAt` (Date) | `submittedAt` (Timestamp) | direct |
| `items` (String, JSON) | `items` (array of maps) | JSON decode → native |
| `box` (Int64?) | `box` (int \| null) | direct |
| _no `contractVersion`_ | `contractVersion` (int) | backfill as `1` |
| _no `submitterEmployeeNumber`_ | `submitterEmployeeNumber` | backfill from local cache; for records with no cached submitter, use the literal string `"unknown"` and exclude from analytics |

**Cutover plan:**

1. Land Firestore client on iOS behind a feature flag (`useFirestore`).
2. Dual-write for one TestFlight cycle: every submit goes to both
   CloudKit and Firestore. Reads still come from CloudKit.
3. One-shot migration script (`scripts/cloudkit-to-firestore.swift`,
   forthcoming): page through all CloudKit records, write to Firestore
   if not already present (idempotent on `id`).
4. Flip the read path to Firestore. Keep dual-writing for one more
   cycle.
5. Drop CloudKit writes. Schedule the CloudKit container for deletion
   90 days later (gives a recovery window).

Step 3 is idempotent specifically so it can be re-run if a client
fails to dual-write a record during the transition.
