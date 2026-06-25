defmodule CraftplanWeb.ManageInventoryEditInteractionsLiveTest do
  use CraftplanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Craftplan.Inventory.Material

  defp create_material!(attrs \\ %{}) do
    defaults = %{
      name: "Mat-#{System.unique_integer()}",
      sku: "MAT-#{System.unique_integer()}",
      price: Decimal.new("1.00"),
      unit: :gram,
      minimum_stock: Decimal.new(0),
      maximum_stock: Decimal.new(0)
    }

    Material
    |> Ash.Changeset.for_create(:create, Map.merge(defaults, attrs))
    |> Ash.create!(actor: Craftplan.DataCase.staff_actor())
  end

  @tag role: :staff
  test "edit material and save", %{conn: conn} do
    m = create_material!()
    {:ok, view, _} = live(conn, ~p"/manage/inventory/#{m.sku}/edit")

    params = %{"material" => %{"name" => m.name <> "X"}}

    view
    |> element("#material-form")
    |> render_submit(params)

    assert_patch(view, ~p"/manage/inventory/#{m.sku}/details")
    assert render(view) =~ "Material updated successfully"
  end

  @tag role: :staff
  test "price input accepts high-precision stored prices (#28)", %{conn: conn} do
    # Materials priced via received lots (e.g. IGF imports) store >3 decimal places.
    m = create_material!(%{price: Decimal.new("0.001137")})
    {:ok, view, _} = live(conn, ~p"/manage/inventory/#{m.sku}/edit")

    price_input = view |> element("#material_price") |> render()

    # The stored value must round-trip into the input...
    assert price_input =~ ~s(value="0.001137")
    # ...and step="0.001" would make the browser reject it and block the whole form.
    assert price_input =~ ~s(step="any")
  end
end
