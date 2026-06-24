# Orders Index Performance — Bounded Load Design

**Date:** 2026-06-23
**Status:** Approved (design)
**Scope:** `CraftplanWeb.OrderLive.Index` only. Inventory/forecast slowness is a separate concern.

## Problem

After importing a year of orders (~4,365 orders / ~7,585 items in prod), the
`/manage/orders` page became unusable:

- Initial document load measured at **11.41s**, **23.1 MB** transferred.
- LiveView fell back to **longpoll** transport and entered a **retry loop**
  (repeated ~2.1s longpoll failures), causing the page to "reload itself".

### Root cause

`CraftplanWeb.OrderLive.Index` loads **every order, unbounded, twice per mount**,
and re-loads on every navigation:

- `mount/3` → `load_initial_data/2` calls **both** `load_orders_for_calendar/2`
  (no pagination, no date filter) **and** `load_streamed_orders/2` (all orders
  streamed), each with `[:items, :total_cost, customer: [:full_name], items: [product: [:name]]]`.
- `handle_params/3` re-runs `load_orders_for_calendar/2` on **every** navigation,
  even in table mode.
- The table renders all ~4,365 rows; the calendar loads all orders but displays
  only the visible 7 days (`Enum.take(7)` + `get_orders_for_day/2`).

The database is **not** the bottleneck — indexes are present and used
(`orders_items`: 1.79M idx scans vs 783 seq scans), the pool is idle (50 idle / 1
active), Postgres CPU < 1%. The cost is the application materializing ~12k structs
+ a `total_cost` aggregate per render and shipping a huge payload over the tunnel,
which in turn breaks the LiveView transport.

## Decisions (from brainstorming)

- **Default window:** orders with `delivery_date` in **[today − 7d, today + 90d]**.
- **Window UX:** pre-fill the existing "Delivery date after/before" pickers with the
  window. Transparent, reuses existing filter UI. Clearing/widening the dates is the
  escape hatch to historical (imported) orders. **Reset filters** returns to the window.
- **Pagination:** offset pagination, **page size 100**, with **Prev/Next** controls
  and a "showing X–Y of N" label.
- **Per-view loading:** load only the active view's data (table *or* calendar), not both.

## Design

### 1. Per-view loading (core fix)

Stop eagerly loading both views. `mount/3` and `handle_params/3` determine
`view_mode` and load **only** that view's data. Switching views loads the other
side on demand.

### 2. Table — windowed + paginated

- `@default_filters` gains `delivery_date_start = today − 7d` and
  `delivery_date_end = today + 90d`, computed at mount (today is dynamic), rendered
  in the existing date pickers.
- The `:list` action already filters on those dates, so the query is bounded with
  no new filter code.
- Use the action's existing offset pagination (`pagination offset? true,
  countable true`, `order.ex`): `page: [limit: 100, offset: offset, count: true]`.
  Stream `page.results`; track `offset`, `count`, `more?` in assigns.
- **Prev / Next** controls below the table; re-stream with `reset: true` on page
  change. Label: "showing X–Y of N".
- Changing any filter resets `offset` to 0 and re-queries. **Reset filters**
  restores the default window (not empty).

### 3. Calendar — week-scoped

`load_orders_for_calendar/2` takes the visible `days_range` and queries with
`delivery_date` bounded to `[week_start, week_end]`, carrying over the non-date
filters (status / payment / customer) but **overriding** the date filter with the
displayed week — so week navigation works independent of the form's window. Each
prev/next/today change queries only that week (~dozens of orders).

### 4. No behavior regressions

Filter form, calendar week navigation, event modal, order creation insert, and
delete all preserved. Only *how much is loaded at once* changes. The pre-filled
window makes scoping visible rather than hidden (honest UI).

## Testing (TDD — failing tests first)

LiveView tests under `test/craftplan_web/live/manage/order_live/`:

1. With 120+ in-window orders, the table page holds **100**, not all.
2. Default window applied on mount: an out-of-window order is absent, then present
   after clearing the date filters.
3. Calendar loads only the visible week's orders; next/prev week shifts the set.
4. Prev/Next pagination advances/retreats the page and updates the X–Y of N label.
5. An explicit date filter overrides the default window.

## Out of scope

- Inventory / forecasting performance (separate investigation + PR).
- WebSocket-vs-longpoll transport: expected to self-resolve once the mount is fast;
  if it doesn't, a small separate `cloudflared` ingress tweak, tracked separately.
- Postgres / Docker tuning: ruled out by evidence; no change.
