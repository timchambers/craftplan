# Bottle order-report importer

Stage 1 — `extract.py`: turns a Bottle XLSX export into 4 CSVs under `runs/<ts>/`.
Stage 2 — `mix bottle.import <run_dir>`: sends GraphQL mutations to a deployed Craftplan instance to ingest the CSVs as Customers, Products, Orders, and OrderItems.

The target instance is selected by `CRAFTPLAN_API_URL` — required, no default. This import runs against production (`https://plan.breadparavion.com`); the task raises if `CRAFTPLAN_API_URL`/`CRAFTPLAN_API_KEY` are unset, so it never silently writes to local dev.

See `.claude/skills/bottle-import/SKILL.md` for the full agent-facing workflow, including prerequisites, troubleshooting, and idempotency notes.

## Prerequisites

**Deploy-first:** The Order/Product GraphQL exposure PR must be merged and deployed to the target instance before running the importer against it.

**API key scopes:** `CRAFTPLAN_API_KEY` must grant create+read on `products` and `customers`, create+read+update on `orders`, and create on `order_items`.

## Quickstart

    python3 -m venv .venv && source .venv/bin/activate
    pip install pandas openpyxl
    python extract.py /path/to/bottle.xlsx --from 2026-01-01 --to 2026-06-20
    # prints: priv/imports/bottle/runs/20260622T140000Z

    export CRAFTPLAN_API_URL=https://plan.breadparavion.com
    export CRAFTPLAN_API_KEY=cpk_...

    # Preview (aborts if unknown PIDs found):
    mix bottle.import priv/imports/bottle/runs/20260622T140000Z

    # Run (optionally add --concurrency N; default 8):
    mix bottle.import priv/imports/bottle/runs/20260622T140000Z --yes
