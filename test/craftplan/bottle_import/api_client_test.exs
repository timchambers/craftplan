defmodule Craftplan.BottleImport.ApiClientTest do
  use ExUnit.Case, async: true

  alias Craftplan.BottleImport.ApiClient

  test "query/2 posts to the graphql endpoint with bearer auth and returns data" do
    Req.Test.stub(ApiClient, fn conn ->
      assert conn.request_path == "/api/graphql"
      assert ["Bearer cpk_test"] = Plug.Conn.get_req_header(conn, "authorization")
      Req.Test.json(conn, %{"data" => %{"listProducts" => %{"results" => []}}})
    end)

    assert {:ok, %{"listProducts" => %{"results" => []}}} =
             ApiClient.query("query { listProducts { results { id } } }", %{})
  end

  test "query/2 surfaces graphql errors" do
    Req.Test.stub(ApiClient, fn conn ->
      Req.Test.json(conn, %{"errors" => [%{"message" => "boom"}]})
    end)

    assert {:error, {:graphql, [%{"message" => "boom"}]}} = ApiClient.query("query { x }", %{})
  end

  test "mutate/3 unwraps result and reports mutation errors" do
    Req.Test.stub(ApiClient, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{"createProduct" => %{"result" => nil, "errors" => [%{"message" => "bad"}]}}
      })
    end)

    assert {:error, {:mutation, [%{"message" => "bad"}]}} =
             ApiClient.mutate(
               "mutation { createProduct { result { id } errors { message } } }",
               %{},
               "createProduct"
             )
  end
end
