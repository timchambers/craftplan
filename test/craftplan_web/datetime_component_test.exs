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
