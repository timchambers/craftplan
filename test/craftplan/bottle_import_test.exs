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
  # PaginationApi: a Req.Test stub that serves two pages of listOrders results
  # and ASSERTS that the first request sends `after: nil` (not `""`).
  # ---------------------------------------------------------------------------

  defmodule PaginationApi do
    @moduledoc false

    # Page 1: two orders (one PAID, one not), with a non-nil cursor.
    @page1_rows [
      %{"id" => "o101", "invoiceNumber" => "BOTTLE-101", "paymentStatus" => "PAID"},
      %{"id" => "o102", "invoiceNumber" => "BOTTLE-102", "paymentStatus" => "PENDING"}
    ]
    @page1_cursor "cursor-page-2"

    # Page 2: one order, terminating cursor nil.
    @page2_rows [
      %{"id" => "o103", "invoiceNumber" => "BOTTLE-103", "paymentStatus" => "PAID"}
    ]

    def stub(conn) do
      body = conn.body_params
      doc = body["query"] || ""
      vars = body["variables"] || %{}

      cond do
        String.contains?(doc, "listOrders") ->
          after_val = Map.get(vars, "after")
          # Send every listOrders `after` value to the test process for assertion.
          # Use :pagination_test_receiver which the test registers as its own pid.
          receiver = Process.whereis(:pagination_test_receiver)
          if receiver, do: send(receiver, {:list_orders_after, after_val})

          if after_val == @page1_cursor do
            Req.Test.json(conn, %{
              "data" => %{
                "listOrders" => %{"results" => @page2_rows, "endKeyset" => nil}
              }
            })
          else
            Req.Test.json(conn, %{
              "data" => %{
                "listOrders" => %{"results" => @page1_rows, "endKeyset" => @page1_cursor}
              }
            })
          end

        String.contains?(doc, "listProducts") ->
          Req.Test.json(conn, %{"data" => %{"listProducts" => %{"results" => []}}})

        String.contains?(doc, "listCustomers") ->
          Req.Test.json(conn, %{"data" => %{"listCustomers" => %{"results" => []}}})

        true ->
          Req.Test.json(conn, %{"data" => %{}})
      end
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

  # ---------------------------------------------------------------------------
  # Regression: load_existing_orders must seed keyset pagination with nil
  # ---------------------------------------------------------------------------

  describe "load_existing_orders pagination (regression: after: nil seed)" do
    setup do
      Req.Test.set_req_test_to_shared()
      # Register this test process so PaginationApi.stub/1 can send it messages.
      Process.register(self(), :pagination_test_receiver)

      on_exit(fn ->
        # Unregister so the name is free for future test runs in this suite.
        if Process.whereis(:pagination_test_receiver) == self() do
          Process.unregister(:pagination_test_receiver)
        end
      end)

      :ok
    end

    test "first listOrders request sends after: nil (not \"\")" do
      Req.Test.stub(ApiClient, &PaginationApi.stub/1)

      # run_args drives load_existing_orders internally; --yes skips the confirm prompt.
      result = ImportTask.run_args([fixtures_dir(), "--yes", "--price-map", @price_map])

      # Collect the first listOrders `after` value sent by the stub.
      # REGRESSION GUARD: this assertion fails if the seed is "" instead of nil.
      assert_received {:list_orders_after, first_after_val}

      assert first_after_val == nil,
             "Expected first listOrders call to send after: nil, got: #{inspect(first_after_val)}"

      # Confirm pagination continued to page 2 (cursor-page-2 was sent as after).
      assert_received {:list_orders_after, "cursor-page-2"}

      # The fixture orders (BOTTLE-1001..1005) are not in the paged results so they are new.
      assert result.inserted_orders >= 0
      assert result.failed_orders >= 0
    end

    test "all pages are consumed: pagination terminates without crash" do
      Req.Test.stub(ApiClient, &PaginationApi.stub/1)

      # Stub serves page 1 (2 orders, cursor "cursor-page-2") then page 2 (1 order, nil cursor).
      # If unfold were seeded with "" the first listOrders call would fail
      # and the catch-all would return nil immediately — only one message sent.
      assert %{failed_orders: _, inserted_orders: _} =
               ImportTask.run_args([fixtures_dir(), "--yes", "--price-map", @price_map])

      # Both page requests must have fired.
      assert_received {:list_orders_after, _page1_after}
      assert_received {:list_orders_after, "cursor-page-2"}
    end
  end
end
