# Reorder Planner Async Metrics Load — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the ~2s `owner_grid_rows/3` computation off the synchronous `mount/3` of `CraftplanWeb.InventoryLive.ReorderPlanner` so the page mounts instantly (WebSocket join succeeds, no reload loop) and metrics load asynchronously behind the existing spinner.

**Architecture:** Phoenix LiveView 1.1 `start_async/3` + `handle_async/3` + `cancel_async/2`. Mount kicks off the compute only when `connected?(socket)`; results arrive via `handle_async`. Control toggles recompute the same async way.

**Tech Stack:** Elixir, Phoenix LiveView 1.1, Ash, ExUnit + `Phoenix.LiveViewTest` (`render_async/1`).

## Global Constraints

- Run `mix format <file>` **scoped to changed files only** before every commit. NEVER run a bare repo-wide `mix format` (it reformats unrelated pre-existing files).
- All mix/elixir commands MUST be prefixed: `export PATH="$HOME/.local/share/mise/shims:$PATH"` (mise shims; otherwise Hex/mix crash).
- Commit style: `type(scope): description` (e.g. `perf(inventory):`).
- Only touch `lib/craftplan_web/live/manage/inventory_live/reorder.ex` and a new test file `test/craftplan_web/manage_inventory_reorder_live_test.exs`. Do NOT change `InventoryForecasting`, the `:owner_grid_metrics` action, or any resource.
- Do NOT run the full `mix test` suite (documented pre-existing failures, including 3 "adjust stock" failures in inventory). Run only the focused files named per task.
- Preserve existing behavior: the `horizon <= 0` no-op guard, the error → `forecast_error` path, all normalization/preference helpers.

---

## File Structure

- Modify: `lib/craftplan_web/live/manage/inventory_live/reorder.ex` — convert metrics loading from sync to async.
- Create: `test/craftplan_web/manage_inventory_reorder_live_test.exs` — async load + toggle tests.

Current relevant code (in `reorder.ex`):
- `mount/3` (≈258) ends with `{:ok, load_metrics(socket)}`.
- `load_metrics/1` (≈419) — synchronous; has a `horizon <= 0` guard clause and a `rescue` that sets `forecast_error`.
- `refresh_metrics/2` (≈413) — `assign(assigns) |> load_metrics()`.
- Toggle handlers: `set_service_level`/`set_horizon` call `refresh_metrics/2`; `update_advanced`/`reset_advanced` call `load_metrics/1`.
- `build_days_range/2` (≈457) stays as-is.

---

## Task 1: Async mount load (start_async + connected? guard)

**Files:**
- Modify: `lib/craftplan_web/live/manage/inventory_live/reorder.ex` (`mount/3`, add `maybe_start_metrics/1`, `start_metrics_load/1`, `handle_async/3`)
- Test: `test/craftplan_web/manage_inventory_reorder_live_test.exs`

**Interfaces:**
- Produces:
  - `maybe_start_metrics(socket) :: socket` (private) — `start_metrics_load/1` if `connected?`, else socket unchanged.
  - `start_metrics_load(socket) :: socket` (private) — assigns `metrics_loaded?: false`, cancels in-flight `:forecast_metrics`, `start_async(:forecast_metrics, fn -> rows end)`. Keeps the `horizon <= 0` no-op guard.
  - `handle_async(:forecast_metrics, {:ok, rows} | {:exit, reason}, socket)`.
- Leaves `load_metrics/1`, `refresh_metrics/2`, and the toggle handlers UNCHANGED for now (Task 2 migrates them). `load_metrics/1` and `start_metrics_load/1` coexist this task.

- [ ] **Step 1: Write the failing test**

Create `test/craftplan_web/manage_inventory_reorder_live_test.exs`:

```elixir
defmodule CraftplanWeb.ManageInventoryReorderLiveTest do
  # async: false + shared sandbox — the page computes metrics in a start_async
  # task; shared mode guarantees that task can reach the test's DB connection.
  use CraftplanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Craftplan.Repo, {:shared, self()})
    :ok
  end

  describe "async metrics load" do
    @tag role: :staff
    test "mount returns immediately with the loading state, then resolves async", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/manage/inventory/forecast/reorder")

      # Mount did NOT block on the ~2s computation: spinner is shown.
      assert html =~ "Loading inventory metrics"

      # Awaiting the async assign clears the spinner and renders the band
      # (empty state is fine with no seeded data).
      resolved = render_async(view)
      refute resolved =~ "Loading inventory metrics"
      assert resolved =~ "No forecast rows available" or resolved =~ "owner-metrics-band"
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `export PATH="$HOME/.local/share/mise/shims:$PATH"; mix test test/craftplan_web/manage_inventory_reorder_live_test.exs`
Expected: FAIL — currently mount blocks and resolves synchronously, so the initial `html` does NOT contain "Loading inventory metrics" (it already shows the band). The first assertion fails.

(If instead it errors on sandbox access from the async task, that confirms the sandbox risk — the `{:shared, self()}` setup above should prevent it; keep it.)

- [ ] **Step 3: Add the async helpers and handle_async**

In `reorder.ex`, add (near `load_metrics/1`):

```elixir
defp maybe_start_metrics(socket) do
  if connected?(socket), do: start_metrics_load(socket), else: socket
end

defp start_metrics_load(%{assigns: %{horizon_days: horizon}} = socket) when horizon <= 0 do
  socket
end

defp start_metrics_load(socket) do
  days_range = build_days_range(socket.assigns.today, socket.assigns.horizon_days)
  actor = socket.assigns[:current_user]

  opts = [
    service_level: socket.assigns.service_level,
    lookback_days: socket.assigns.lookback_days,
    actual_weight: socket.assigns.actual_weight,
    planned_weight: socket.assigns.planned_weight,
    min_samples: socket.assigns.min_samples
  ]

  socket
  |> assign(:metrics_loaded?, false)
  |> assign(:forecast_error, nil)
  |> assign(:days_range, days_range)
  |> cancel_async(:forecast_metrics)
  |> start_async(:forecast_metrics, fn ->
    InventoryForecasting.owner_grid_rows(days_range, opts, actor)
  end)
end

@impl true
def handle_async(:forecast_metrics, {:ok, rows}, socket) do
  {:noreply,
   socket
   |> assign(:forecast_rows, rows)
   |> assign(:metrics_loaded?, true)
   |> assign(:forecast_error, nil)}
end

def handle_async(:forecast_metrics, {:exit, reason}, socket) do
  Logger.error("Unable to load owner forecast metrics: #{inspect(reason)}")

  {:noreply,
   socket
   |> assign(:forecast_rows, [])
   |> assign(:metrics_loaded?, false)
   |> assign(:forecast_error, "Unable to load forecast metrics right now.")}
end
```

Note: `cancel_async/2` is a no-op when no async is running under that name (safe on first call). If the installed LiveView version raises instead, guard it (only cancel in Task 2's toggle path); verify during this step.

- [ ] **Step 4: Wire mount to the async path**

In `mount/3`, change the final line from `{:ok, load_metrics(socket)}` to:

```elixir
{:ok, maybe_start_metrics(socket)}
```

Leave everything else in `mount/3` unchanged.

- [ ] **Step 5: Run test to verify it passes**

Run: `export PATH="$HOME/.local/share/mise/shims:$PATH"; mix test test/craftplan_web/manage_inventory_reorder_live_test.exs`
Expected: PASS — initial html shows the spinner; `render_async` resolves to the band/empty state.

- [ ] **Step 6: Format and commit**

```bash
export PATH="$HOME/.local/share/mise/shims:$PATH"
mix format lib/craftplan_web/live/manage/inventory_live/reorder.ex test/craftplan_web/manage_inventory_reorder_live_test.exs
git add lib/craftplan_web/live/manage/inventory_live/reorder.ex test/craftplan_web/manage_inventory_reorder_live_test.exs
git commit -m "perf(inventory): load reorder forecast metrics async on mount"
```

---

## Task 2: Async control toggles + remove synchronous path

**Files:**
- Modify: `lib/craftplan_web/live/manage/inventory_live/reorder.ex` (`refresh_metrics/2`, `update_advanced`, `reset_advanced`; delete `load_metrics/1`)
- Test: `test/craftplan_web/manage_inventory_reorder_live_test.exs`

**Interfaces:**
- Consumes: `start_metrics_load/1` (Task 1).
- `refresh_metrics/2` now ends in `start_metrics_load/1`; `update_advanced`/`reset_advanced` call `start_metrics_load/1`. `load_metrics/1` is deleted (no remaining callers).

- [ ] **Step 1: Write the failing test**

Add to the `"async metrics load"` describe block:

```elixir
    @tag role: :staff
    test "changing the horizon recomputes asynchronously (no blocking)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/manage/inventory/forecast/reorder")
      render_async(view)

      clicked =
        view
        |> element("button[phx-click=set_horizon][phx-value-days=28]")
        |> render_click()

      # The toggle handler returned without blocking on the recompute:
      # the spinner is shown again.
      assert clicked =~ "Loading inventory metrics"

      resolved = render_async(view)
      refute resolved =~ "Loading inventory metrics"
    end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `export PATH="$HOME/.local/share/mise/shims:$PATH"; mix test test/craftplan_web/manage_inventory_reorder_live_test.exs`
Expected: FAIL — `set_horizon` still calls `refresh_metrics/2` → synchronous `load_metrics/1`, which resolves before returning, so `clicked` shows the band, not the spinner.

- [ ] **Step 3: Migrate refresh_metrics and the advanced handlers to async**

In `reorder.ex`:

Change `refresh_metrics/2`:

```elixir
defp refresh_metrics(socket, assigns) do
  socket
  |> assign(assigns)
  |> start_metrics_load()
end
```

In `handle_event("update_advanced", ...)` and `handle_event("reset_advanced", ...)`, change the final `load_metrics(socket)` call to `start_metrics_load(socket)`. (Both currently end with `{:noreply, load_metrics(socket)}` / build a socket then `load_metrics`.)

- [ ] **Step 4: Delete the now-unused synchronous load_metrics/1**

Remove both `load_metrics/1` clauses (the `horizon <= 0` guard clause and the main clause with its `rescue`). Confirm no remaining references:

Run: `export PATH="$HOME/.local/share/mise/shims:$PATH"; grep -n "load_metrics" lib/craftplan_web/live/manage/inventory_live/reorder.ex`
Expected: no matches (only `start_metrics_load` remains).

- [ ] **Step 5: Run tests + clean compile**

```bash
export PATH="$HOME/.local/share/mise/shims:$PATH"
mix test test/craftplan_web/manage_inventory_reorder_live_test.exs
mix compile --force --warnings-as-errors
```
Expected: both reorder tests PASS; compile clean (the only acceptable noise is the pre-existing unrelated state — there should be no warnings from `reorder.ex`).

- [ ] **Step 6: Regression check — forecast nav + inventory suites**

Run: `export PATH="$HOME/.local/share/mise/shims:$PATH"; mix test test/craftplan_web/manage_inventory_forecast_nav_live_test.exs`
Expected: PASS (this exercises navigation to the reorder/forecast pages). Report results; if any failure appears, confirm whether it also fails on `origin/main` (pre-existing) before treating it as a regression.

- [ ] **Step 7: Format and commit**

```bash
export PATH="$HOME/.local/share/mise/shims:$PATH"
mix format lib/craftplan_web/live/manage/inventory_live/reorder.ex test/craftplan_web/manage_inventory_reorder_live_test.exs
git add lib/craftplan_web/live/manage/inventory_live/reorder.ex test/craftplan_web/manage_inventory_reorder_live_test.exs
git commit -m "perf(inventory): recompute reorder metrics async on control changes"
```

---

## Self-Review notes

- **Spec coverage:** connected? guard + async mount (Task 1), handle_async success/exit (Task 1), async toggles + cancel_async (Tasks 1-2), no UI change, `load_metrics/1` removed (Task 2). Tests cover async-mount-doesn't-block and toggle-doesn't-block.
- **Type consistency:** `start_metrics_load/1`, `maybe_start_metrics/1`, `handle_async(:forecast_metrics, ...)` used consistently across both tasks. `load_metrics/1` fully removed by end of Task 2.
- **Known risk:** sandbox access from the `start_async` task — handled by `{:shared, self()}` + `async: false` in the test module.
- **Out of scope:** the ~2s computation cost itself; other forecast consumers.
