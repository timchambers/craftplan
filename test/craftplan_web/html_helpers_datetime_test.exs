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
