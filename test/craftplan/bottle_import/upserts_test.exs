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

  # Records every GraphQL request body and answers create/update mutations with
  # canned success, so tests can assert on what the importer actually sent.
  defp record_graphql do
    {:ok, recorder} = Agent.start_link(fn -> [] end)

    Req.Test.stub(ApiClient, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      Agent.update(recorder, &[body | &1])
      query = body["query"] || ""

      resp =
        cond do
          String.contains?(query, "createOrder") ->
            %{
              "data" => %{
                "createOrder" => %{
                  "result" => %{"id" => "o1", "invoiceNumber" => "BOTTLE-1"},
                  "errors" => []
                }
              }
            }

          String.contains?(query, "updateOrder") ->
            %{
              "data" => %{
                "updateOrder" => %{
                  "result" => %{"id" => "o1", "paymentStatus" => "PAID"},
                  "errors" => []
                }
              }
            }

          true ->
            %{"data" => %{}}
        end

      Req.Test.json(conn, resp)
    end)

    recorder
  end

  defp requests(recorder), do: recorder |> Agent.get(& &1) |> Enum.reverse()

  defp create_order_input(recorder) do
    recorder
    |> requests()
    |> Enum.find(fn b -> String.contains?(b["query"] || "", "createOrder") end)
    |> get_in(["variables", "input"])
  end

  defp called_update_order?(recorder) do
    Enum.any?(requests(recorder), &String.contains?(&1["query"] || "", "updateOrder"))
  end

  defp order_row(slot_day, payment_status) do
    %{
      "Bottle ID" => "1",
      "Transaction Date" => "2026-01-10 10:00:00",
      "Fulfillment Slot Day" => slot_day,
      "Fulfillment Slot Time" => "1/1 05:00AM - 1/1 12:00PM",
      "Fulfillment Method" => "Delivery",
      "Payment Status" => payment_status
    }
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
               %{
                 "Bottle ID" => "999",
                 "Transaction Date" => "2026-01-10 10:00:00",
                 "Payment Status" => "Paid"
               },
               [],
               %{},
               "c1",
               MapSet.new(["BOTTLE-999"]),
               MapSet.new([%{invoice: "BOTTLE-999", id: "o1"}])
             )
  end

  test "upsert_order creates a future-dated order as unconfirmed" do
    recorder = record_graphql()

    assert {:ok, :created} =
             Upserts.upsert_order(
               order_row("2099-01-01", "Paid"),
               [],
               %{},
               "c1",
               MapSet.new(),
               MapSet.new()
             )

    assert create_order_input(recorder)["status"] == "unconfirmed"
  end

  test "upsert_order creates a past-dated order as completed" do
    recorder = record_graphql()

    assert {:ok, :created} =
             Upserts.upsert_order(
               order_row("2020-01-01", "Paid"),
               [],
               %{},
               "c1",
               MapSet.new(),
               MapSet.new()
             )

    assert create_order_input(recorder)["status"] == "completed"
  end

  test "upsert_order stamps the order paid when Payment Status is Paid" do
    recorder = record_graphql()

    assert {:ok, :created} =
             Upserts.upsert_order(
               order_row("2020-01-01", "Paid"),
               [],
               %{},
               "c1",
               MapSet.new(),
               MapSet.new()
             )

    assert called_update_order?(recorder)
  end

  test "upsert_order leaves payment pending when Payment Status is not Paid" do
    recorder = record_graphql()

    assert {:ok, :created} =
             Upserts.upsert_order(
               order_row("2020-01-01", "Unpaid"),
               [],
               %{},
               "c1",
               MapSet.new(),
               MapSet.new()
             )

    refute called_update_order?(recorder)
  end

  test "upsert_order does not re-stamp an existing unpaid order when the sheet is not Paid" do
    recorder = record_graphql()

    row =
      "2020-01-01"
      |> order_row("Unpaid")
      |> Map.put("Bottle ID", "999")

    assert {:skip, :already_imported} =
             Upserts.upsert_order(
               row,
               [],
               %{},
               "c1",
               MapSet.new(["BOTTLE-999"]),
               MapSet.new([%{invoice: "BOTTLE-999", id: "o1"}])
             )

    refute called_update_order?(recorder)
  end
end
