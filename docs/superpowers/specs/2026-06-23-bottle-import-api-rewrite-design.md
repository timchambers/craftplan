# Bottle importer — GraphQL/API rewrite — Design

**Status:** Draft for review
**Date:** 2026-06-23
**Author/Driver:** Tim Chambers (with Claude)
**Supersedes (Stage 2 only):** [2026-06-22-bottle-import-design.md](2026-06-22-bottle-import-design.md)

## 1. Problem

The Bottle importer's Stage 2 (`mix bottle.import`) writes directly to a `Repo` via Ash actions. That couples it to whatever database the Mix process is configured for — on a developer laptop, always `craftplan_dev`. As a result, the first real import landed 4,305 orders in **dev**, and there is no clean path to get them into **production**, which runs as a Docker-Compose deployment on a separate machine:

- The prod container runs an OTP release — no Mix task to invoke.
- The run-directory CSVs are gitignored — never built into the image.
- Writing to the prod Postgres directly would tunnel past the API layer — fragile and off-convention.

The IGF importer already solves the equivalent problem by writing over HTTP via GraphQL to `CRAFTPLAN_API_URL` (e.g. `https://plan.breadparavion.com`) authenticated with a `cpk_…` bearer token. The same instance-agnostic approach should drive the Bottle importer.

## 2. Goals

1. Stage 2 writes to Craftplan over the GraphQL API, targeting any instance via `CRAFTPLAN_API_URL` (localhost for dev, prod URL for prod).
2. Preserve all existing parsing/normalization behavior (name, phone, slot-time, email-conflict, address, category→availability, delivery-method, paid stamping).
3. Idempotent and resumable: re-running skips already-imported orders.
4. Efficient enough for ~4,300 orders against a single prod box (minutes, not tens of minutes).
5. Keep the operator-facing shell: preview gate, `--yes`, audit log.

## 3. Non-goals (unchanged from prior spec)

Kit explosion, gift cards, resale-supplier POs, and the multi-year backfill operational playbook remain out of scope.

## 4. Key decisions (resolved during brainstorming)

| # | Decision | Choice |
|---|---|---|
| 1 | Paid stamping (`payment_status`/`paid_at` aren't settable over GraphQL today) | Add both to Order's `:update` accept list + make public; importer does `create_order` → `update_order`. |
| 2 | Relationship to the existing direct-to-DB path | **Replace** with a single API path; target chosen by `CRAFTPLAN_API_URL`. Remove the Ash/Repo write path. |
| 3 | Order-write loop strategy | **Scale-optimized**: batched idempotency, resolve-first in-memory maps, bounded concurrency, resumable. |
| 4 | Idempotency mechanism | Make `invoice_number` **public + filterable**; page `listOrders(filter: {invoiceNumber: {like: "BOTTLE-%"}})` once into a skip-set. No migration. |

## 5. Background: why the API isn't import-ready today

AshGraphql only exposes **public** accepted attributes as mutation inputs, and only returns/filters **public** attributes on a type. Customer and Product mark their attributes `public? true`; **Order marks none**. Consequences for an API-based importer:

- `create_order`/`update_order` inputs won't carry the fields the importer must set (`status`, `customer_id`, `delivery_date`, `invoice_number`, `payment_method`, `delivery_method`) until those attributes are public.
- `payment_status` and `paid_at` are in **no** writable action's accept list — the dev task set them via `force_change_attribute`, an in-process Ash escape hatch with no GraphQL equivalent.
- `listOrders` cannot return or filter by `invoiceNumber` (not public), so neither read-back idempotency nor (absent a unique identity on `invoice_number`) constraint-based dedupe works.

Therefore the rewrite has a **server-side prerequisite** (Section 7) that must deploy to the target before the importer can run against it.

## 6. Architecture & data flow

### 6.1 Pipeline

1. **Stage 1 — `extract.py`** — unchanged. Produces `products.csv`, `customers.csv`, `orders.csv`, `order_items.csv`.
2. **Preview** — load CSVs + `price_map.yml`. Detect unknown PIDs via `listProducts(filter: {sku: {eq: "BOTTLE-<pid>"}})` ∪ price-map keys. Abort with the list if any unknown (unchanged gate semantics). Print counts; `--yes` or interactive confirm.
3. **Resolve products once** — for each `products.csv` row: look up by SKU; create if missing (kit → `selling_availability: :off`, else `:available`). Build `pid → {id, price}` map.
4. **Resolve customers once** — for each `customers.csv` row (already deduped by the extractor): normalize phone, parse name, resolve email conflict, build address; look up by phone, create or update. Build `phone → id` map.
5. **Batch idempotency** — page `listOrders(filter: {invoiceNumber: {like: "BOTTLE-%"}})`, reading `invoiceNumber` + `paymentStatus`; build `already_imported` set and `unpaid_existing` set.
6. **Write orders** — bounded-concurrency pool (default 8, configurable via `--concurrency`). Per order:
   - In `already_imported` and paid → skip.
   - In `already_imported` but unpaid → `update_order` to stamp paid only (re-stamp recovery).
   - Not present → `create_order` with nested `items` (JsonString array, same mechanism as IGF `lot_receipts`) → `update_order` stamping `payment_status: :paid` + `paid_at`.
7. **Audit + summary** — append one JSONL line (existing shape + `api_url`); print the summary block.

### 6.2 In-memory resolution rationale

Today's task re-upserts the customer on every one of 4,305 orders and re-resolves products per item. Over HTTP that is ~17k calls. Resolving products (65) and customers (609) once up front and reading the idempotency set in one paged query reduces the run to ~9k calls (≈ customers + products + 2×orders), completing in ~2–3 min with concurrency, and makes resumption a set-membership check.

### 6.3 Modules

- **New `Craftplan.BottleImport.ApiClient`** — thin `Req` wrapper. `query(document, variables)` POSTs to `#{CRAFTPLAN_API_URL}/api/graphql` with `Authorization: Bearer #{CRAFTPLAN_API_KEY}`, returns `{:ok, data}` | `{:error, reason}` (GraphQL `errors` array surfaced as `{:error, ...}`). Houses all GraphQL documents. `Req` is already a `:dev`/`:test` dep; the importer runs locally as a client, so no prod dependency change.
- **Rewritten `Craftplan.BottleImport.Upserts`** — same public functions and signatures (`resolve_product/5`, `upsert_customer/2`, `upsert_order/4`), internals call `ApiClient` instead of `Ash`. Returns `{:ok, ...}` | `{:skip, :already_imported}` | `{:error, reason}` as before.
- **Untouched:** `NameParser`, `PhoneNormalizer`, `SlotTimeParser` (pure functions).
- **`Mix.Tasks.Bottle.Import`** — keeps CLI/preview/`--yes`/audit shell; drops `staff_actor!` and Ash queries; adds resolution maps, the skip-set, and the concurrency pool. New flags: `--concurrency N` (default 8). Auth via env, not an in-process actor.

## 7. Server-side prerequisite — Order resource change (separate PR)

Make the import-relevant Order GraphQL surface usable:

- Mark `public? true`: `invoice_number`, `status`, `delivery_date`, `payment_method`, `delivery_method`, `payment_status`, `paid_at` (and confirm the customer relationship input is exposed).
- Add `payment_status` and `paid_at` to the `:update` action's `accept` list.
- Ensure `listOrders` supports filtering on `invoice_number` (generic filter input on the public attribute, mirroring IGF's `listPurchaseOrders(filter: {reference})`).

**Verification during implementation:** introspect the generated schema for `create_order`/`update_order`/`listOrders` and confirm the exact exposed field set; adjust `public?`/`accept` until the importer's documents type-check. No data migration (idempotency is read-based, not constraint-based).

This PR is independently testable and deployable, and is the prerequisite for the importer to work against any target.

## 8. Error handling & resumability

- **Continue-on-failure**: collect `{bottle_id, reason}`, never abort the whole run on one bad order; report failures at the end. Matches today's behavior and IGF's backfill philosophy.
- **No partial orders**: items are nested in the single `create_order` mutation, so a failed create writes nothing.
- **Partial paid-stamp**: a `create_order` that succeeds but whose follow-up `update_order` fails leaves an unpaid order. The Section 6.1 step-5 `unpaid_existing` set makes re-runs re-stamp these rather than skip them.
- **Transport**: `ApiClient` treats non-2xx and GraphQL `errors` as `{:error, reason}`; the per-order reducer records and continues. (Retry/backoff: out of scope for v1; a failed order is simply re-attempted on the next run.)

## 9. Testing

- Parser tests (`NameParser`/`PhoneNormalizer`/`SlotTimeParser`): unchanged.
- `ApiClient`: unit-tested with `Req.Test` stub — asserts endpoint, auth header, document/variables, and `{:ok,_}`/`{:error,_}` mapping.
- `Upserts`: unit-tested against a stubbed `ApiClient` — asserts the resolve/lookup/create/update decisions and preserved parsing behavior (email-conflict, kit availability, paid stamping).
- Orchestration: a stubbed-API test over `test/support/bottle_fixtures` asserting resolve-first ordering, skip-set behavior, and `create → update` sequencing, including the unpaid-re-stamp path.
- Optional live smoke test gated on an env var (`BOTTLE_IMPORT_LIVE_TEST`).

## 10. Configuration & operations

- `CRAFTPLAN_API_URL` — default `http://localhost:4000`.
- `CRAFTPLAN_API_KEY` — `cpk_…` token with write scopes for products, customers, orders, order_items (verify against `ApiScopeCheck`).
- Dev imports now require the dev server running and a dev API key.
- `SKILL.md` rewritten to document the API flow, env vars, and the deploy-first ordering (resource PR → deploy → import).

## 11. Delivery plan

Per the one-PR-per-concern norm, and **targeting the fork `origin` (`timchambers/craftplan`) — never `upstream`**:

- **PR 1 — Order GraphQL exposure** (Section 7). Deploy to the target instance before importing.
- **PR 2 — Stage-2 API rewrite** (Sections 6, 8–10). Depends on PR 1 being deployed.

The 4,305 orders already in dev are harmless; once PR 1 is deployed to prod and PR 2 lands, run the importer with `CRAFTPLAN_API_URL` pointed at prod to populate it.

## 12. Open items to confirm in the implementation plan

1. Exact `public?`/`accept` set required for `create_order`/`update_order`/`listOrders` (Section 7 verification).
2. The precise AshGraphql filter syntax for `invoice_number` (`{like:}` vs `{eq:}` per page).
3. Whether the customer relationship is set via a `customer_id` input or a relationship input on `create_order`.
