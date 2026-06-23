defmodule Craftplan.BottleImport.QueriesTest do
  use ExUnit.Case, async: true

  alias Craftplan.BottleImport.Queries

  test "documents reference verified fields" do
    assert Queries.list_product_by_sku() =~ "listProducts(filter: {sku: {eq: $sku}})"
    assert Queries.create_order() =~ "createOrder(input: $input)"
    assert Queries.create_order() =~ "$input: CreateOrderInput!"
    assert Queries.create_order() =~ "result { id invoiceNumber }"
    assert Queries.list_bottle_orders() =~ ~s|invoiceNumber: {like: "BOTTLE-%"}|
    assert Queries.list_bottle_orders() =~ "paymentStatus"
    assert Queries.update_order_paid() =~ "paymentStatus: PAID"
  end
end
