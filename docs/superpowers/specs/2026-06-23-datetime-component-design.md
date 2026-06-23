# Semantic `<time>` component for all date/time displays — Design

**Status:** Draft for review
**Date:** 2026-06-23
**Author/Driver:** Tim Chambers (with Claude)

## 1. Problem

Across Craftplan's web UI, point-in-time values are rendered inconsistently: some via `format_date/2` (date only), many via `format_time/2` (a bare time like `05:00 AM` with **no date**). A bare time is useless for any event older than ~12 hours, and there's no machine-readable timestamp or hover affordance for the full value. PRs #9 (POs) and #14 (orders/customers/inventory) swapped specific `format_time` columns to `format_date`, but that's piecemeal and still loses the underlying timestamp.

## 2. Goals

1. A single reusable component for rendering any date/time value.
2. **Never display a bare time** — always at least a date; optionally date + time.
3. Emit a semantic, accessible `<time>` element with a machine-readable `datetime` attribute (ISO 8601).
4. Reveal the full localized date **+ time** on hover (the `title` attribute).
5. Replace the scattered `format_date`/`format_time`/`format_hour` render sites with the component.

## 3. Key decisions (resolved during brainstorming)

| # | Decision | Choice |
|---|---|---|
| 1 | Visible text | **Per-call `precision`**, default **date-only**; callers opt into date + time. |
| 2 | Timezone resolution | **Server-side `@time_zone`** (the existing browser-tz-via-cookie value), matching the rest of the app. No new JS. |
| 3 | Machine-readable value | `datetime` attribute = canonical ISO 8601 of the instant. |
| 4 | Full value affordance | `title` attribute = full localized date + time (browser tooltip on hover). |
| 5 | Relationship to #14 | This **supersedes** #14 (it re-renders the same sites). Recommend closing #14 unmerged; #13 (nil-address crash) is unrelated and stays. |

## 4. Timezone context (why decision 2 is consistent)

Craftplan has **no timezone preference field**. The browser tz is detected client-side (`Intl.DateTimeFormat().resolvedOptions().timeZone`, `assets/js/app.js`), written to a `timezone` cookie, copied to `session["timezone"]` by the `put_session_timezone` router plug, and assigned as `@time_zone` in `LiveSettings.on_mount`. So `@time_zone` already **is** the viewer's browser timezone. Known limitation (inherited, not introduced here): the very first request before the cookie is set has `@time_zone == nil` and renders in UTC until a reload.

## 5. Component design

A function component in `lib/craftplan_web/components/core.ex`:

```elixir
attr :value, :any, required: true, doc: "Date, NaiveDateTime, or DateTime (nil renders the empty placeholder)"
attr :time_zone, :string, default: nil, doc: "IANA tz; pass @time_zone"
attr :precision, :atom, default: :date, values: [:date, :datetime]
attr :class, :string, default: nil
attr :empty, :string, default: "—"
def datetime(assigns)
```

Rendered output (precision `:date`):

```html
<time datetime="2026-01-13T05:00:00Z" title="January 13, 2026 at 5:00 AM EST">Jan 13, 2026</time>
```

- **Visible text** — `:date` → `format_date(value, format: :medium, timezone: tz)` (e.g. `Jan 13, 2026`). `:datetime` → medium date + `format_time(value, timezone: tz)` (e.g. `Jan 13, 2026, 5:00 AM`).
- **`datetime` attr** — canonical ISO 8601 of the instant. `DateTime`/`NaiveDateTime` → full ISO 8601 (UTC, `…Z`); `Date` → `YYYY-MM-DD`. Independent of the display tz so it's unambiguous.
- **`title` attr** — full localized date + time in `tz` (e.g. `January 13, 2026 at 5:00 AM EST`). For a bare `Date` (no time component), the title is the long date only.
- **`nil` value** — render the `empty` placeholder as plain text (no `<time>` tag), matching today's `format_*` "" / "—" behavior.
- **Usage:** `<.datetime value={@order.delivery_date} time_zone={@time_zone} />`, or `precision={:datetime}` where the time matters.

**Component name:** `<.datetime>` (open to `<.local_time>` — confirm at spec review).

### Supporting helpers (in `html_helpers.ex`)

The component composes existing helpers plus two small additions:
- `datetime_attr(value, tz)` → ISO 8601 string for the `datetime` attribute.
- `format_datetime(value, tz)` → the full "date at time TZ" string used for the `title` (and reusable for `precision: :datetime` visible text).

These keep formatting centralized and unit-testable.

## 6. Scope — the sweep

Replace the **27 user-facing date/time render sites across 13 files** (`format_date`/`format_time`/`format_hour`) with `<.datetime>`, choosing `precision` per site (default `:date`; `:datetime` only where the time genuinely matters, e.g. recent-activity views — decided per site in the plan). The `format_time` "Created at" / "Produced At" / "Delivery time" sites kept in #14 become `<.datetime>` too, resolving "never just time" everywhere.

**Evaluated case-by-case; likely kept as-is** (not single-instant events, so `<time>` doesn't apply cleanly):
- **Period / navigation labels** — e.g. the orders calendar header `format_date(List.first(@days_range), format: "%B %Y")` (a month label, not an event).
- **Print-only contexts** — product label, order invoice — where hover/interactivity is meaningless; may still adopt the component for uniformity at the implementer's discretion, but no `title` benefit.

The implementation plan will enumerate all 27 sites with an explicit **convert / keep** decision and the chosen `precision` for each.

## 7. Testing

- **Component unit test** (`test/craftplan_web/components/...`): renders `<.datetime>` and asserts the `<time>` tag, the `datetime` attr (ISO 8601), the `title` attr (full localized date+time), `:date` vs `:datetime` visible text, timezone shifting, and `nil` → `empty` placeholder.
- **Helper unit tests** for `datetime_attr/2` and `format_datetime/2`.
- **Regression:** the touched LiveView suites must still pass. The 3 pre-existing failures in `manage_inventory_interactions_live_test.exs` ("adjust stock") fail on `main` independently of this change and are out of scope.

## 8. Out of scope (YAGNI)

- **Client-side dynamic tz / JS hook** — rejected in favor of server-side `@time_zone` (decision 2).
- **Relative time** ("2 hours ago").
- **A timezone preference UI** (Settings/User field) — the browser-tz mechanism stays as-is.
- **Fixing the first-uncookied-load UTC gap** — pre-existing app behavior, not introduced or addressed here.

## 9. Delivery

One PR to the fork (`origin`, `timchambers/craftplan`), never upstream: the `<.datetime>` component + helpers + the full sweep. Supersedes #14 (close it). The implementation plan follows.
