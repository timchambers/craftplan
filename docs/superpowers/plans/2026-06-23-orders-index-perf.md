# Orders Index Performance (Bounded Load) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop `CraftplanWeb.OrderLive.Index` from loading every order on every render — bound the table to a date window + pagination, and the calendar to its visible week — eliminating the 11s / 23MB mount and the longpoll retry loop.

**Architecture:** The `:list` action already filters on `delivery_date_start`/`delivery_date_end` and supports offset pagination. We (1) default the filter date pickers to a [today−7d, today+90d] window, (2) switch the table from an unbounded Ash stream to an offset-paginated read (100/page) with Prev/Next, and (3) scope the calendar query to the displayed 7-day week. We also load only the active view's data instead of both views on every navigation.

**Tech Stack:** Elixir, Ash Framework (`Ash.Page.Offset`), Phoenix LiveView (streams), ExUnit + `Phoenix.LiveViewTest`.

## Global Constraints

- Run `mix format` before every commit (Styler/Spark/Tailwind/HEEx). Verbatim.
- Commit style: `type(scope): description` (e.g. `perf(orders):`, `test(orders):`).
- Tests run via `mix test` (runs `ash.setup --quiet` first).
- Page size is exactly **100**. Window is exactly **today − 7 days** to **today + 90 days**.
- Date picker values are ISO `YYYY-MM-DD` strings (parsed by existing `parse_date/2`).
- Only touch `lib/craftplan_web/live/manage/order_live/index.ex` and its tests. Do NOT change the `:list` action, the resource, or `docker-compose.yml`.

---

## File Structure

- Modify: `lib/craftplan_web/live/manage/order_live/index.ex` — all changes live here.
- Create: `test/craftplan_web/manage_orders_perf_live_test.exs` — new tests for window, pagination, calendar scoping.

Existing patterns to follow:
- Offset pagination + result unwrap: `lib/craftplan_web/live/manage/product_live/index.ex:108-127` (`page: [limit: 100]`, `%Ash.Page.Offset{results: res}`).
- Test style: `test/craftplan_web/manage_orders_live_test.exs` and `..._filters_calendar_interactions_live_test.exs` (`use CraftplanWeb.ConnCase, async: true`, `@tag role: :staff`, `live/2`, `render_change/2`, `render_click/1`).
- Factory: `Craftplan.Test.Factory.create_customer!/1`, `create_product!/0`, `create_order_with_items!(customer, items, opts)` where `opts` accepts `delivery_date:` (a `DateTime`).

---

## Task 1: Default the table to a [today−7d, today+90d] window

**Files:**
- Modify: `lib/craftplan_web/live/manage/order_live/index.ex` (`@default_filters`, `mount/3`, `handle_event("reset_filters", ...)`)
- Test: `test/craftplan_web/manage_orders_perf_live_test.exs`

**Interfaces:**
- Produces: `default_filters/0` (private) returning a `%{"status" => [], "payment_status" => [], "delivery_date_start" => iso8601, "delivery_date_end" => iso8601, "customer_name" => ""}` map. Module attrs `@page_size 100`, `@window_past_days 7`, `@window_future_days 90`.

- [ ] **Step 1: Write the failing test**

Create `test/craftplan_web/manage_orders_perf_live_test.exs`:

```elixir
defmodule CraftplanWeb.ManageOrdersPerfLiveTest do
  use CraftplanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Craftplan.Test.Factory

  defp order_at(delivery_date, customer_name) do
    customer = Factory.create_customer!(%{first_name: customer_name, last_name: "Perf"})
    product = Factory.create_product!()

    Factory.create_order_with_items!(
      customer,
      [%{product_id: product.id, quantity: 1, unit_price: product.price}],
      delivery_date: delivery_date
    )
  end

  defp days_from_now(days), do: DateTime.add(DateTime.utc_now(), days * 86_400, :second)

  describe "default delivery-date window" do
    @tag role: :staff
    test "pre-fills the date pickers with today-7 / today+90", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/manage/orders")
      today = Date.utc_today()
      assert html =~ Date.to_iso8601(Date.add(today, -7))
      assert html =~ Date.to_iso8601(Date.add(today, 90))
    end

    @tag role: :staff
    test "excludes orders outside the window, includes them after clearing dates", %{conn: conn} do
      _in_window = order_at(days_from_now(1), "InWindow")
      _out_of_window = order_at(days_from_now(-60), "WayBack")

      {:ok, view, html} = live(conn, ~p"/manage/orders")
      assert html =~ "InWindow"
      refute html =~ "WayBack"

      cleared =
        view
        |> element("#filters-form")
        |> render_change(%{
          "filters" => %{"delivery_date_start" => "", "delivery_date_end" => ""}
        })

      assert cleared =~ "WayBack"
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/craftplan_web/manage_orders_perf_live_test.exs -v`
Expected: FAIL — date pickers are empty by default, so the pre-fill assertions fail and `WayBack` shows up (no window applied).

- [ ] **Step 3: Replace the static default filters with a window-computing function**

In `index.ex`, near the top of the module, add attrs and a function, and delete the old `@default_filters` module attribute:

```elixir
# Calendar event duration in seconds
@calendar_event_duration 3600

@page_size 100
@window_past_days 7
@window_future_days 90

defp default_filters do
  today = Date.utc_today()

  %{
    "status" => [],
    "payment_status" => [],
    "delivery_date_start" => Date.to_iso8601(Date.add(today, -@window_past_days)),
    "delivery_date_end" => Date.to_iso8601(Date.add(today, @window_future_days)),
    "customer_name" => ""
  }
end
```

Then replace every reference to `@default_filters` with `default_filters()`:
- In `mount/3`: `assign(socket, :filters, default_filters())` and `parse_filters(default_filters())`.
- In `handle_event("reset_filters", ...)`: `assign(socket, :filters, default_filters())` and `parse_filters(default_filters())`.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/craftplan_web/manage_orders_perf_live_test.exs -v`
Expected: PASS (both tests in the "default delivery-date window" describe block).

- [ ] **Step 5: Format and commit**

```bash
mix format
git add lib/craftplan_web/live/manage/order_live/index.ex test/craftplan_web/manage_orders_perf_live_test.exs
git commit -m "perf(orders): default orders table to last-7/next-90-day window"
```

---

## Task 2: Offset-paginate the table (100/page) with Prev/Next

**Files:**
- Modify: `lib/craftplan_web/live/manage/order_live/index.ex` (table load path, render pagination controls, `mount/3`, `handle_event` for filters + new page events)
- Test: `test/craftplan_web/manage_orders_perf_live_test.exs`

**Interfaces:**
- Consumes: `@page_size`, `default_filters/0` (Task 1), `parse_filters/1` (existing).
- Produces:
  - `load_table_page(socket, filter_opts, offset) :: socket` (private) — reads one offset page, sets assigns `:page_offset`, `:page_count`, `:page_more`, and streams `:orders` with `reset: true`.
  - `page_label(offset, page_size, count) :: String.t()` (private) — `"Showing 1-100 of 120"` / `"No orders"`.
  - Assigns: `:page_offset` (int), `:page_count` (int), `:page_more` (bool).
  - Events: `"next_page"`, `"prev_page"`.

- [ ] **Step 1: Write the failing test**

Add this describe block to `test/craftplan_web/manage_orders_perf_live_test.exs`:

```elixir
  describe "table pagination" do
    @tag role: :staff
    test "shows 100 of N and pages through the rest", %{conn: conn} do
      customer = Factory.create_customer!(%{first_name: "Page", last_name: "Tester"})
      product = Factory.create_product!()

      for _ <- 1..120 do
        Factory.create_order_with_items!(
          customer,
          [%{product_id: product.id, quantity: 1, unit_price: product.price}],
          delivery_date: DateTime.add(DateTime.utc_now(), 86_400, :second)
        )
      end

      {:ok, view, html} = live(conn, ~p"/manage/orders")
      assert html =~ "Showing 1-100 of 120"
      assert has_element?(view, "button[phx-click=next_page]:not([disabled])")

      next = view |> element("button[phx-click=next_page]") |> render_click()
      assert next =~ "Showing 101-120 of 120"
      assert has_element?(view, "button[phx-click=prev_page]:not([disabled])")

      prev = view |> element("button[phx-click=prev_page]") |> render_click()
      assert prev =~ "Showing 1-100 of 120"
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/craftplan_web/manage_orders_perf_live_test.exs:NN -v` (the new test line)
Expected: FAIL — no "Showing ... of ..." label, no `next_page`/`prev_page` buttons exist.

- [ ] **Step 3: Add the paginated table load + label helper**

In `index.ex`, replace `load_streamed_orders/2` with `load_table_page/3` and add `page_label/3`:

```elixir
defp load_table_page(socket, filter_opts, offset) do
  page =
    Orders.list_orders!(
      filter_opts,
      actor: socket.assigns[:current_user],
      page: [limit: @page_size, offset: offset, count: true],
      load: [:items, :total_cost, customer: [:full_name], items: [product: [:name]]]
    )

  socket
  |> assign(:page_offset, page.offset)
  |> assign(:page_count, page.count)
  |> assign(:page_more, page.more?)
  |> stream(:orders, page.results, reset: true)
end

defp page_label(_offset, _page_size, 0), do: "No orders"

defp page_label(offset, page_size, count) do
  "Showing #{offset + 1}-#{min(offset + page_size, count)} of #{count}"
end
```

- [ ] **Step 4: Initialize page assigns in mount and load the first page**

In `mount/3`, replace the `stream(:orders, streamed_orders)` setup. The new `mount/3` body:

```elixir
def mount(_params, _session, socket) do
  filters = default_filters()
  filter_opts = parse_filters(filters)

  socket =
    socket
    |> assign(:filters, filters)
    |> assign(:products, Catalog.list_products!(actor: socket.assigns[:current_user]))
    |> assign(:customers, CRM.list_customers!(actor: socket.assigns[:current_user], load: [:full_name]))
    |> assign(:days_range, calculate_days_range())
    |> assign(:current_week_start, nil)
    |> assign(:orders, [])
    |> assign(:view_mode, "table")
    |> assign(:calendar_events, [])
    |> assign(:selected_order, nil)
    |> assign(:page_offset, 0)
    |> assign(:page_count, 0)
    |> assign(:page_more, false)
    |> stream(:orders, [])
    |> load_table_page(filter_opts, 0)

  {:ok, socket}
end
```

Delete the now-unused `load_initial_data/2` and `assign_initial_view_state/1` helpers (their work moved into `mount/3`).

- [ ] **Step 5: Add Prev/Next controls to the table render**

In `render/1`, inside the table `Page.surface` for `@view_mode == "table"`, immediately after the closing `</.table>` tag, add:

```heex
<div class="mt-4 flex items-center justify-between text-sm text-stone-600">
  <span>{page_label(@page_offset, @page_size, @page_count)}</span>
  <div class="flex items-center gap-2">
    <.button
      variant={:outline}
      phx-click="prev_page"
      disabled={@page_offset == 0}
    >
      Previous
    </.button>
    <.button
      variant={:outline}
      phx-click="next_page"
      disabled={!@page_more}
    >
      Next
    </.button>
  </div>
</div>
```

Add `@page_size` into render scope: at the top of `render/1` where other `assign_new` calls are, add `|> assign_new(:page_size, fn -> @page_size end)`.

- [ ] **Step 6: Add next_page / prev_page handlers and reset offset on filter changes**

Add handlers:

```elixir
@impl true
def handle_event("next_page", _params, socket) do
  filter_opts = parse_filters(socket.assigns.filters)
  offset = socket.assigns.page_offset + @page_size
  {:noreply, load_table_page(socket, filter_opts, offset)}
end

@impl true
def handle_event("prev_page", _params, socket) do
  filter_opts = parse_filters(socket.assigns.filters)
  offset = max(0, socket.assigns.page_offset - @page_size)
  {:noreply, load_table_page(socket, filter_opts, offset)}
end
```

`load_streamed_orders/2` is now deleted, so update **every** remaining caller (otherwise the build breaks). In `handle_params/3`, the `else` branch currently does `streamed_orders = load_streamed_orders(socket, filter_opts); stream(socket, :orders, streamed_orders, reset: true)` — replace that whole `else` body with `load_table_page(socket, filter_opts, 0)`:

```elixir
socket =
  if socket.assigns.view_mode == view_mode do
    socket
  else
    load_table_page(socket, filter_opts, 0)
  end
```

(This is a temporary patch; Task 3 rewrites `handle_params/3` entirely.)

In `handle_event("apply_filters", ...)`, `handle_event("reset_filters", ...)`, and `handle_event("update_date_filters", ...)`: replace the `load_streamed_orders(...)` + `stream(:orders, streamed_orders, reset: true)` lines with `load_table_page(socket, filter_opts, 0)`. (Keep these handlers' calendar work for now; Task 3 fixes that.) Example for `apply_filters`:

```elixir
@impl true
def handle_event("apply_filters", %{"filters" => raw_filters}, socket) do
  new_filters = Map.merge(socket.assigns.filters, raw_filters)
  filter_opts = parse_filters(new_filters)

  orders_for_calendar = load_orders_for_calendar(socket, filter_opts)
  calendar_events = create_calendar_events(orders_for_calendar, @calendar_event_duration)

  {:noreply,
   socket
   |> assign(:filters, new_filters)
   |> assign(:orders, orders_for_calendar)
   |> assign(:calendar_events, calendar_events)
   |> load_table_page(filter_opts, 0)}
end
```

- [ ] **Step 7: Run test to verify it passes**

Run: `mix test test/craftplan_web/manage_orders_perf_live_test.exs -v`
Expected: PASS (window + pagination describe blocks).

- [ ] **Step 8: Format and commit**

```bash
mix format
git add lib/craftplan_web/live/manage/order_live/index.ex test/craftplan_web/manage_orders_perf_live_test.exs
git commit -m "perf(orders): offset-paginate orders table at 100/page with prev/next"
```

---

## Task 3: Scope the calendar to its visible week + load only the active view

**Files:**
- Modify: `lib/craftplan_web/live/manage/order_live/index.ex` (`load_orders_for_calendar`, `handle_params/3`, week-navigation handlers, `handle_info` guard)
- Test: `test/craftplan_web/manage_orders_perf_live_test.exs`

**Interfaces:**
- Consumes: `calculate_days_range/1`, `create_calendar_events/2` (existing), `load_table_page/3` (Task 2).
- Produces:
  - `calendar_window(days_range) :: {DateTime.t(), DateTime.t()}` (public, for unit test) — start-of-first-day .. end-of-last-day, UTC.
  - `load_orders_for_calendar(socket, filter_opts, days_range) :: [order]` (private, now 3-arity) — overrides date bounds with the week.
  - `load_view_data(socket, view_mode, filter_opts) :: socket` (private) — loads only the active view.

- [ ] **Step 1: Write the failing tests**

Add to `test/craftplan_web/manage_orders_perf_live_test.exs`:

```elixir
  describe "calendar window scoping" do
    @tag role: :staff
    test "calendar_window/1 bounds the first..last day of the range in UTC" do
      range = [~D[2026-06-22], ~D[2026-06-23], ~D[2026-06-24], ~D[2026-06-25],
               ~D[2026-06-26], ~D[2026-06-27], ~D[2026-06-28]]

      {start_dt, end_dt} = CraftplanWeb.OrderLive.Index.calendar_window(range)

      assert start_dt == ~U[2026-06-22 00:00:00Z]
      assert end_dt == ~U[2026-06-28 23:59:59Z]
    end

    @tag role: :staff
    test "calendar shows this week's order and not next week's, and flips on navigation",
         %{conn: conn} do
      week_start = Date.add(Date.utc_today(), -(Date.day_of_week(Date.utc_today()) - 1))
      this_week = DateTime.new!(Date.add(week_start, 1), ~T[10:00:00], "Etc/UTC")
      next_week = DateTime.new!(Date.add(week_start, 8), ~T[10:00:00], "Etc/UTC")

      _c1 = order_at(this_week, "ThisWeekCust")
      _c2 = order_at(next_week, "NextWeekCust")

      {:ok, view, html} = live(conn, ~p"/manage/orders?view=calendar")
      assert html =~ "ThisWeekCust"
      refute html =~ "NextWeekCust"

      flipped = view |> element("button[phx-click=next_week]") |> render_click()
      assert flipped =~ "NextWeekCust"
      refute flipped =~ "ThisWeekCust"
    end
  end
```

Note: `order_at/2` is the helper defined in Task 1's test; it now also accepts a `DateTime`.

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/craftplan_web/manage_orders_perf_live_test.exs -v`
Expected: FAIL — `calendar_window/1` is undefined; calendar currently loads the whole window so `next_week` navigation may not flip cleanly.

- [ ] **Step 3: Add calendar_window/1 and make load_orders_for_calendar week-scoped**

Replace the existing 2-arity `load_orders_for_calendar/2` with:

```elixir
def calendar_window(days_range) do
  week_start = List.first(days_range)
  week_end = List.last(days_range)

  {DateTime.new!(week_start, ~T[00:00:00], "Etc/UTC"),
   DateTime.new!(week_end, ~T[23:59:59], "Etc/UTC")}
end

defp load_orders_for_calendar(socket, filter_opts, days_range) do
  {start_dt, end_dt} = calendar_window(days_range)

  cal_opts =
    filter_opts
    |> Map.put(:delivery_date_start, start_dt)
    |> Map.put(:delivery_date_end, end_dt)

  Orders.list_orders!(
    cal_opts,
    actor: socket.assigns[:current_user],
    load: [:items, :total_cost, customer: [:full_name], items: [product: [:name]]]
  )
end
```

- [ ] **Step 4: Add per-view loader and rewrite handle_params to use it**

Add:

```elixir
defp load_view_data(socket, "calendar", filter_opts) do
  orders = load_orders_for_calendar(socket, filter_opts, socket.assigns.days_range)

  socket
  |> assign(:orders, orders)
  |> assign(:calendar_events, create_calendar_events(orders, @calendar_event_duration))
end

defp load_view_data(socket, _table, filter_opts) do
  load_table_page(socket, filter_opts, 0)
end
```

Rewrite `handle_params/3`:

```elixir
@impl true
def handle_params(params, _url, socket) do
  view_mode = Map.get(params, "view", "table")
  filter_opts = parse_filters(socket.assigns.filters)
  days_range = calculate_days_range(socket.assigns[:current_week_start])

  socket =
    socket
    |> assign(:view_mode, view_mode)
    |> assign(:days_range, days_range)
    |> load_view_data(view_mode, filter_opts)
    |> apply_action(socket.assigns.live_action, params)

  {:noreply, Navigation.assign(socket, :orders, order_trail(socket.assigns))}
end
```

- [ ] **Step 5: Update week-navigation handlers to reload only the week's orders**

In `handle_event("prev_week", ...)`, `"next_week"`, and `"today"`: after computing the new `days_range`, replace the `load_orders_for_calendar(socket, filter_opts)` (2-arity) call with the 3-arity version passing the new range. Example for `next_week`:

```elixir
@impl true
def handle_event("next_week", _params, socket) do
  new_start = Date.add(List.first(socket.assigns.days_range), 7)
  days_range = date_range(new_start)
  filter_opts = parse_filters(socket.assigns.filters)
  orders_for_calendar = load_orders_for_calendar(socket, filter_opts, days_range)

  {:noreply,
   socket
   |> assign(:current_week_start, new_start)
   |> assign(:days_range, days_range)
   |> assign(:orders, orders_for_calendar)
   |> assign(:calendar_events, create_calendar_events(orders_for_calendar, @calendar_event_duration))}
end
```

Apply the same 3-arity change in `prev_week` (uses `Date.add(..., -7)`) and `today` (uses `calculate_days_range()`). Also update `handle_event("apply_filters", ...)`, `"reset_filters"`, and `"update_date_filters"` to pass `socket.assigns.days_range` to `load_orders_for_calendar/3`.

- [ ] **Step 6: Guard handle_info for the saved-order case**

The `handle_info({CraftplanWeb.OrderLive.FormComponent, {:saved, order}}, socket)` handler prepends to `socket.assigns.orders`. Keep it, but recompute calendar events from the (possibly empty in table mode) `@orders` and stream-insert into the table:

```elixir
@impl true
def handle_info({CraftplanWeb.OrderLive.FormComponent, {:saved, order}}, socket) do
  order =
    Ash.load!(order, [:items, :total_cost, customer: [:full_name]],
      actor: socket.assigns[:current_user]
    )

  orders = [order | socket.assigns.orders]

  {:noreply,
   socket
   |> stream_insert(:orders, order, at: 0)
   |> assign(:orders, orders)
   |> assign(:calendar_events, create_calendar_events(orders, @calendar_event_duration))}
end
```

- [ ] **Step 7: Run the new tests to verify they pass**

Run: `mix test test/craftplan_web/manage_orders_perf_live_test.exs -v`
Expected: PASS (all describe blocks: window, pagination, calendar scoping).

- [ ] **Step 8: Run the full orders LiveView suite for regressions**

Run: `mix test test/craftplan_web/manage_orders_live_test.exs test/craftplan_web/manage_orders_filters_calendar_interactions_live_test.exs test/craftplan_web/manage_orders_interactions_live_test.exs test/craftplan_web/manage_orders_details_edit_interactions_live_test.exs test/craftplan_web/manage_orders_items_interactions_live_test.exs`
Expected: PASS (or same pre-existing failures as `main` — see note below).

- [ ] **Step 9: Format and commit**

```bash
mix format
git add lib/craftplan_web/live/manage/order_live/index.ex test/craftplan_web/manage_orders_perf_live_test.exs
git commit -m "perf(orders): scope calendar to visible week and load only the active view"
```

---

## Task 4: Full verification

- [ ] **Step 1: Run the complete test suite**

Run: `mix test`
Expected: PASS, except known pre-existing failures on `main` (the project has a documented ~92-100 pre-existing failures, mostly orders + LiveView). Confirm the new `manage_orders_perf_live_test.exs` passes and that no *new* failures were introduced versus `main`. If unsure, `git stash` is not applicable (committed) — compare against a clean `main` run.

- [ ] **Step 2: Compile cleanly with warnings as errors**

Run: `mix compile --warnings-as-errors`
Expected: no warnings (e.g. no unused `load_initial_data/2`, `assign_initial_view_state/1`, or 2-arity `load_orders_for_calendar/2` left behind).

- [ ] **Step 3: Final commit if formatting changed anything**

```bash
mix format
git add -A lib/ test/
git diff --cached --quiet || git commit -m "style(orders): mix format after perf changes"
```

---

## Self-Review notes

- **Spec coverage:** default window (Task 1), pre-filled pickers (Task 1 Step 5 test), escape hatch via clearing dates (Task 1 test), pagination 100 + Prev/Next + label (Task 2), reset-to-window (Task 1 reset_filters), calendar week-scoping overriding the form window (Task 3), per-view loading (Task 3 `load_view_data`), no-regression of filters/calendar/modal/delete (Task 3 Step 8). All covered.
- **Type consistency:** `load_table_page/3`, `load_orders_for_calendar/3`, `calendar_window/1`, `page_label/3`, assigns `:page_offset`/`:page_count`/`:page_more`/`:page_size` used consistently across tasks. The 2-arity `load_orders_for_calendar/2` and `load_streamed_orders/2` are fully removed.
- **Pagination/stream:** offset pagination replaces Ash `stream?: true` (they are mutually exclusive); `page.results` feeds the LiveView stream.
- **Out of scope (unchanged):** inventory/forecast perf, cloudflared/WebSocket, Postgres/Docker tuning.
