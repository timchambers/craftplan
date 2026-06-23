defmodule CraftplanWeb.Api.BottleImportIntegrationTest do
  @moduledoc """
  Integration tests that run every GraphQL document from
  `Craftplan.BottleImport.Queries` against the REAL schema.

  These tests use no Req.Test stubs — they POST to /api/graphql over HTTP
  via the Phoenix ConnCase test adapter, exercising the full Ash/AshGraphql
  stack including policies and input coercions.

  If the schema rejects any document or encoding the test will fail with a
  descriptive assertion message rather than silently passing. That constitutes
  a BLOCKED finding that must be fixed in Queries/Upserts before shipping.
  """

  use CraftplanWeb.ConnCase, async: true

  alias Craftplan.Accounts
  alias Craftplan.BottleImport.Queries

  # ---------------------------------------------------------------------------
  # Helpers copied from graphql_test.exs
  # ---------------------------------------------------------------------------

  defp create_api_key!(scopes) do
    admin = Craftplan.DataCase.admin_actor()

    {:ok, api_key} =
      Accounts.create_api_key(%{name: "bottle-integ-key", scopes: scopes}, actor: admin)

    {Map.get(api_key, :__raw_key__), api_key, admin}
  end

  defp graphql(conn, raw_key, query, variables \\ %{}) do
    conn
    |> put_req_header("authorization", "Bearer #{raw_key}")
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", Jason.encode!(%{"query" => query, "variables" => variables}))
    |> json_response(200)
  end

  # ---------------------------------------------------------------------------
  # The integration test
  # ---------------------------------------------------------------------------

  describe "Bottle importer documents" do
    test "execute against the real schema end-to-end", %{conn: conn} do
      {raw_key, _api_key, _admin} =
        create_api_key!(%{
          "products" => ["read", "create"],
          "customers" => ["read", "create"],
          "orders" => ["read", "create", "update"],
          "order_items" => ["read", "create", "update"]
        })

      # ------------------------------------------------------------------
      # Step 1: createProduct with lowercase String encodings for status
      #         and sellingAvailability
      # ------------------------------------------------------------------

      product_input = %{
        "sku" => "BOTTLE-PID-INTEG",
        "name" => "Integ Loaf",
        "price" => "10.00",
        "status" => "active",
        "sellingAvailability" => "available"
      }

      product_resp =
        graphql(conn, raw_key, Queries.create_product(), %{"input" => product_input})

      assert is_nil(product_resp["errors"]),
             "createProduct returned top-level GraphQL errors: #{inspect(product_resp["errors"])}"

      product_payload_errors = get_in(product_resp, ["data", "createProduct", "errors"])

      assert product_payload_errors == [],
             "createProduct mutation returned payload errors: #{inspect(product_payload_errors)}"

      product_id = get_in(product_resp, ["data", "createProduct", "result", "id"])

      assert is_binary(product_id) and byte_size(product_id) > 0,
             "createProduct did not return an id; result: #{inspect(get_in(product_resp, ["data", "createProduct", "result"]))}"

      # ------------------------------------------------------------------
      # Step 2: createCustomer with lowercase "individual" type
      # ------------------------------------------------------------------

      customer_input = %{
        "type" => "individual",
        "firstName" => "Integ",
        "lastName" => "Buyer",
        "email" => "integ@example.com",
        "phone" => "+12025550199",
        "shippingAddress" =>
          Jason.encode!(%{
            "street" => "1 Test St",
            "city" => "DC",
            "state" => "DC",
            "zip" => "20001",
            "country" => "US"
          })
      }

      customer_resp =
        graphql(conn, raw_key, Queries.create_customer(), %{"input" => customer_input})

      assert is_nil(customer_resp["errors"]),
             "createCustomer returned top-level GraphQL errors: #{inspect(customer_resp["errors"])}"

      customer_payload_errors = get_in(customer_resp, ["data", "createCustomer", "errors"])

      assert customer_payload_errors == [],
             "createCustomer mutation returned payload errors: #{inspect(customer_payload_errors)}"

      customer_id = get_in(customer_resp, ["data", "createCustomer", "result", "id"])

      assert is_binary(customer_id) and byte_size(customer_id) > 0,
             "createCustomer did not return an id; result: #{inspect(get_in(customer_resp, ["data", "createCustomer", "result"]))}"

      # ------------------------------------------------------------------
      # Step 3: createOrder — the critical assertion that lowercase String
      #         encodings for status, paymentMethod, deliveryMethod AND the
      #         nested `items` input are all accepted.
      # ------------------------------------------------------------------

      order_input = %{
        "customerId" => customer_id,
        "deliveryDate" => "2026-01-15T12:00:00Z",
        "deliveryMethod" => "delivery",
        "invoiceNumber" => "BOTTLE-INTEG-1",
        "status" => "completed",
        "paymentMethod" => "card",
        "items" => [
          %{
            "productId" => product_id,
            "quantity" => "2",
            "unitPrice" => "10.00"
          }
        ]
      }

      order_resp = graphql(conn, raw_key, Queries.create_order(), %{"input" => order_input})

      assert is_nil(order_resp["errors"]),
             "createOrder returned top-level GraphQL errors: #{inspect(order_resp["errors"])}"

      order_payload_errors = get_in(order_resp, ["data", "createOrder", "errors"])

      assert order_payload_errors == [],
             "createOrder mutation returned payload errors (this is the critical assertion — " <>
               "lowercase String encodings for status/paymentMethod/deliveryMethod and nested items " <>
               "must be accepted): #{inspect(order_payload_errors)}"

      order_id = get_in(order_resp, ["data", "createOrder", "result", "id"])

      assert is_binary(order_id) and byte_size(order_id) > 0,
             "createOrder did not return an id; result: #{inspect(get_in(order_resp, ["data", "createOrder", "result"]))}"

      assert get_in(order_resp, ["data", "createOrder", "result", "invoiceNumber"]) ==
               "BOTTLE-INTEG-1",
             "createOrder did not echo back the invoiceNumber"

      # ------------------------------------------------------------------
      # Step 4: update_order_paid — uses the PAID GraphQL enum literal
      # ------------------------------------------------------------------

      paid_resp =
        graphql(conn, raw_key, Queries.update_order_paid(), %{
          "id" => order_id,
          "paidAt" => "2026-01-15T12:00:00Z"
        })

      assert is_nil(paid_resp["errors"]),
             "updateOrder(PAID) returned top-level GraphQL errors: #{inspect(paid_resp["errors"])}"

      paid_payload_errors = get_in(paid_resp, ["data", "updateOrder", "errors"])

      assert paid_payload_errors == [],
             "updateOrder(PAID) mutation returned payload errors: #{inspect(paid_payload_errors)}"

      assert get_in(paid_resp, ["data", "updateOrder", "result", "paymentStatus"]) == "PAID",
             "updateOrder did not set paymentStatus to PAID; got: #{inspect(get_in(paid_resp, ["data", "updateOrder", "result", "paymentStatus"]))}"

      # ------------------------------------------------------------------
      # Step 5: list_bottle_orders — uses $after keyset pagination variable
      # ------------------------------------------------------------------

      list_resp =
        graphql(conn, raw_key, Queries.list_bottle_orders(), %{"after" => nil})

      assert is_nil(list_resp["errors"]),
             "list_bottle_orders returned top-level GraphQL errors: #{inspect(list_resp["errors"])}"

      results = get_in(list_resp, ["data", "listOrders", "results"])

      assert is_list(results),
             "list_bottle_orders did not return a results list; data: #{inspect(list_resp["data"])}"

      assert Enum.any?(results, &(&1["invoiceNumber"] == "BOTTLE-INTEG-1")),
             "BOTTLE-INTEG-1 not found in list_bottle_orders results: #{inspect(Enum.map(results, & &1["invoiceNumber"]))}"

      paid_order = Enum.find(results, &(&1["invoiceNumber"] == "BOTTLE-INTEG-1"))

      assert paid_order["paymentStatus"] == "PAID",
             "BOTTLE-INTEG-1 paymentStatus should be PAID, got: #{inspect(paid_order["paymentStatus"])}"

      # ------------------------------------------------------------------
      # Step 6: list_product_by_sku — smoke-test the query document
      # ------------------------------------------------------------------

      sku_resp =
        graphql(conn, raw_key, Queries.list_product_by_sku(), %{"sku" => "BOTTLE-PID-INTEG"})

      assert is_nil(sku_resp["errors"]),
             "list_product_by_sku returned top-level GraphQL errors: #{inspect(sku_resp["errors"])}"

      sku_results = get_in(sku_resp, ["data", "listProducts", "results"])

      assert [%{"id" => ^product_id}] = sku_results,
             "list_product_by_sku did not return the created product; results: #{inspect(sku_results)}"
    end
  end
end
