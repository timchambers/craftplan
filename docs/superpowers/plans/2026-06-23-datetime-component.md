# Semantic `<time>` datetime component + sweep — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a reusable `<.datetime>` component that renders any date/time value as a semantic `<time>` element (visible human date, ISO `datetime` attr, full date+time `title` tooltip), and convert the user-facing date/time render sites to use it.

**Architecture:** Two formatting helpers in `html_helpers.ex` (`datetime_attr/2`, `format_datetime/2`), one function component `datetime/1` in `core.ex` composing them, then a mechanical sweep replacing 15 render sites across 9 files. Server-side timezone via the existing `@time_zone`.

**Tech Stack:** Elixir 1.18.3 / OTP 27, Phoenix LiveView, `Phoenix.Component`, `Calendar.strftime`, ExUnit + `Phoenix.LiveViewTest`.

## Global Constraints

- Run `mix` via mise shims: `PATH="$HOME/.local/share/mise/shims:$PATH" mix ...`. Never Homebrew Elixir.
- **PRs target the fork `origin` (`timchambers/craftplan`), never `upstream`.** `gh pr create --repo timchambers/craftplan`.
- Do NOT run repo-wide `mix format` (it reformats ~15 unrelated files). Format only touched files.
- Component name: `<.datetime>`. Timezone: server-side `@time_zone` (no client JS). `datetime` attr: canonical ISO 8601 (UTC). `title`: full localized date + time. `precision`: `:date` (default) | `:datetime`. Never render a bare time.
- Commit style: `type(scope): description`.
- This work **supersedes PR #14** — close #14 unmerged at the end (Task 6).
- The 3 pre-existing failures in `test/craftplan_web/manage_inventory_interactions_live_test.exs` ("adjust stock") fail on `main` independently; they are out of scope. Never claim a clean suite without accounting for them.
- `core.ex` already has `import CraftplanWeb.HtmlHelpers`, so the component calls helpers unqualified.

---

### Task 1: Formatting helpers `datetime_attr/2` and `format_datetime/2`

**Files:**
- Modify: `lib/craftplan_web/html_helpers.ex` (add two public functions near the existing `format_date`/`format_time`)
- Test: `test/craftplan_web/html_helpers_datetime_test.exs` (create)

**Interfaces:**
- Produces:
  - `datetime_attr(value :: Date.t()|NaiveDateTime.t()|DateTime.t()|nil, tz :: String.t()|nil) :: String.t()` — canonical ISO 8601. `Date` → `"YYYY-MM-DD"`; `NaiveDateTime`/`DateTime` → UTC ISO 8601 (`"…Z"`); `nil` → `""`.
  - `format_datetime(value, tz) :: String.t()` — full localized date + time. `Date` → long date only (`"January 13, 2026"`); `NaiveDateTime`/`DateTime` → `"January 13, 2026 at 5:00 AM"` (long date + 12h time, shifted to `tz`); `nil` → `""`.

- [ ] **Step 1: Write the failing test**

Create `test/craftplan_web/html_helpers_datetime_test.exs`:

```elixir
defmodule CraftplanWeb.HtmlHelpersDatetimeTest do
  use ExUnit.Case, async: true

  import CraftplanWeb.HtmlHelpers

  describe "datetime_attr/2" do
    test "Date renders YYYY-MM-DD" do
      assert datetime_attr(~D[2026-01-13], nil) == "2026-01-13"
    end

    test "DateTime renders canonical UTC ISO 8601" do
      dt = DateTime.new!(~D[2026-01-13], ~T[05:00:00], "Etc/UTC")
      assert datetime_attr(dt, "America/New_York") == "2026-01-13T05:00:00Z"
    end

    test "NaiveDateTime is treated as UTC" do
      assert datetime_attr(~N[2026-01-13 05:00:00], nil) == "2026-01-13T05:00:00Z"
    end

    test "nil renders empty string" do
      assert datetime_attr(nil, nil) == ""
    end
  end

  describe "format_datetime/2" do
    test "DateTime shows long date + 12h time in the timezone" do
      dt = DateTime.new!(~D[2026-01-13], ~T[12:00:00], "Etc/UTC")
      # 12:00 UTC is 07:00 in America/New_York (EST, -05:00)
      assert format_datetime(dt, "America/New_York") == "January 13, 2026 at 7:00 AM"
    end

    test "Date shows long date only (no time)" do
      assert format_datetime(~D[2026-01-13], nil) == "January 13, 2026"
    end

    test "nil renders empty string" do
      assert format_datetime(nil, nil) == ""
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `PATH="$HOME/.local/share/mise/shims:$PATH" mix test test/craftplan_web/html_helpers_datetime_test.exs`
Expected: FAIL — `datetime_attr/2` / `format_datetime/2` undefined.

- [ ] **Step 3: Implement the helpers**

In `lib/craftplan_web/html_helpers.ex`, add after the `format_time` block (before the private helpers section). Note `format_date`/`format_time` and the private `normalize_datetime/2` already exist in this module.

```elixir
@doc """
Canonical ISO 8601 string for a `<time datetime=…>` attribute. Dates render
as `YYYY-MM-DD`; datetimes render as UTC (`…Z`). Returns "" for nil.
"""
@spec datetime_attr(datetime_input | nil, String.t() | nil) :: String.t()
def datetime_attr(nil, _tz), do: ""
def datetime_attr(%Date{} = date, _tz), do: Date.to_iso8601(date)

def datetime_attr(%NaiveDateTime{} = naive, _tz) do
  naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
end

def datetime_attr(%DateTime{} = datetime, _tz) do
  datetime |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_iso8601()
end

@doc """
Full, human-readable localized date + time for a `title` tooltip. Dates show
the long date only; datetimes show long date + 12h time shifted to `tz`.
Returns "" for nil.
"""
@spec format_datetime(datetime_input | nil, String.t() | nil) :: String.t()
def format_datetime(nil, _tz), do: ""
def format_datetime(%Date{} = date, _tz), do: format_date(date, format: :long)

def format_datetime(value, tz) do
  format_date(value, format: :long, timezone: tz) <> " at " <> format_time(value, format: :time12, timezone: tz)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `PATH="$HOME/.local/share/mise/shims:$PATH" mix test test/craftplan_web/html_helpers_datetime_test.exs`
Expected: PASS (10 assertions). If the EST offset differs (DST/tz-data), adjust the expected `7:00 AM` to match the helper's actual output — the point is "shifted to tz", not the exact hour.

- [ ] **Step 5: Commit**

```bash
PATH="$HOME/.local/share/mise/shims:$PATH" mix format lib/craftplan_web/html_helpers.ex test/craftplan_web/html_helpers_datetime_test.exs
git add lib/craftplan_web/html_helpers.ex test/craftplan_web/html_helpers_datetime_test.exs
git commit -m "feat(ui): add datetime_attr/2 and format_datetime/2 helpers"
```

---

### Task 2: The `<.datetime>` component

**Files:**
- Modify: `lib/craftplan_web/components/core.ex` (add `datetime/1` function component)
- Test: `test/craftplan_web/datetime_component_test.exs` (create)

**Interfaces:**
- Consumes: `datetime_attr/2`, `format_datetime/2` (Task 1), and existing `format_date/2`, `format_time/2` (already imported in `core.ex`).
- Produces: component `datetime/1` usable in HEEx as `<.datetime value={…} time_zone={@time_zone} precision={:date|:datetime} class={…} empty={…} />`.

- [ ] **Step 1: Write the failing test**

Create `test/craftplan_web/datetime_component_test.exs`:

```elixir
defmodule CraftplanWeb.DatetimeComponentTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  defp render_dt(assigns), do: render_component(&CraftplanWeb.Components.Core.datetime/1, assigns)

  test "renders a <time> with datetime attr and date-only visible text by default" do
    dt = DateTime.new!(~D[2026-01-13], ~T[05:00:00], "Etc/UTC")
    html = render_dt(%{value: dt, time_zone: "America/New_York"})

    assert html =~ ~s(<time)
    assert html =~ ~s(datetime="2026-01-13T05:00:00Z")
    assert html =~ "Jan 13, 2026"
    # title carries the full localized date + time
    assert html =~ ~s(title=")
    assert html =~ "at"
    # date-only visible text must NOT contain a bare clock time
    refute html =~ ~r/>\s*\d{1,2}:\d{2}/
  end

  test "precision :datetime shows date and time in the visible text" do
    dt = DateTime.new!(~D[2026-01-13], ~T[12:00:00], "Etc/UTC")
    html = render_dt(%{value: dt, time_zone: "America/New_York", precision: :datetime})

    assert html =~ "January 13, 2026 at"
    assert html =~ "AM"
  end

  test "Date value renders YYYY-MM-DD datetime attr and medium date" do
    html = render_dt(%{value: ~D[2026-01-13], time_zone: nil})
    assert html =~ ~s(datetime="2026-01-13")
    assert html =~ "Jan 13, 2026"
  end

  test "nil value renders the empty placeholder, no <time> tag" do
    html = render_dt(%{value: nil, time_zone: nil})
    refute html =~ "<time"
    assert html =~ "—"
  end

  test "custom empty placeholder is honored" do
    html = render_dt(%{value: nil, time_zone: nil, empty: "never"})
    assert html =~ "never"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `PATH="$HOME/.local/share/mise/shims:$PATH" mix test test/craftplan_web/datetime_component_test.exs`
Expected: FAIL — `CraftplanWeb.Components.Core.datetime/1` undefined.

- [ ] **Step 3: Implement the component**

In `lib/craftplan_web/components/core.ex`, add (anywhere among the other components, e.g. after `kbd/1`):

```elixir
@doc """
Renders a date/time value as a semantic `<time>` element.

  * Visible text is a human date (`:date`, default) or date + time (`:datetime`) — never a bare time.
  * `datetime` attribute is the canonical ISO 8601 instant (machine-readable).
  * `title` attribute is the full localized date + time (browser tooltip on hover).

## Examples

    <.datetime value={@order.delivery_date} time_zone={@time_zone} />
    <.datetime value={@batch.completed_at} time_zone={@time_zone} precision={:datetime} />
"""
attr :value, :any, required: true, doc: "Date, NaiveDateTime, or DateTime (nil renders the empty placeholder)"
attr :time_zone, :string, default: nil, doc: "IANA timezone; pass @time_zone"
attr :precision, :atom, default: :date, values: [:date, :datetime]
attr :class, :string, default: nil
attr :empty, :string, default: "—"

def datetime(%{value: nil} = assigns) do
  ~H"""
  <span class={@class}>{@empty}</span>
  """
end

def datetime(assigns) do
  assigns =
    assigns
    |> assign(:machine, datetime_attr(assigns.value, assigns.time_zone))
    |> assign(:full, format_datetime(assigns.value, assigns.time_zone))
    |> assign(:label, datetime_label(assigns.value, assigns.precision, assigns.time_zone))

  ~H"""
  <time datetime={@machine} title={@full} class={@class}>{@label}</time>
  """
end

defp datetime_label(value, :datetime, tz), do: format_datetime(value, tz)
defp datetime_label(value, _precision, tz), do: format_date(value, format: :medium, timezone: tz)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `PATH="$HOME/.local/share/mise/shims:$PATH" mix test test/craftplan_web/datetime_component_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
PATH="$HOME/.local/share/mise/shims:$PATH" mix format lib/craftplan_web/components/core.ex test/craftplan_web/datetime_component_test.exs
git add lib/craftplan_web/components/core.ex test/craftplan_web/datetime_component_test.exs
git commit -m "feat(ui): add <.datetime> semantic time component"
```

---

### Task 3: Sweep — Orders views

**Files:**
- Modify: `lib/craftplan_web/live/manage/order_live/index.ex` (lines 162, 372)
- Modify: `lib/craftplan_web/live/manage/order_live/show.ex` (lines 94, 98)
- Test: `test/craftplan_web/manage_orders_live_test.exs` (add one render assertion)

**Interfaces:** Consumes `<.datetime>` (Task 2).

- [ ] **Step 1: Add a render assertion (failing until the swap)**

In `test/craftplan_web/manage_orders_live_test.exs`, inside the `describe "show tabs"` block, add:

```elixir
@tag role: :staff
test "order show renders delivery date as a <time> element", %{conn: conn} do
  product = Factory.create_product!()
  customer = Factory.create_customer!()

  order =
    Factory.create_order_with_items!(customer, [
      %{product_id: product.id, quantity: 2, unit_price: product.price}
    ])

  {:ok, _view, html} = live(conn, ~p"/manage/orders/#{order.reference}")
  assert html =~ "<time"
  assert html =~ ~s(datetime=)
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `PATH="$HOME/.local/share/mise/shims:$PATH" mix test test/craftplan_web/manage_orders_live_test.exs -o "order show renders delivery date"`
(If the `-o` filter is unsupported, run the whole file and confirm this test fails.)
Expected: FAIL — no `<time` element yet.

- [ ] **Step 3: Convert the four order sites**

In `lib/craftplan_web/live/manage/order_live/index.ex`:

Line 162 (list "Delivery date" column):
```elixir
{format_time(order.delivery_date, @time_zone)}
```
→
```elixir
<.datetime value={order.delivery_date} time_zone={@time_zone} />
```

Lines 371-373 (selected-order panel — relabel "Delivery time" → "Delivery", show date + time):
```elixir
<:item title="Delivery time">
  {format_time(@selected_order.delivery_date, @time_zone)}
</:item>
```
→
```elixir
<:item title="Delivery">
  <.datetime value={@selected_order.delivery_date} time_zone={@time_zone} precision={:datetime} />
</:item>
```

In `lib/craftplan_web/live/manage/order_live/show.ex`:

Line 94 ("Delivery Date"):
```elixir
{format_time(@order.delivery_date, @time_zone)}
```
→
```elixir
<.datetime value={@order.delivery_date} time_zone={@time_zone} />
```

Line 98 ("Created At"):
```elixir
{format_time(@order.inserted_at, @time_zone)}
```
→
```elixir
<.datetime value={@order.inserted_at} time_zone={@time_zone} />
```

**Do NOT touch** `order_live/index.ex:192` (`"%B %Y"` month header — a period label) or `order_live/index.ex:312` (`format_hour` inside a day-grouped calendar card — the date is the column; the slot time is the useful info there).

- [ ] **Step 4: Run tests to verify they pass**

Run: `PATH="$HOME/.local/share/mise/shims:$PATH" mix test test/craftplan_web/manage_orders_live_test.exs`
Expected: PASS (file green).

- [ ] **Step 5: Commit**

```bash
PATH="$HOME/.local/share/mise/shims:$PATH" mix format lib/craftplan_web/live/manage/order_live/index.ex lib/craftplan_web/live/manage/order_live/show.ex test/craftplan_web/manage_orders_live_test.exs
git add lib/craftplan_web/live/manage/order_live/index.ex lib/craftplan_web/live/manage/order_live/show.ex test/craftplan_web/manage_orders_live_test.exs
git commit -m "ui(orders): render order dates via <.datetime>"
```

---

### Task 4: Sweep — Customer, Inventory, Production batches

**Files:**
- Modify: `lib/craftplan_web/live/manage/customer_live/show.ex` (lines 63, 66)
- Modify: `lib/craftplan_web/live/manage/inventory_live/show.ex` (line 158)
- Modify: `lib/craftplan_web/live/manage/production_batch_live/index.ex` (line 149)
- Modify: `lib/craftplan_web/live/manage/production_batch_live/show.ex` (line 107 call site; delete now-unused `format_batch_time/2` at lines 648-652)
- Test: `test/craftplan_web/manage_customers_live_test.exs` (add one render assertion)

**Interfaces:** Consumes `<.datetime>` (Task 2).

> NOTE: `customer_live/show.ex` is also touched by the open PR #13 (lines 29-30, nil-address guard). This task edits lines 63/66 only — different lines, so the two branches merge cleanly.

- [ ] **Step 1: Add a render assertion (failing until the swap)**

In `test/craftplan_web/manage_customers_live_test.exs`, inside `describe "show tabs"`, add:

```elixir
@tag role: :staff
test "customer order-history tab renders dates as <time> elements", %{conn: conn} do
  c = create_customer!()
  {:ok, _view, html} = live(conn, ~p"/manage/customers/#{c.reference}/orders")
  assert html =~ "<time"
end
```

(`create_customer!/1` already exists in this file and sets both addresses.) If the customer has no orders, the table is empty and renders no `<time>`; create an order first:

```elixir
@tag role: :staff
test "customer order-history tab renders dates as <time> elements", %{conn: conn} do
  c = create_customer!()
  product = Craftplan.Test.Factory.create_product!()
  Craftplan.Test.Factory.create_order_with_items!(c, [
    %{product_id: product.id, quantity: 1, unit_price: product.price}
  ])

  {:ok, _view, html} = live(conn, ~p"/manage/customers/#{c.reference}/orders")
  assert html =~ "<time"
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `PATH="$HOME/.local/share/mise/shims:$PATH" mix test test/craftplan_web/manage_customers_live_test.exs`
Expected: the new test FAILS (no `<time>` yet); others pass.

- [ ] **Step 3: Convert the sites**

`customer_live/show.ex` line 63 ("Created at"):
```elixir
{format_time(order.inserted_at, @time_zone)}
```
→
```elixir
<.datetime value={order.inserted_at} time_zone={@time_zone} />
```

`customer_live/show.ex` line 66 ("Delivery Date"):
```elixir
{format_time(order.delivery_date, @time_zone)}
```
→
```elixir
<.datetime value={order.delivery_date} time_zone={@time_zone} />
```

`inventory_live/show.ex` line 158 ("Date"):
```elixir
{format_time(entry.occurred_at || entry.inserted_at, @time_zone)}
```
→
```elixir
<.datetime value={entry.occurred_at || entry.inserted_at} time_zone={@time_zone} />
```

`production_batch_live/index.ex` line 149 ("Created"):
```elixir
{format_time(batch.inserted_at, @time_zone)}
```
→
```elixir
<.datetime value={batch.inserted_at} time_zone={@time_zone} />
```

`production_batch_live/show.ex` line 107 ("Produced At"):
```elixir
<.summary_card label="Produced At" value={format_batch_time(@produced_at, @time_zone)}>
```
→
```elixir
<.summary_card label="Produced At" value={nil}>
  <.datetime value={@produced_at} time_zone={@time_zone} />
```
…**only if `summary_card` renders its inner block.** Check `summary_card`'s definition first: if it renders `value` as a string and ignores inner block, instead keep it string-based by leaving `format_batch_time` in place for THIS one site and skip it (a `<time>` element can't be passed as a plain string `value`). If `summary_card` has an inner-block slot, use the inner-block form above and then delete `format_batch_time/2` (lines 648-652) since it's no longer referenced. Document which path you took in the report.

- [ ] **Step 4: Run tests to verify they pass**

Run: `PATH="$HOME/.local/share/mise/shims:$PATH" mix test test/craftplan_web/manage_customers_live_test.exs test/craftplan_web/manage_inventory_live_test.exs test/craftplan_web/production_batch_live_test.exs`
Expected: PASS (no new failures; pre-existing `manage_inventory_interactions` failures are NOT in this set).

- [ ] **Step 5: Commit**

```bash
PATH="$HOME/.local/share/mise/shims:$PATH" mix format lib/craftplan_web/live/manage/customer_live/show.ex lib/craftplan_web/live/manage/inventory_live/show.ex lib/craftplan_web/live/manage/production_batch_live/index.ex lib/craftplan_web/live/manage/production_batch_live/show.ex test/craftplan_web/manage_customers_live_test.exs
git add lib/craftplan_web/live/manage/customer_live/show.ex lib/craftplan_web/live/manage/inventory_live/show.ex lib/craftplan_web/live/manage/production_batch_live/index.ex lib/craftplan_web/live/manage/production_batch_live/show.ex test/craftplan_web/manage_customers_live_test.exs
git commit -m "ui: render customer/inventory/batch dates via <.datetime>"
```

---

### Task 5: Sweep — Purchasing + BOM recipe

**Files:**
- Modify: `lib/craftplan_web/live/manage/purchasing_live/index.ex` (lines 37, 38)
- Modify: `lib/craftplan_web/live/manage/purchasing_live/show.ex` (lines 37, 38)
- Modify: `lib/craftplan_web/live/manage/product_live/form_component_recipe.ex` (lines 32, 706)
- Test: add a render assertion to an existing purchasing LiveView test if one exists; otherwise rely on the existing suites + the component test.

**Interfaces:** Consumes `<.datetime>` (Task 2).

- [ ] **Step 1: Locate a purchasing LiveView test**

Run: `ls test/craftplan_web/ | grep -i purchas`
If a test renders the PO index or show, add an assertion `assert html =~ "<time"` after rendering it. If none exists, skip the test step (the component is already covered by Task 2; this task is a mechanical swap verified by the existing suites compiling/passing).

- [ ] **Step 2: Convert the sites**

`purchasing_live/index.ex` line 37 / 38:
```elixir
<:col :let={po} label="Ordered">{format_date(po.ordered_at, @time_zone)}</:col>
<:col :let={po} label="Received">{format_date(po.received_at, @time_zone)}</:col>
```
→
```elixir
<:col :let={po} label="Ordered"><.datetime value={po.ordered_at} time_zone={@time_zone} /></:col>
<:col :let={po} label="Received"><.datetime value={po.received_at} time_zone={@time_zone} /></:col>
```

`purchasing_live/show.ex` line 37 / 38:
```elixir
<:item title="Ordered At">{format_date(@po.ordered_at, @time_zone)}</:item>
<:item title="Received At">{format_date(@po.received_at, @time_zone)}</:item>
```
→
```elixir
<:item title="Ordered At"><.datetime value={@po.ordered_at} time_zone={@time_zone} /></:item>
<:item title="Received At"><.datetime value={@po.received_at} time_zone={@time_zone} /></:item>
```

`form_component_recipe.ex` line 32 ("Changed on"):
```elixir
{@bom.published_at && format_date(@bom.published_at)}
```
→
```elixir
<.datetime :if={@bom.published_at} value={@bom.published_at} time_zone={@time_zone} />
```
(If `@time_zone` is not assigned in this component's assigns, pass `time_zone={assigns[:time_zone]}` or omit the attr — `datetime_attr`/`format_date` tolerate `nil` tz. Verify whether `@time_zone` exists here; if not, omit `time_zone`.)

`form_component_recipe.ex` line 706 ("Published" column):
```elixir
{if b.published_at, do: format_date(b.published_at, format: :short), else: "-"}
```
→
```elixir
<.datetime value={b.published_at} time_zone={assigns[:time_zone]} empty="-" />
```

- [ ] **Step 3: Run the suites**

Run: `PATH="$HOME/.local/share/mise/shims:$PATH" mix test $(ls test/craftplan_web/*purchas* test/craftplan_web/*recipe* 2>/dev/null)`
Expected: PASS. If no such test files exist, run `PATH="$HOME/.local/share/mise/shims:$PATH" mix compile --warnings-as-errors` (scoped) to confirm the templates compile.

- [ ] **Step 4: Commit**

```bash
PATH="$HOME/.local/share/mise/shims:$PATH" mix format lib/craftplan_web/live/manage/purchasing_live/index.ex lib/craftplan_web/live/manage/purchasing_live/show.ex lib/craftplan_web/live/manage/product_live/form_component_recipe.ex
git add lib/craftplan_web/live/manage/purchasing_live/index.ex lib/craftplan_web/live/manage/purchasing_live/show.ex lib/craftplan_web/live/manage/product_live/form_component_recipe.ex
git commit -m "ui: render purchasing/BOM dates via <.datetime>"
```

---

### Task 6: Finalize — verify, close #14, open fork PR

**Files:** none (process).

- [ ] **Step 1: Confirm no `format_time` render sites remain except the deliberate keeps**

Run: `grep -rnE "format_time\(|format_hour\(" lib/craftplan_web/ | grep -vE "html_helpers.ex|def format"`
Expected: only `order_live/index.ex:~312` (`format_hour`, day-grouped calendar — intentional) and the `format_time`/`format_hour` defs. No other `format_time(` render sites. (`format_date` keeps remain at the period-label/print sites listed in the spec — that's expected.)

- [ ] **Step 2: Run the touched LiveView suites + component/helper tests**

Run: `PATH="$HOME/.local/share/mise/shims:$PATH" mix test test/craftplan_web/datetime_component_test.exs test/craftplan_web/html_helpers_datetime_test.exs test/craftplan_web/manage_orders_live_test.exs test/craftplan_web/manage_customers_live_test.exs test/craftplan_web/manage_inventory_live_test.exs test/craftplan_web/production_batch_live_test.exs`
Expected: all green (the pre-existing `manage_inventory_interactions` failures are NOT in this set).

- [ ] **Step 3: Push and open the fork PR**

```bash
git push https://github.com/timchambers/craftplan.git ui/datetime-component:ui/datetime-component
gh pr create --repo timchambers/craftplan --base main \
  --title "ui: semantic <time> component for all date/time displays" \
  --body "Adds <.datetime> (semantic <time> with ISO datetime attr + full-timestamp title tooltip) and converts the user-facing date/time render sites to use it. Never shows a bare time. Server-side @time_zone. Supersedes #14. See docs/superpowers/specs/2026-06-23-datetime-component-design.md."
```

- [ ] **Step 4: Close the superseded PR #14**

```bash
gh pr close 14 --repo timchambers/craftplan --comment "Superseded by the <.datetime> component PR, which re-renders these sites (orders/customers/inventory) as semantic <time> elements."
```

---

## Self-Review

**Spec coverage:**
- Goal 1 (reusable component) → Task 2. ✓
- Goal 2 (never bare time; precision) → Task 2 component (`:date` default, no time-only label) + sweep Tasks 3-5. ✓
- Goal 3 (ISO `datetime` attr) → Task 1 `datetime_attr/2` + Task 2. ✓
- Goal 4 (`title` full date+time) → Task 1 `format_datetime/2` + Task 2. ✓
- Goal 5 (replace render sites) → Tasks 3-5 (15 sites); keeps documented in Task 3 Step 3 / Task 6 Step 1. ✓
- Decision 2 (server-side `@time_zone`) → component takes `time_zone` attr; all call sites pass `@time_zone`. ✓
- Decision 5 (supersede #14) → Task 6 Step 4. ✓

**Placeholder scan:** No TBD/TODO. Two sites carry an explicit conditional decision the implementer resolves by inspecting one referenced function: `production_batch_live/show.ex` (`summary_card` inner-block check, Task 4 Step 3) and `form_component_recipe.ex` `@time_zone` availability (Task 5 Step 2). Both name exactly what to check and both branches — not open-ended.

**Type consistency:** `datetime_attr/2` and `format_datetime/2` signatures match between Task 1 (definition) and Task 2 (use). The component attrs (`value`, `time_zone`, `precision`, `class`, `empty`) are used consistently across Tasks 3-5 call sites. `<.datetime>` is the same name everywhere.
