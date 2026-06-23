defmodule Craftplan.BottleImportTest do
  use ExUnit.Case, async: false

  alias Craftplan.BottleImport.ApiClient
  alias Mix.Tasks.Bottle.Import, as: ImportTask

  @fixtures Path.expand("../support/bottle_fixtures", __DIR__)
  @price_map Path.join(@fixtures, "price_map.yml")

  defp fixtures_dir, do: @fixtures

  # ---------------------------------------------------------------------------
  # FixtureApi: a stateless Req.Test stub that dispatches on the GraphQL
  # document substring and returns canned responses.
  # ---------------------------------------------------------------------------

  defmodule FixtureApi do
    @moduledoc false

    # The five fixture orders, used in second_pass listOrders response.
    @fixture_orders [
      %{"id" => "o1001", "invoiceNumber" => "BOTTLE-1001", "paymentStatus" => "PAID"},
      %{"id" => "o1002", "invoiceNumber" => "BOTTLE-1002", "paymentStatus" => "PAID"},
      %{"id" => "o1003", "invoiceNumber" => "BOTTLE-1003", "paymentStatus" => "PAID"},
      %{"id" => "o1004", "invoiceNumber" => "BOTTLE-1004", "paymentStatus" => "PAID"},
      %{"id" => "o1005", "invoiceNumber" => "BOTTLE-1005", "paymentStatus" => "PAID"}
    ]

    # ---- first pass: empty DB, all creates succeed ----

    def first_pass(conn) do
      body = conn.body_params
      doc = body["query"] || ""
      dispatch_first(conn, doc)
    end

    # listOrders (idempotency check) – no existing orders
    defp dispatch_first(conn, <<"query", _::binary>> = doc) when is_binary(doc) do
      cond do
        String.contains?(doc, "listOrders") ->
          Req.Test.json(conn, %{
            "data" => %{
              "listOrders" => %{"results" => [], "endKeyset" => nil}
            }
          })

        String.contains?(doc, "listProducts") ->
          Req.Test.json(conn, %{
            "data" => %{"listProducts" => %{"results" => []}}
          })

        String.contains?(doc, "listCustomers") ->
          Req.Test.json(conn, %{
            "data" => %{"listCustomers" => %{"results" => []}}
          })

        true ->
          Req.Test.json(conn, %{"data" => %{}})
      end
    end

    # mutations: createProduct / createCustomer / createOrder / updateOrder
    defp dispatch_first(conn, <<"mutation", _::binary>> = doc) when is_binary(doc) do
      cond do
        String.contains?(doc, "createProduct") ->
          vars = conn.body_params["variables"] || %{}
          input = get_in(vars, ["input"]) || %{}
          sku = input["sku"] || "BOTTLE-PID-X"
          price = input["price"] || "10.00"
          id = "prod-#{sku}"

          Req.Test.json(conn, %{
            "data" => %{
              "createProduct" => %{
                "result" => %{"id" => id, "sku" => sku, "price" => price},
                "errors" => []
              }
            }
          })

        String.contains?(doc, "createCustomer") ->
          vars = conn.body_params["variables"] || %{}
          input = get_in(vars, ["input"]) || %{}
          phone = input["phone"] || "0000000000"
          id = "cust-#{phone}"

          Req.Test.json(conn, %{
            "data" => %{
              "createCustomer" => %{
                "result" => %{"id" => id, "phone" => phone, "email" => input["email"]},
                "errors" => []
              }
            }
          })

        String.contains?(doc, "createOrder") ->
          vars = conn.body_params["variables"] || %{}
          input = get_in(vars, ["input"]) || %{}
          invoice = input["invoiceNumber"] || "BOTTLE-0"
          # strip BOTTLE- prefix to get the Bottle ID for a stable ID
          id = "ord-#{invoice}"

          Req.Test.json(conn, %{
            "data" => %{
              "createOrder" => %{
                "result" => %{"id" => id, "invoiceNumber" => invoice},
                "errors" => []
              }
            }
          })

        String.contains?(doc, "updateOrder") ->
          vars = conn.body_params["variables"] || %{}
          id = vars["id"] || "unknown"

          Req.Test.json(conn, %{
            "data" => %{
              "updateOrder" => %{
                "result" => %{"id" => id, "paymentStatus" => "PAID"},
                "errors" => []
              }
            }
          })

        String.contains?(doc, "updateCustomer") ->
          vars = conn.body_params["variables"] || %{}
          id = vars["id"] || "unknown"

          Req.Test.json(conn, %{
            "data" => %{
              "updateCustomer" => %{
                "result" => %{"id" => id},
                "errors" => []
              }
            }
          })

        true ->
          Req.Test.json(conn, %{"data" => %{}})
      end
    end

    # fallback
    defp dispatch_first(conn, _doc) do
      Req.Test.json(conn, %{"data" => %{}})
    end

    # ---- second pass: all 5 orders already imported and paid ----

    def second_pass(conn) do
      body = conn.body_params
      doc = body["query"] || ""
      dispatch_second(conn, doc)
    end

    defp dispatch_second(conn, <<"query", _::binary>> = doc) do
      cond do
        String.contains?(doc, "listOrders") ->
          Req.Test.json(conn, %{
            "data" => %{
              "listOrders" => %{
                "results" => @fixture_orders,
                "endKeyset" => nil
              }
            }
          })

        # preview listProducts — return something (products exist)
        String.contains?(doc, "listProducts") ->
          vars = conn.body_params["variables"] || %{}
          sku = vars["sku"] || "BOTTLE-PID-X"

          Req.Test.json(conn, %{
            "data" => %{
              "listProducts" => %{
                "results" => [%{"id" => "prod-#{sku}", "sku" => sku, "price" => "10.00"}]
              }
            }
          })

        String.contains?(doc, "listCustomers") ->
          Req.Test.json(conn, %{
            "data" => %{"listCustomers" => %{"results" => []}}
          })

        true ->
          Req.Test.json(conn, %{"data" => %{}})
      end
    end

    defp dispatch_second(conn, <<"mutation", _::binary>> = doc) do
      if String.contains?(doc, "createCustomer") do
        vars = conn.body_params["variables"] || %{}
        input = get_in(vars, ["input"]) || %{}
        phone = input["phone"] || "0000000000"
        id = "cust-#{phone}"

        Req.Test.json(conn, %{
          "data" => %{
            "createCustomer" => %{
              "result" => %{"id" => id, "phone" => phone, "email" => input["email"]},
              "errors" => []
            }
          }
        })
      else
        Req.Test.json(conn, %{"data" => %{}})
      end
    end

    defp dispatch_second(conn, _doc) do
      Req.Test.json(conn, %{"data" => %{}})
    end
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "run_args/1 over the API (orchestration)" do
    setup do
      # Allow stub to be used from Task.async_stream worker processes
      Req.Test.set_req_test_to_shared()
      :ok
    end

    test "imports the fixture run over the API and is idempotent on re-run" do
      # First pass: empty catalog/customers/orders — all creates succeed.
      Req.Test.stub(ApiClient, &FixtureApi.first_pass/1)

      result = ImportTask.run_args([fixtures_dir(), "--yes", "--price-map", @price_map])

      assert result.unknown_pids == []
      assert result.inserted_orders == 5
      assert result.failed_orders == 0

      # Second pass: listOrders returns all 5 as already-imported + paid → all skipped.
      Req.Test.stub(ApiClient, &FixtureApi.second_pass/1)

      result2 = ImportTask.run_args([fixtures_dir(), "--yes", "--price-map", @price_map])

      assert result2.inserted_orders == 0
      assert result2.skipped_orders == 5
    end
  end
end
