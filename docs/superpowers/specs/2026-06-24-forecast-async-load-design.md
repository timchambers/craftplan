# Reorder Planner Async Metrics Load — Design

**Date:** 2026-06-24
**Status:** Approved (design)
**Scope:** `CraftplanWeb.InventoryLive.ReorderPlanner` (`lib/craftplan_web/live/manage/inventory_live/reorder.ex`) only.

## Problem

`/manage/inventory/forecast/reorder` mounts in ~2s (prod: `Sent 200 in 2057ms`) and exhibits the same longpoll/reload loop the orders page had. Root cause: `mount/3` calls `load_metrics/1` **synchronously**, which runs the ~2s `InventoryForecasting.owner_grid_rows/3` computation before returning. Because LiveView mounts twice (disconnected HTTP render + connected WebSocket render), this runs twice, and the slow connected mount blocks the WebSocket join → timeout → re-mount → loop.

The CPU cost of `owner_grid_rows/3` is **not** changed here (a deferred, measure-first follow-up). This change only moves the work **off the synchronous mount** so the page is interactive immediately.

The UI already supports this: `metrics_band` renders a loading state (`loading?={!@metrics_loaded?}`, "Loading inventory metrics…") that is currently never shown because mount blocks until metrics are ready.

## Design

Phoenix LiveView 1.1 → use `start_async/3` + `handle_async/3` + `cancel_async/2`.

1. **`mount/3`** sets `metrics_loaded?: false` and returns immediately. It kicks off the async compute **only when `connected?(socket)`** — the disconnected HTTP render shows the spinner and does no computation (today it computes on *both* mounts).
2. **`start_metrics_load/1`** (replaces synchronous `load_metrics/1`): computes `days_range` + `opts`, assigns `metrics_loaded?: false`, cancels any in-flight `:forecast_metrics` async, then `start_async(:forecast_metrics, fn -> owner_grid_rows(days_range, opts, actor) end)`.
3. **`handle_async(:forecast_metrics, {:ok, rows}, socket)`** assigns `forecast_rows: rows`, `metrics_loaded?: true`, `forecast_error: nil`. The **`{:exit, reason}`** clause logs and sets `forecast_error` (replacing the old `rescue` in `load_metrics`).
4. **Control toggles** (`set_service_level`, `set_horizon`, `update_advanced`, `reset_advanced`) recompute via `start_metrics_load/1` instead of synchronous `load_metrics/1` — today each click freezes the LiveView for ~2s. `cancel_async` makes rapid toggling safe (last request wins).
5. **No UI changes** — the existing loading state finally gets used.

### Behavior

- Mount: instant. Spinner shown. WebSocket join succeeds → no reload loop. Metrics appear ~2s later.
- Toggles: instant spinner, background recompute, no freeze.
- Error in compute: `forecast_error` shown, spinner cleared (`metrics_loaded?` stays false → existing error path), same as before.
- The `horizon <= 0` guard (no-op) is preserved.

## Testing

New `test/craftplan_web/manage_inventory_reorder_live_test.exs`:

1. **Async mount:** `live/2` returns HTML containing "Loading inventory metrics…"; after `render_async/1`, the loading text is gone and the metrics band (or its empty state "No forecast rows available") renders. Proves mount does not block on the computation.
2. **Toggle is async:** after initial `render_async`, clicking a horizon button returns HTML with the spinner (proves the handler doesn't block), then `render_async` resolves to the updated band.

**Known test risk:** `start_async` runs the compute in a task spawned by the LiveView process. The Ecto/Ash sandbox connection must be reachable from that task. With `ConnCase`'s caller-tracking sandbox (`$callers`), the spawned task inherits access and `render_async/1` awaits it. If sandbox access fails in test, fallback is `Ecto.Adapters.SQL.Sandbox.mode(Craftplan.Repo, {:shared, self()})` in that test (and `async: false` for the module). The plan calls this out so the implementer verifies it during RED/GREEN.

## Out of scope

- Optimizing the ~2s `owner_grid_rows/3` computation (the 42-day lookback recompute, per-day nested filtering, occasional BOM N+1). Separate, measure-first follow-up.
- The other forecast consumers (`overview_live.ex`, `inventory_live/index.ex`) — they call `prepare_materials_requirements` but were not reported slow; not touched.
