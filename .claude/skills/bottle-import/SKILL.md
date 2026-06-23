---
name: bottle-import
description: Import a Bottle order-report XLSX (orders from the breadparavion.com e-commerce platform) into Craftplan as Customers, Products, Orders, and OrderItems. Triggers on phrases like "import this Bottle order report", "import Bottle orders", "load Bottle XLSX", or when the user @-references an XLSX whose filename contains "Bottles" or whose first 'Orders for ...' sheet matches the Bottle export shape. Idempotent — safe to re-run.
---

# Bottle order-report → Craftplan importer

This skill ingests a Bottle XLSX into Craftplan in two stages: a Python extractor produces 4 inspectable CSVs, then a Mix task sends GraphQL mutations to a deployed Craftplan instance via its API, with a preview gate and an audit log. Craftplan is the source of truth for `Product` data; `price_map.yml` is only consulted for unknown PIDs during the bootstrap.

## Inputs

- `xlsx_path` — absolute path to a Bottle XLSX export.
- `date_from` — `YYYY-MM-DD` start of the fulfillment window.
- `date_to` — `YYYY-MM-DD` end of the fulfillment window.

## Prerequisites

- **Elixir version**: This project pins Elixir 1.18.3. Verify your local version matches, or run `mise install` (if using mise) before running `mix` commands.

- **Deploy-first ordering (CRITICAL):** The Order/Product GraphQL field-exposure PR (the one that makes `Product.sku` and Order `invoice_number`/`payment_status`/`paid_at` public/filterable, allows setting paid via `updateOrder`, registers the payment-status enum, and adds the granular `update` API scope) **MUST be merged and deployed to the target Craftplan instance before running the importer against it.** Running against an instance that lacks these changes will fail — those fields and mutations are absent from the schema.

- **API key scopes (CRITICAL):** The `CRAFTPLAN_API_KEY` must grant:
  - `create` + `read` on **products**
  - `create` + `read` on **customers**
  - `create` + `read` + `update` on **orders**
  - `create` on **order_items**

  The `order_items` scope is required because `createOrder` creates line items via a managed relationship that is authorized separately — without it, every order creation fails with a forbidden error.

- **Environment variables:**
  - `CRAFTPLAN_API_URL` — the target instance base URL. Defaults to `http://localhost:4000` for local dev. For production: `https://plan.breadparavion.com`.
  - `CRAFTPLAN_API_KEY` — a `cpk_…` bearer token with the scopes above.

## Procedure

Follow in order. Do not skip the gates.

### 1. Stage 1 — extract

```bash
cd /Users/timchambers/Sites/craftplan/priv/imports/bottle
# Python venv with pandas + openpyxl
source .venv/bin/activate
python extract.py "<xlsx_path>" --from <date_from> --to <date_to>
```

The script prints the run-directory path on its last stdout line. Capture it.

### 2. Verify the extract

```bash
wc -l <run_dir>/*.csv
```

Confirm row counts look sensible. If `orders.csv` has zero rows in the window, halt — usually means the wrong date range.

### 3. Set env vars

```bash
export CRAFTPLAN_API_URL=https://plan.breadparavion.com   # or http://localhost:4000 for dev
export CRAFTPLAN_API_KEY=cpk_...
```

### 4. Preview gate

```bash
mix bottle.import <run_dir>
```

The task checks all PIDs in `order_items.csv` against the API (`listProducts`) and `price_map.yml`. It resolves products and lists any **unknown PIDs**. Inspect the preview for:
- **Unknown PIDs** — if any, the task aborts (exit code 2) with a list. Either (a) create those Products in Craftplan via Manage → Products, then re-run; or (b) add the PID + price to `priv/imports/bottle/price_map.yml`.

If no unknown PIDs, the task prompts `Proceed? [Yn]`. Type `y` to proceed, anything else to abort.

### 5. Run the import

```bash
mix bottle.import <run_dir> --yes
```

Use `--concurrency N` to override the default parallelism of 8 async order-write tasks (e.g. `--concurrency 4` on a slow connection).

### 6. Spot-check in the deployed UI

Open the Craftplan instance at `CRAFTPLAN_API_URL`, navigate to Manage → Orders, filter to the imported date range, and confirm:
- A handful of order references exist with the expected `BOTTLE-<id>` invoice numbers.
- Customer detail pages show the imported shipping addresses.
- Product list shows the new SKUs with `BOTTLE-PID-` prefix.

### 7. Audit log

Each run appends a line to `priv/imports/bottle/bottle_import_log.jsonl`. Check the latest entry:

```bash
tail -1 priv/imports/bottle/bottle_import_log.jsonl | jq
```

The summary and audit log report `inserted_orders`, `skipped_orders`, `restamped_orders`, and `failed_orders`. A first run shows ~0 skips; a clean re-run shows everything skipped (idempotency). Confirm `inserted_orders + skipped_orders + restamped_orders == total orders in window`, `failed_orders == 0`, and `api_url` shows the expected target. (`restamped_orders` is normally 0 except after a partial-failure recovery re-run where some orders were imported but not yet marked paid.)

## Idempotency

Re-running the importer against the same run directory is safe:
- Orders already imported (deduped by `BOTTLE-<id>` invoice number via the API) are skipped.
- An already-imported order that is not yet marked paid will be re-stamped paid if the Bottle row shows a paid status.

## Bootstrap (one-time, first import only)

Before the very first run, populate `priv/imports/bottle/price_map.yml` with retail prices for every PID that appears in the Bottle file but does not yet exist in Craftplan. Format:

```yaml
prices:
  "PID-47420": "10.00"
  "PID-47421": "8.50"
  # ...
```

After the bootstrap, the file should mostly empty out — new SKUs should be created in Craftplan first.

## Out of scope

- **Kit explosion.** `Combo Box (2 of each)` and Galentine's variants import as opaque products with `selling_availability: :off`. Modeling kit decomposition is a separate change.
- **Gift cards.** Dropped at extract time.
- **Resale-supplier POs.** Coffees and honeys here are sales records; their wholesale POs are a separate import.
- **Multi-year backfill.** Supported by this skill's idempotency, but the operational playbook (year-by-year, with checkpoints) is documented separately.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `unknown_pids` is non-empty (exit code 2) | Bottle has a SKU not in Craftplan and not in `price_map.yml` | Create the product in Craftplan (Manage → Products) or add the PID + price to `price_map.yml`; re-run |
| `{:error, {:mutation, …}}` / GraphQL `forbidden` on order creation | API key is missing a required scope, most likely `order_items` create | Regenerate the API key with all four scopes: `products` (create+read), `customers` (create+read), `orders` (create+read+update), `order_items` (create) |
| GraphQL `forbidden` on field access (`sku`, `invoiceNumber`, `paymentStatus`, etc.) | Order/Product GraphQL exposure PR not deployed to target instance | Merge and deploy that PR first, then retry |
| HTTP 401 or connection refused | Wrong `CRAFTPLAN_API_URL` or `CRAFTPLAN_API_KEY` | Verify both env vars are set and point to the correct deployed instance |
| `failed_orders` non-zero in audit log | Network timeout or transient API error | Re-run with `--yes` — already-imported orders will be skipped; only failures are retried |
