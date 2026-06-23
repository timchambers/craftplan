defmodule Craftplan.BottleImport.UpsertsTest do
  use ExUnit.Case, async: true

  alias Craftplan.BottleImport.ApiClient
  alias Craftplan.BottleImport.Upserts

  defp stub_sequence(responses) do
    {:ok, agent} = Agent.start_link(fn -> responses end)

    Req.Test.stub(ApiClient, fn conn ->
      next = Agent.get_and_update(agent, fn [h | t] -> {h, t} end)
      Req.Test.json(conn, next)
    end)
  end

  test "resolve_product returns existing product without creating" do
    stub_sequence([
      %{
        "data" => %{
          "listProducts" => %{
            "results" => [%{"id" => "p1", "sku" => "BOTTLE-PID-1", "price" => "10.00"}]
          }
        }
      }
    ])

    assert {:ok, %{id: "p1", price: %Decimal{}}} =
             Upserts.resolve_product("PID-1", "Loaf", "manufactured", %{})
  end

  test "resolve_product creates from price map when missing" do
    stub_sequence([
      %{"data" => %{"listProducts" => %{"results" => []}}},
      %{
        "data" => %{
          "createProduct" => %{
            "result" => %{"id" => "p2", "sku" => "BOTTLE-PID-2", "price" => "8.50"},
            "errors" => []
          }
        }
      }
    ])

    assert {:ok, %{id: "p2"}} =
             Upserts.resolve_product("PID-2", "Bun", "manufactured", %{
               "PID-2" => Decimal.new("8.50")
             })
  end

  test "resolve_product errors on unknown pid" do
    stub_sequence([%{"data" => %{"listProducts" => %{"results" => []}}}])

    assert {:error, {:unknown_pid, %{pid: "PID-3"}}} =
             Upserts.resolve_product("PID-3", "Mystery", "manufactured", %{})
  end

  test "upsert_customer nils an email already held by a different phone" do
    stub_sequence([
      # email conflict check (resolve_email_conflict called first) -> held by different phone
      %{
        "data" => %{
          "listCustomers" => %{
            "results" => [%{"id" => "cX", "phone" => "+15550000000", "email" => "shared@h.com"}]
          }
        }
      },
      # lookup by phone -> none (called second)
      %{"data" => %{"listCustomers" => %{"results" => []}}},
      # create
      %{"data" => %{"createCustomer" => %{"result" => %{"id" => "c1"}, "errors" => []}}}
    ])

    row = %{
      "Customer Name" => "Jane Doe",
      "Phone" => "(202) 555-1212",
      "Email" => "shared@h.com",
      "Address1" => "1 St",
      "Address2" => "",
      "City" => "DC",
      "State" => "DC",
      "Zip" => "20001"
    }

    assert {:ok, %{id: "c1"}} = Upserts.upsert_customer(row)
  end

  test "upsert_order skips when already imported and paid" do
    assert {:skip, :already_imported} =
             Upserts.upsert_order(
               %{"Bottle ID" => "999"},
               [],
               %{},
               "c1",
               MapSet.new(["BOTTLE-999"]),
               MapSet.new()
             )
  end

  test "upsert_order re-stamps an already-imported but unpaid order" do
    stub_sequence([
      %{
        "data" => %{
          "updateOrder" => %{
            "result" => %{"id" => "o1", "paymentStatus" => "PAID"},
            "errors" => []
          }
        }
      }
    ])

    # NOTE: needs the order id; in this path upsert_order looks it up from the unpaid map.
    assert {:ok, :restamped} =
             Upserts.upsert_order(
               %{"Bottle ID" => "999", "Transaction Date" => "2026-01-10 10:00:00"},
               [],
               %{},
               "c1",
               MapSet.new(["BOTTLE-999"]),
               MapSet.new([%{invoice: "BOTTLE-999", id: "o1"}])
             )
  end
end
