defmodule CraftplanWeb.ManageSettingsInteractionsLiveTest do
  use CraftplanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @tag role: :admin
  test "general settings can be saved", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/manage/settings/general")

    params = %{"settings" => %{"tax_rate" => "0.05"}}

    view
    |> element("#settings-form")
    |> render_submit(params)

    assert render(view) =~ "Settings updated successfully"
  end

  @tag role: :admin
  test "general settings expose labor rate and overhead fields (#22)", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/manage/settings/general")

    assert html =~ ~s(name="settings[labor_hourly_rate]")
    assert html =~ ~s(name="settings[labor_overhead_percent]")
  end

  @tag role: :admin
  test "labor rate and overhead can be edited from settings (#22)", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/manage/settings/general")

    view
    |> element("#settings-form")
    |> render_submit(%{
      "settings" => %{"labor_hourly_rate" => "25.5", "labor_overhead_percent" => "0.15"}
    })

    assert render(view) =~ "Settings updated successfully"

    settings = Craftplan.Settings.get_settings!()
    assert Decimal.equal?(settings.labor_hourly_rate, Decimal.new("25.5"))
    assert Decimal.equal?(settings.labor_overhead_percent, Decimal.new("0.15"))
  end

  @tag role: :admin
  test "add and delete allergen in settings", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/manage/settings/allergens")

    view
    |> element("button[phx-click=show_add_modal]")
    |> render_click()

    name = "Allergen-#{System.unique_integer()}"

    view
    |> element("#allergen-form")
    |> render_submit(%{"allergen" => %{"name" => name}})

    assert render(view) =~ name

    # Optional: delete interactions are covered elsewhere; keep add-only here
  end

  @tag role: :admin
  test "add and delete nutritional fact in settings", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/manage/settings/nutritional_facts")

    view
    |> element("button[phx-click=show_modal]")
    |> render_click()

    name = "NF-#{System.unique_integer()}"

    view
    |> element("#nutritional-fact-form")
    |> render_submit(%{"nutritional_fact" => %{"name" => name}})

    assert render(view) =~ name

    # Optional: delete interactions are covered elsewhere; keep add-only here
  end
end
