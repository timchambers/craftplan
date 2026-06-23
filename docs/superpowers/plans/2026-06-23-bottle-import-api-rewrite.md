# Bottle Importer GraphQL/API Rewrite — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `mix bottle.import` write to Craftplan over the GraphQL API (any instance via `CRAFTPLAN_API_URL`) instead of the local Repo, so imports can target production.

**Architecture:** Two phases / two PRs. **PR1** exposes the Order/Product GraphQL fields the importer must read, filter, and write. **PR2** replaces Stage 2's Ash/Repo write backend with a `Req`-based GraphQL client, keeping the `extract.py` Stage 1, the parser modules, and the CLI/preview/audit shell unchanged.

**Tech Stack:** Elixir, Ash 3, AshGraphql/Absinthe, `Req` (dev/test dep), `NimbleCSV`, ExUnit, `Req.Test`.

## Global Constraints

- Elixir 1.18.3 / OTP 27 — run `mix` via the mise shims (`PATH="$HOME/.local/share/mise/shims:$PATH"`), never Homebrew's Elixir.
- **All PRs target the fork `origin` (`timchambers/craftplan`), never `upstream` (`puemos/craftplan`).** Use `gh pr create --repo timchambers/craftplan`.
- Commit style: `type(scope): description` (e.g. `feat(bottle-import):`, `feat(orders):`).
- `Req` is `only: [:dev, :test]` — the importer runs locally as a client; do not add `Req` to prod deps.
- Preserve all parsing behavior in `NameParser`, `PhoneNormalizer`, `SlotTimeParser` — do not modify them.
- GraphQL endpoint: `POST {CRAFTPLAN_API_URL}/api/graphql`, header `Authorization: Bearer {CRAFTPLAN_API_KEY}`.
- AshGraphql mutation payloads are `{ result {…}, errors { message shortMessage code fields vars } }`. List queries return `KeysetPageOf<T>` with a `results` field.
- GraphQL enum literals are UPPER_CASE: `status: ACTIVE`, `sellingAvailability: AVAILABLE | OFF`, `paymentMethod: CARD`, `paymentStatus: PAID`, `deliveryMethod: DELIVERY | PICKUP`.

## Verified schema facts (current, pre-PR1)

- `CreateProductInput`: `sku, name, price, status, sellingAvailability, photos, featuredPhoto, maxDailyQuantity`.
- `CreateCustomerInput`: `type, firstName, lastName, email, phone, shippingAddress, billingAddress`.
- `CreateOrderInput`: `customerId, deliveryDate, deliveryMethod, invoiceNumber, invoiceStatus, invoicedAt, paymentMethod, status, discountType, discountValue, items`.
- `UpdateOrderInput`: same as create + `taxTotal, shippingTotal, discountTotal` (NO `paymentStatus`/`paidAt` yet).
- `items` element type `OrderCreateItemsInput`: `productId, quantity, unitPrice` (+ cost fields, unused).
- Filters: `ProductFilterInput` has NO `sku`; `OrderFilterInput` has only `and, id, not, or`; `CustomerFilterInput` has `phone, email` ✓. String filter ops include `eq, like, ilike, in`.
- Type read fields: `Order` → `id` only; `Product` → no `sku`; `Customer` → `phone, email, …` ✓.

---

# PHASE 1 / PR1 — GraphQL field exposure (`feat(orders)/(catalog)`)

> Deliverable: a deployable resource change. After deploy, the importer can resolve products by SKU, dedupe orders by invoice number, and stamp orders paid — all over GraphQL. PR1 has no dependency on PR2.

### Task 1: Expose `Product.sku` for read + filter

**Files:**
- Modify: `lib/craftplan/catalog/product.ex` (the `attribute :sku` block, ~line 130)
- Test: `test/craftplan_web/api/graphql_test.exs`

**Interfaces:**
- Produces: `listProducts(filter: {sku: {eq: String}})` returns matching products; `Product.sku` readable.

- [ ] **Step 1: Write the failing test**

Add to `test/craftplan_web/api/graphql_test.exs` inside the `describe "queries"` block:

```elixir
test "listProducts can filter by sku and return it", %{conn: conn} do
  {raw_key, _api_key, admin} = create_api_key!(%{"products" => ["read", "create"]})
  Factory.create_product!(%{name: "SKU Probe", sku: "BOTTLE-PID-TEST1"}, admin)

  query = """
  query($sku: String!) {
    listProducts(filter: {sku: {eq: $sku}}) {
      results { id sku }
    }
  }
  """

  resp = graphql(conn, raw_key, query, %{"sku" => "BOTTLE-PID-TEST1"})

  assert is_nil(resp["errors"])
  results = get_in(resp, ["data", "listProducts", "results"])
  assert [%{"sku" => "BOTTLE-PID-TEST1"}] = results
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `PATH="$HOME/.local/share/mise/shims:$PATH" mix test test/craftplan_web/api/graphql_test.exs -k "filter by sku"`
Expected: FAIL — `filter` rejects unknown field `sku` (or `sku` not in results).

- [ ] **Step 3: Make `sku` public**

In `lib/craftplan/catalog/product.ex`, add `public? true` to the `:sku` attribute:

```elixir
attribute :sku, :string do
  public? true
end
```

(Match the existing block's other options; only add `public? true`.)

- [ ] **Step 4: Run test to verify it passes**

Run: `PATH="$HOME/.local/share/mise/shims:$PATH" mix test test/craftplan_web/api/graphql_test.exs -k "filter by sku"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/craftplan/catalog/product.ex test/craftplan_web/api/graphql_test.exs
git commit -m "feat(catalog): expose Product.sku over GraphQL for filtering"
```

### Task 2: Expose `Order.invoice_number` + `payment_status` + `paid_at` for read/filter

**Files:**
- Modify: `lib/craftplan/orders/order.ex` (attribute blocks: `invoice_number` ~line 265, `payment_status` ~line 306, `paid_at` ~line 337)
- Test: `test/craftplan_web/api/graphql_test.exs`

**Interfaces:**
- Produces: `listOrders(filter: {invoiceNumber: {like: String}})` returns orders with readable `invoiceNumber`, `paymentStatus`, `paidAt`.

- [ ] **Step 1: Write the failing test**

```elixir
test "listOrders can filter by invoiceNumber and read payment fields", %{conn: conn} do
  {raw_key, _api_key, admin} = create_api_key!(%{"orders" => ["read", "create"], "customers" => ["create"]})
  customer = Factory.create_customer!(%{first_name: "Inv", last_name: "Probe"}, admin)
  Factory.create_order_with_items!(customer, [], invoice_number: "BOTTLE-INVTEST")

  query = """
  query($pat: String!) {
    listOrders(filter: {invoiceNumber: {like: $pat}}) {
      results { id invoiceNumber paymentStatus paidAt }
    }
  }
  """

  resp = graphql(conn, raw_key, query, %{"pat" => "BOTTLE-%"})

  assert is_nil(resp["errors"])
  results = get_in(resp, ["data", "listOrders", "results"])
  assert Enum.any?(results, &(&1["invoiceNumber"] == "BOTTLE-INVTEST"))
end
```

> If `Factory.create_order_with_items!/3` does not accept `:invoice_number`, set it in the factory opts handling first (one-line addition to the existing opts merge in `test/support/factory.ex`).

- [ ] **Step 2: Run test to verify it fails**

Run: `PATH="$HOME/.local/share/mise/shims:$PATH" mix test test/craftplan_web/api/graphql_test.exs -k "filter by invoiceNumber"`
Expected: FAIL — `filter` rejects `invoiceNumber`.

- [ ] **Step 3: Make the three attributes public**

In `lib/craftplan/orders/order.ex` add `public? true` to each:

```elixir
attribute :invoice_number, :string do
  allow_nil? true
  public? true
end
```
```elixir
attribute :payment_status, PaymentStatus do
  allow_nil? false
  default :pending
  public? true
end
```
```elixir
attribute :paid_at, :utc_datetime do
  allow_nil? true
  public? true
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `PATH="$HOME/.local/share/mise/shims:$PATH" mix test test/craftplan_web/api/graphql_test.exs -k "filter by invoiceNumber"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/craftplan/orders/order.ex test/craftplan_web/api/graphql_test.exs test/support/factory.ex
git commit -m "feat(orders): expose invoice_number/payment_status/paid_at over GraphQL reads"
```

### Task 3: Allow writing `payment_status` + `paid_at` via `updateOrder`

**Files:**
- Modify: `lib/craftplan/orders/order.ex` (the `update :update` action `accept` list, ~line 75)
- Test: `test/craftplan_web/api/graphql_test.exs`

**Interfaces:**
- Produces: `updateOrder(id, input: {paymentStatus: PAID, paidAt: DateTime})` persists both fields.

- [ ] **Step 1: Write the failing test**

```elixir
test "updateOrder can set paymentStatus and paidAt", %{conn: conn} do
  {raw_key, _api_key, admin} = create_api_key!(%{"orders" => ["read", "create", "update"], "customers" => ["create"]})
  customer = Factory.create_customer!(%{first_name: "Pay", last_name: "Probe"}, admin)
  order = Factory.create_order_with_items!(customer, [], invoice_number: "BOTTLE-PAYTEST")

  mutation = """
  mutation($id: ID!, $paidAt: DateTime!) {
    updateOrder(id: $id, input: {paymentStatus: PAID, paidAt: $paidAt}) {
      result { id paymentStatus paidAt }
      errors { message }
    }
  }
  """

  resp = graphql(conn, raw_key, mutation, %{"id" => order.id, "paidAt" => "2026-01-15T12:00:00Z"})

  assert is_nil(resp["errors"])
  assert [] == get_in(resp, ["data", "updateOrder", "errors"])
  assert get_in(resp, ["data", "updateOrder", "result", "paymentStatus"]) == "PAID"
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `PATH="$HOME/.local/share/mise/shims:$PATH" mix test test/craftplan_web/api/graphql_test.exs -k "set paymentStatus"`
Expected: FAIL — `input` rejects `paymentStatus`/`paidAt`.

- [ ] **Step 3: Add the fields to the `:update` accept list**

In `lib/craftplan/orders/order.ex`, the `update :update do` action — append `:payment_status, :paid_at` to its `accept [...]` list:

```elixir
accept [
  :status,
  :customer_id,
  :delivery_date,
  :invoice_number,
  :invoice_status,
  :invoiced_at,
  :payment_method,
  :discount_type,
  :discount_value,
  :delivery_method,
  :tax_total,
  :shipping_total,
  :discount_total,
  :payment_status,
  :paid_at
]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `PATH="$HOME/.local/share/mise/shims:$PATH" mix test test/craftplan_web/api/graphql_test.exs -k "set paymentStatus"`
Expected: PASS

- [ ] **Step 5: Run the full suite + commit**

Run: `PATH="$HOME/.local/share/mise/shims:$PATH" mix test test/craftplan_web/api/graphql_test.exs`
Expected: PASS (whole file).

```bash
git add lib/craftplan/orders/order.ex test/craftplan_web/api/graphql_test.exs
git commit -m "feat(orders): allow setting payment_status/paid_at via updateOrder"
```

### Task 4: PR1 finalization

- [ ] **Step 1: Format + full suite**

Run: `PATH="$HOME/.local/share/mise/shims:$PATH" mix format && PATH="$HOME/.local/share/mise/shims:$PATH" mix test test/craftplan_web/api/`
Expected: formatting clean; API tests PASS. (Note: the repo has known pre-existing failures elsewhere — scope the run to `test/craftplan_web/api/`.)

- [ ] **Step 2: Open PR against the fork**

```bash
git push -u origin HEAD
gh pr create --repo timchambers/craftplan --base main \
  --title "feat: expose Order/Product GraphQL fields for Bottle API import" \
  --body "Exposes Product.sku and Order invoice_number/payment_status/paid_at for read+filter, and allows setting payment_status/paid_at via updateOrder. Prerequisite for the Bottle importer API rewrite."
```

- [ ] **Step 3: Deploy gate (manual)**

PR1 must merge and deploy to the target instance (prod Docker-Compose image rebuilt and pulled) **before** PR2 can run against it. Note this in the PR description.

---

# PHASE 2 / PR2 — Stage-2 API rewrite (`feat(bottle-import)`)

> Depends on PR1 being deployed to the target. Branch from `main` after PR1 merges.

### Task 5: `ApiClient` — Req-based GraphQL transport

**Files:**
- Create: `lib/craftplan/bottle_import/api_client.ex`
- Test: `test/craftplan/bottle_import/api_client_test.exs`
- Modify: `config/test.exs` (add the Req test-stub hook)

**Interfaces:**
- Produces:
  - `ApiClient.query(document :: String.t(), variables :: map()) :: {:ok, map()} | {:error, term()}` — returns the `data` map on success; `{:error, {:graphql, errors}}` if the response has a non-empty `errors` array; `{:error, {:http, status}}` on non-2xx.
  - `ApiClient.mutate(document, variables, root_field :: String.t()) :: {:ok, map()} | {:error, term()}` — unwraps `data[root_field]`, returns `{:error, {:mutation, errors}}` if `errors` non-empty, else `{:ok, result_map}`.
  - `ApiClient.api_url_for_log() :: String.t()` — the configured base URL, for the audit line (consumed by Task 8).

- [ ] **Step 1: Add the test-stub config hook**

In `config/test.exs` add:

```elixir
config :craftplan, :bottle_api_req_options, plug: {Req.Test, Craftplan.BottleImport.ApiClient}
config :craftplan, :bottle_api_url, "http://test.local"
config :craftplan, :bottle_api_key, "cpk_test"
```

- [ ] **Step 2: Write the failing test**

Create `test/craftplan/bottle_import/api_client_test.exs`:

```elixir
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
      Req.Test.json(conn, %{"data" => %{"createProduct" => %{"result" => nil, "errors" => [%{"message" => "bad"}]}}})
    end)

    assert {:error, {:mutation, [%{"message" => "bad"}]}} =
             ApiClient.mutate("mutation { createProduct { result { id } errors { message } } }", %{}, "createProduct")
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `PATH="$HOME/.local/share/mise/shims:$PATH" mix test test/craftplan/bottle_import/api_client_test.exs`
Expected: FAIL — `ApiClient` undefined.

- [ ] **Step 4: Implement `ApiClient`**

Create `lib/craftplan/bottle_import/api_client.ex`:

```elixir
defmodule Craftplan.BottleImport.ApiClient do
  @moduledoc """
  Minimal GraphQL transport for the Bottle importer. POSTs to
  `{CRAFTPLAN_API_URL}/api/graphql` with a `cpk_` bearer token.
  """

  @spec query(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def query(document, variables \\ %{}) do
    case Req.post(req(), json: %{query: document, variables: variables}) do
      {:ok, %{status: 200, body: %{"data" => data, "errors" => errors}}} when errors not in [nil, []] ->
        {:error, {:graphql, errors}}

      {:ok, %{status: 200, body: %{"data" => data}}} ->
        {:ok, data}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  @spec mutate(String.t(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def mutate(document, variables, root_field) do
    with {:ok, data} <- query(document, variables) do
      case Map.get(data, root_field) do
        %{"errors" => errs} when errs not in [nil, []] -> {:error, {:mutation, errs}}
        %{"result" => result} -> {:ok, result}
        other -> {:error, {:unexpected, other}}
      end
    end
  end

  defp req do
    base =
      Req.new(
        base_url: api_url(),
        url: "/api/graphql",
        headers: [authorization: "Bearer #{api_key()}"],
        retry: false
      )

    Req.merge(base, Application.get_env(:craftplan, :bottle_api_req_options, []))
  end

  @doc "The configured API base URL, for audit-log lines."
  @spec api_url_for_log() :: String.t()
  def api_url_for_log, do: api_url()

  defp api_url, do: Application.get_env(:craftplan, :bottle_api_url) || System.get_env("CRAFTPLAN_API_URL") || "http://localhost:4000"
  defp api_key, do: Application.get_env(:craftplan, :bottle_api_key) || System.get_env("CRAFTPLAN_API_KEY") || ""
end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `PATH="$HOME/.local/share/mise/shims:$PATH" mix test test/craftplan/bottle_import/api_client_test.exs`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/craftplan/bottle_import/api_client.ex test/craftplan/bottle_import/api_client_test.exs config/test.exs
git commit -m "feat(bottle-import): add GraphQL ApiClient transport"
```

### Task 6: `Queries` — the GraphQL document module

**Files:**
- Create: `lib/craftplan/bottle_import/queries.ex`
- Test: `test/craftplan/bottle_import/queries_test.exs`

**Interfaces:**
- Produces string constants/functions:
  - `Queries.list_product_by_sku()` / `Queries.create_product()` / `Queries.list_customer_by_phone()` / `Queries.list_customer_by_email()` / `Queries.create_customer()` / `Queries.update_customer()` / `Queries.list_bottle_orders()` / `Queries.create_order()` / `Queries.update_order_paid()` — all return `String.t()` GraphQL documents using the verified field names.

- [ ] **Step 1: Write the failing test**

Create `test/craftplan/bottle_import/queries_test.exs`:

```elixir
defmodule Craftplan.BottleImport.QueriesTest do
  use ExUnit.Case, async: true
  alias Craftplan.BottleImport.Queries

  test "documents reference verified fields" do
    assert Queries.list_product_by_sku() =~ "listProducts(filter: {sku: {eq: $sku}})"
    assert Queries.create_order() =~ "createOrder(input: $input)"
    assert Queries.create_order() =~ "items"
    assert Queries.list_bottle_orders() =~ ~s|invoiceNumber: {like: "BOTTLE-%"}|
    assert Queries.list_bottle_orders() =~ "paymentStatus"
    assert Queries.update_order_paid() =~ "paymentStatus: PAID"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `PATH="$HOME/.local/share/mise/shims:$PATH" mix test test/craftplan/bottle_import/queries_test.exs`
Expected: FAIL — `Queries` undefined.

- [ ] **Step 3: Implement `Queries`**

Create `lib/craftplan/bottle_import/queries.ex`:

```elixir
defmodule Craftplan.BottleImport.Queries do
  @moduledoc "GraphQL documents for the Bottle importer (field names verified against the schema)."

  def list_product_by_sku do
    """
    query($sku: String!) {
      listProducts(filter: {sku: {eq: $sku}}) {
        results { id sku price }
      }
    }
    """
  end

  def create_product do
    """
    mutation($input: CreateProductInput!) {
      createProduct(input: $input) {
        result { id sku price }
        errors { message shortMessage fields }
      }
    }
    """
  end

  def list_customer_by_phone do
    """
    query($phone: String!) {
      listCustomers(filter: {phone: {eq: $phone}}) {
        results { id phone email }
      }
    }
    """
  end

  def list_customer_by_email do
    """
    query($email: String!) {
      listCustomers(filter: {email: {eq: $email}}) {
        results { id phone email }
      }
    }
    """
  end

  def create_customer do
    """
    mutation($input: CreateCustomerInput!) {
      createCustomer(input: $input) {
        result { id phone email }
        errors { message shortMessage fields }
      }
    }
    """
  end

  def update_customer do
    """
    mutation($id: ID!, $input: UpdateCustomerInput!) {
      updateCustomer(id: $id, input: $input) {
        result { id }
        errors { message shortMessage fields }
      }
    }
    """
  end

  def list_bottle_orders do
    """
    query($after: String) {
      listOrders(filter: {invoiceNumber: {like: "BOTTLE-%"}}, first: 250, after: $after) {
        results { id invoiceNumber paymentStatus }
        endKeyset
      }
    }
    """
  end

  def create_order do
    """
    mutation($input: CreateOrderInput!) {
      createOrder(input: $input) {
        result { id invoiceNumber }
        errors { message shortMessage fields }
      }
    }
    """
  end

  def update_order_paid do
    """
    mutation($id: ID!, $paidAt: DateTime) {
      updateOrder(id: $id, input: {paymentStatus: PAID, paidAt: $paidAt}) {
        result { id paymentStatus }
        errors { message shortMessage fields }
      }
    }
    """
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `PATH="$HOME/.local/share/mise/shims:$PATH" mix test test/craftplan/bottle_import/queries_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/craftplan/bottle_import/queries.ex test/craftplan/bottle_import/queries_test.exs
git commit -m "feat(bottle-import): add GraphQL document module"
```

### Task 7: Rewrite `Upserts` onto the API

**Files:**
- Modify (rewrite): `lib/craftplan/bottle_import/upserts.ex`
- Modify (rewrite): `test/craftplan/bottle_import/upserts_test.exs`

**Interfaces:**
- Consumes: `ApiClient.query/2`, `ApiClient.mutate/3`, `Queries.*`, untouched `NameParser`/`PhoneNormalizer`/`SlotTimeParser`.
- Produces (new signatures — actor arg dropped; price map and resolved maps passed in):
  - `resolve_product(pid, name, category, price_map) :: {:ok, %{id: String.t(), price: Decimal.t()}} | {:error, {:unknown_pid, map()}} | {:error, term()}`
  - `upsert_customer(row) :: {:ok, %{id: String.t()}} | {:error, term()}`
  - `upsert_order(order_row, items, product_map :: %{pid => %{id, price}}, customer_id :: String.t(), already_imported :: MapSet.t(), unpaid :: MapSet.t()) :: {:ok, :created | :restamped} | {:skip, :already_imported} | {:error, term()}`

- [ ] **Step 1: Write the failing tests**

Replace `test/craftplan/bottle_import/upserts_test.exs` with API-stubbed tests. Key cases (full file):

```elixir
defmodule Craftplan.BottleImport.UpsertsTest do
  use ExUnit.Case, async: true

  alias Craftplan.BottleImport.{ApiClient, Upserts}

  defp stub_sequence(responses) do
    {:ok, agent} = Agent.start_link(fn -> responses end)
    Req.Test.stub(ApiClient, fn conn ->
      next = Agent.get_and_update(agent, fn [h | t] -> {h, t} end)
      Req.Test.json(conn, next)
    end)
  end

  test "resolve_product returns existing product without creating" do
    stub_sequence([%{"data" => %{"listProducts" => %{"results" => [%{"id" => "p1", "sku" => "BOTTLE-PID-1", "price" => "10.00"}]}}}])

    assert {:ok, %{id: "p1", price: %Decimal{}}} =
             Upserts.resolve_product("PID-1", "Loaf", "manufactured", %{})
  end

  test "resolve_product creates from price map when missing" do
    stub_sequence([
      %{"data" => %{"listProducts" => %{"results" => []}}},
      %{"data" => %{"createProduct" => %{"result" => %{"id" => "p2", "sku" => "BOTTLE-PID-2", "price" => "8.50"}, "errors" => []}}}
    ])

    assert {:ok, %{id: "p2"}} =
             Upserts.resolve_product("PID-2", "Bun", "manufactured", %{"PID-2" => Decimal.new("8.50")})
  end

  test "resolve_product errors on unknown pid" do
    stub_sequence([%{"data" => %{"listProducts" => %{"results" => []}}}])
    assert {:error, {:unknown_pid, %{pid: "PID-3"}}} =
             Upserts.resolve_product("PID-3", "Mystery", "manufactured", %{})
  end

  test "upsert_customer nils an email already held by a different phone" do
    stub_sequence([
      # lookup by phone -> none
      %{"data" => %{"listCustomers" => %{"results" => []}}},
      # email conflict check -> held by different phone
      %{"data" => %{"listCustomers" => %{"results" => [%{"id" => "cX", "phone" => "+15550000000", "email" => "shared@h.com"}]}}},
      # create
      %{"data" => %{"createCustomer" => %{"result" => %{"id" => "c1"}, "errors" => []}}}
    ])

    row = %{"Customer Name" => "Jane Doe", "Phone" => "(202) 555-1212", "Email" => "shared@h.com",
            "Address1" => "1 St", "Address2" => "", "City" => "DC", "State" => "DC", "Zip" => "20001"}

    assert {:ok, %{id: "c1"}} = Upserts.upsert_customer(row)
  end

  test "upsert_order skips when already imported and paid" do
    assert {:skip, :already_imported} =
             Upserts.upsert_order(%{"Bottle ID" => "999"}, [], %{}, "c1",
               MapSet.new(["BOTTLE-999"]), MapSet.new())
  end

  test "upsert_order re-stamps an already-imported but unpaid order" do
    stub_sequence([%{"data" => %{"updateOrder" => %{"result" => %{"id" => "o1", "paymentStatus" => "PAID"}, "errors" => []}}}])
    # NOTE: needs the order id; in this path upsert_order looks it up from the unpaid map.
    assert {:ok, :restamped} =
             Upserts.upsert_order(%{"Bottle ID" => "999", "Transaction Date" => "2026-01-10 10:00:00"},
               [], %{}, "c1", MapSet.new(["BOTTLE-999"]),
               MapSet.new([%{invoice: "BOTTLE-999", id: "o1"}]))
  end
end
```

> The `unpaid` set carries `%{invoice, id}` maps (the order id is needed to update). Adjust the test data shape to whatever Task 8's skip-set builder produces; keep the two structures identical.

- [ ] **Step 2: Run test to verify it fails**

Run: `PATH="$HOME/.local/share/mise/shims:$PATH" mix test test/craftplan/bottle_import/upserts_test.exs`
Expected: FAIL — new signatures/behavior absent.

- [ ] **Step 3: Rewrite `Upserts`**

Replace `lib/craftplan/bottle_import/upserts.ex`. Full module:

```elixir
defmodule Craftplan.BottleImport.Upserts do
  @moduledoc false

  alias Craftplan.BottleImport.{ApiClient, NameParser, PhoneNormalizer, Queries, SlotTimeParser}

  @spec resolve_product(String.t(), String.t(), String.t(), map()) ::
          {:ok, %{id: String.t(), price: Decimal.t()}} | {:error, term()}
  def resolve_product(pid, name, category, price_map) do
    sku = "BOTTLE-#{pid}"

    case ApiClient.query(Queries.list_product_by_sku(), %{"sku" => sku}) do
      {:ok, %{"listProducts" => %{"results" => [p | _]}}} ->
        {:ok, %{id: p["id"], price: to_decimal(p["price"])}}

      {:ok, %{"listProducts" => %{"results" => []}}} ->
        case Map.get(price_map, pid) do
          nil -> {:error, {:unknown_pid, %{pid: pid, name: name}}}
          %Decimal{} = price -> create_product(sku, name, category, price)
        end

      {:error, _} = err ->
        err
    end
  end

  defp create_product(sku, name, category, price) do
    availability = if category == "kit", do: "OFF", else: "AVAILABLE"

    input = %{
      "sku" => sku,
      "name" => name,
      "price" => Decimal.to_string(price),
      "status" => "ACTIVE",
      "sellingAvailability" => availability
    }

    case ApiClient.mutate(Queries.create_product(), %{"input" => input}, "createProduct") do
      {:ok, p} -> {:ok, %{id: p["id"], price: to_decimal(p["price"])}}
      {:error, _} = err -> err
    end
  end

  @spec upsert_customer(map()) :: {:ok, %{id: String.t()}} | {:error, term()}
  def upsert_customer(row) do
    with {:ok, phone} <- PhoneNormalizer.normalize(row["Phone"]) do
      names = NameParser.parse(row["Customer Name"])
      email = row["Email"] |> blank_to_nil() |> resolve_email_conflict(phone)

      input = %{
        "type" => "INDIVIDUAL",
        "firstName" => names.first_name,
        "lastName" => names.last_name,
        "email" => email,
        "phone" => phone,
        "shippingAddress" => build_address(row)
      }

      case lookup_customer_by_phone(phone) do
        nil ->
          with {:ok, c} <- ApiClient.mutate(Queries.create_customer(), %{"input" => input}, "createCustomer"),
               do: {:ok, %{id: c["id"]}}

        %{"id" => id} ->
          update_input = Map.delete(input, "type")
          with {:ok, _} <- ApiClient.mutate(Queries.update_customer(), %{"id" => id, "input" => update_input}, "updateCustomer"),
               do: {:ok, %{id: id}}
      end
    end
  end

  # Households share an email; if the email is held by a *different* phone, drop it.
  defp resolve_email_conflict(nil, _phone), do: nil

  defp resolve_email_conflict(email, phone) do
    case ApiClient.query(Queries.list_customer_by_email(), %{"email" => email}) do
      {:ok, %{"listCustomers" => %{"results" => [%{"phone" => ^phone} | _]}}} -> email
      {:ok, %{"listCustomers" => %{"results" => [_ | _]}}} -> nil
      _ -> email
    end
  end

  defp lookup_customer_by_phone(phone) do
    case ApiClient.query(Queries.list_customer_by_phone(), %{"phone" => phone}) do
      {:ok, %{"listCustomers" => %{"results" => [c | _]}}} -> c
      _ -> nil
    end
  end

  @spec upsert_order(map(), [map()], map(), String.t(), MapSet.t(), MapSet.t()) ::
          {:ok, :created | :restamped} | {:skip, :already_imported} | {:error, term()}
  def upsert_order(order_row, items, product_map, customer_id, already_imported, unpaid) do
    invoice_number = "BOTTLE-#{order_row["Bottle ID"]}"
    paid_at = parse_utc_datetime(order_row["Transaction Date"])

    cond do
      unpaid_entry = Enum.find(unpaid, &(&1.invoice == invoice_number)) ->
        restamp(unpaid_entry.id, paid_at)

      MapSet.member?(already_imported, invoice_number) ->
        {:skip, :already_imported}

      true ->
        create_and_stamp(order_row, items, product_map, customer_id, invoice_number, paid_at)
    end
  end

  defp create_and_stamp(order_row, items, product_map, customer_id, invoice_number, paid_at) do
    with {:ok, item_inputs} <- build_items(items, product_map),
         {:ok, delivery_date} <-
           SlotTimeParser.parse(parse_date(order_row["Fulfillment Slot Day"]), order_row["Fulfillment Slot Time"]) do
      input = %{
        "customerId" => customer_id,
        "deliveryDate" => DateTime.to_iso8601(delivery_date),
        "deliveryMethod" => map_delivery_method(order_row["Fulfillment Method"]),
        "invoiceNumber" => invoice_number,
        "status" => "COMPLETED",
        "paymentMethod" => "CARD",
        "items" => item_inputs
      }

      with {:ok, order} <- ApiClient.mutate(Queries.create_order(), %{"input" => input}, "createOrder"),
           {:ok, :restamped} <- restamp(order["id"], paid_at) do
        {:ok, :created}
      end
    end
  end

  defp restamp(order_id, paid_at) do
    vars = %{"id" => order_id, "paidAt" => paid_at && DateTime.to_iso8601(paid_at)}

    case ApiClient.mutate(Queries.update_order_paid(), vars, "updateOrder") do
      {:ok, _} -> {:ok, :restamped}
      {:error, _} = err -> err
    end
  end

  defp build_items(items, product_map) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      pid = item["pid"]

      case Map.get(product_map, pid) do
        %{id: id, price: price} ->
          input = %{"productId" => id, "quantity" => to_string(item["quantity"]), "unitPrice" => Decimal.to_string(price)}
          {:cont, {:ok, acc ++ [input]}}

        nil ->
          {:halt, {:error, {:unknown_pid, %{pid: pid}}}}
      end
    end)
  end

  # ---- helpers (carried over from the Repo version) ----

  defp build_address(row) do
    street =
      [blank_to_nil(row["Address1"]), blank_to_nil(row["Address2"])]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    %{
      "street" => blank_to_nil(street),
      "city" => blank_to_nil(row["City"]),
      "state" => blank_to_nil(row["State"]),
      "zip" => blank_to_nil(row["Zip"]),
      "country" => "US"
    }
  end

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)
  defp to_decimal(s) when is_binary(s), do: Decimal.new(s)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: s)
  defp blank_to_nil(other), do: other

  defp map_delivery_method("Maketto Pickup"), do: "PICKUP"
  defp map_delivery_method(_), do: "DELIVERY"

  defp parse_date(%Date{} = d), do: d
  defp parse_date(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_date(ndt)
  defp parse_date(%DateTime{} = dt), do: DateTime.to_date(dt)
  defp parse_date(s) when is_binary(s), do: Date.from_iso8601!(s)

  defp parse_utc_datetime(nil), do: nil
  defp parse_utc_datetime(%DateTime{} = dt), do: DateTime.shift_zone!(dt, "Etc/UTC")

  defp parse_utc_datetime(%NaiveDateTime{} = ndt) do
    {:ok, dt} = DateTime.from_naive(ndt, "America/New_York")
    DateTime.shift_zone!(dt, "Etc/UTC")
  end

  defp parse_utc_datetime(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      trimmed ->
        case NaiveDateTime.from_iso8601(trimmed) do
          {:ok, ndt} -> parse_utc_datetime(ndt)
          {:error, _} -> nil
        end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `PATH="$HOME/.local/share/mise/shims:$PATH" mix test test/craftplan/bottle_import/upserts_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/craftplan/bottle_import/upserts.ex test/craftplan/bottle_import/upserts_test.exs
git commit -m "feat(bottle-import): rewrite Upserts onto the GraphQL API"
```

### Task 8: Rewrite the Mix task (resolve-first, skip-set, concurrency, audit)

**Files:**
- Modify (rewrite): `lib/mix/tasks/bottle/import.ex`
- Modify: `test/craftplan/bottle_import_test.exs`

**Interfaces:**
- Consumes: `Upserts.*`, `ApiClient.query/2`, `Queries.list_bottle_orders/0`.
- Produces: `Mix.Tasks.Bottle.Import.run_args/1` returns the same summary map shape as today plus `api_url`; builds `product_map`, `customer_map`, `already_imported` (MapSet of invoice strings), `unpaid` (MapSet of `%{invoice, id}`).

- [ ] **Step 1: Write the failing orchestration test**

In `test/craftplan/bottle_import_test.exs`, replace the Repo-based setup with a stubbed-API run over `test/support/bottle_fixtures`. Core assertion:

```elixir
test "imports the fixture run over the API and is idempotent on re-run" do
  # First pass: empty catalog/customers/orders, all creates succeed.
  Req.Test.stub(Craftplan.BottleImport.ApiClient, &FixtureApi.first_pass/1)
  result = Mix.Tasks.Bottle.Import.run_args([fixtures_dir(), "--yes"])
  assert result.unknown_pids == []
  assert result.inserted_orders == 5
  assert result.failed_orders == 0

  # Second pass: listOrders returns all 5 as already-imported + paid → all skipped.
  Req.Test.stub(Craftplan.BottleImport.ApiClient, &FixtureApi.second_pass/1)
  result2 = Mix.Tasks.Bottle.Import.run_args([fixtures_dir(), "--yes"])
  assert result2.inserted_orders == 0
  assert result2.skipped_orders == 5
end
```

> Implement a `FixtureApi` test helper module (in the test file) that pattern-matches on the GraphQL document substring (`"listProducts"`, `"createOrder"`, `"listOrders"`, etc.) and returns canned `Req.Test.json/2` responses. `first_pass` returns empty lookups + successful creates; `second_pass` returns the 5 orders from `listOrders` with `paymentStatus: "PAID"`.

- [ ] **Step 2: Run test to verify it fails**

Run: `PATH="$HOME/.local/share/mise/shims:$PATH" mix test test/craftplan/bottle_import_test.exs`
Expected: FAIL — task still calls Ash/Repo.

- [ ] **Step 3: Rewrite the task pipeline**

In `lib/mix/tasks/bottle/import.ex`, replace `preview/2`, `execute/3`, and the lookup helpers. Keep `run/1`, `run_args/1` structure, `load_csvs/1`, `load_price_map/1`, `append_audit/2`, `confirm!/1`, `format_summary/1`. New pipeline:

```elixir
defp execute(csvs, price_map, run_dir) do
  started_at = System.monotonic_time(:millisecond)

  # 1. resolve products -> %{pid => %{id, price}}
  {product_map, prod_errors} = resolve_products(csvs.products, price_map)

  # 2. resolve customers -> %{phone_or_key => id}; keyed by Bottle ID for order lookup
  customer_map = resolve_customers(csvs.orders)

  # 3. idempotency: page listOrders for BOTTLE-% -> already_imported + unpaid sets
  {already_imported, unpaid} = load_existing_orders()

  # 4. write orders with bounded concurrency
  concurrency = csvs.concurrency || 8

  results =
    csvs.orders
    |> Task.async_stream(
      fn order_row ->
        items = Enum.filter(csvs.order_items, &(to_string(&1["Bottle ID"]) == to_string(order_row["Bottle ID"])))
        customer_id = Map.get(customer_map, order_row["Bottle ID"])
        Upserts.upsert_order(order_row, items, product_map, customer_id, already_imported, unpaid)
      end,
      max_concurrency: concurrency,
      timeout: 30_000
    )
    |> Enum.reduce({0, 0, []}, fn
      {:ok, {:ok, _}}, {ins, sk, fl} -> {ins + 1, sk, fl}
      {:ok, {:skip, :already_imported}}, {ins, sk, fl} -> {ins, sk + 1, fl}
      {:ok, {:error, reason}}, {ins, sk, fl} -> {ins, sk, [reason | fl]}
      {:exit, reason}, {ins, sk, fl} -> {ins, sk, [reason | fl]}
    end)

  {inserted, skipped, failed} = results
  elapsed = System.monotonic_time(:millisecond) - started_at

  summary = %{
    unknown_pids: [],
    inserted_orders: inserted,
    skipped_orders: skipped,
    failed_orders: length(failed),
    failures: Enum.reverse(failed),
    elapsed_ms: elapsed,
    api_url: ApiClient.api_url_for_log()
  }

  append_audit(summary, run_dir)
  summary
end

defp load_existing_orders do
  Stream.unfold("", fn
    :done -> nil
    after_cursor ->
      case ApiClient.query(Queries.list_bottle_orders(), %{"after" => after_cursor}) do
        {:ok, %{"listOrders" => %{"results" => [], "endKeyset" => _}}} -> nil
        {:ok, %{"listOrders" => %{"results" => rows, "endKeyset" => nil}}} -> {rows, :done}
        {:ok, %{"listOrders" => %{"results" => rows, "endKeyset" => cur}}} -> {rows, cur}
        _ -> nil
      end
  end)
  |> Enum.concat()
  |> Enum.reduce({MapSet.new(), MapSet.new()}, fn row, {imp, unpaid} ->
    inv = row["invoiceNumber"]
    imp = MapSet.put(imp, inv)
    unpaid = if row["paymentStatus"] == "PAID", do: unpaid, else: MapSet.put(unpaid, %{invoice: inv, id: row["id"]})
    {imp, unpaid}
  end)
end
```

> `preview/2`'s unknown-PID detection: keep the same gate, but resolve "known" via `ApiClient.query(Queries.list_product_by_sku(), …)` ∪ price-map keys instead of the Repo. `resolve_products/2` and `resolve_customers/1` are thin loops over `Upserts.resolve_product/4` and `Upserts.upsert_customer/1` building the maps; `resolve_customers/1` keys the result by `order_row["Bottle ID"]` so step 4 finds the customer id without a per-order lookup. Add `ApiClient.api_url_for_log/0` returning the configured URL for the audit line. Add `--concurrency` to the `OptionParser` switches and thread it onto `csvs` (or pass separately).

- [ ] **Step 4: Run test to verify it passes**

Run: `PATH="$HOME/.local/share/mise/shims:$PATH" mix test test/craftplan/bottle_import_test.exs`
Expected: PASS

- [ ] **Step 5: Run all bottle tests + format + commit**

Run: `PATH="$HOME/.local/share/mise/shims:$PATH" mix format && PATH="$HOME/.local/share/mise/shims:$PATH" mix test test/craftplan/bottle_import_test.exs test/craftplan/bottle_import/`
Expected: PASS

```bash
git add lib/mix/tasks/bottle/import.ex test/craftplan/bottle_import_test.exs
git commit -m "feat(bottle-import): drive the import over the GraphQL API"
```

### Task 9: Update SKILL.md and README for the API flow

**Files:**
- Modify: `.claude/skills/bottle-import/SKILL.md`
- Modify: `priv/imports/bottle/README.md`

**Interfaces:** none (docs).

- [ ] **Step 1: Rewrite SKILL.md**

Update the Procedure to: (1) Stage 1 `extract.py` unchanged; (2) set `CRAFTPLAN_API_URL` + `CRAFTPLAN_API_KEY` (default URL `http://localhost:4000` for dev); (3) preview gate; (4) `mix bottle.import <run_dir> --yes [--concurrency N]`; (5) verify in the deployed UI; (6) audit log now records `api_url`. Add a prominent note: **PR1 (Order/Product GraphQL exposure) must be deployed to the target instance before importing against it.** Update the Prerequisites and Troubleshooting tables (drop the Repo/`staff_actor` row; add an "API key lacks write scope" row → `{:error, {:mutation, …}}`).

- [ ] **Step 2: Update README.md**

Replace the Quickstart's Stage-2 line with the env-var + `mix bottle.import` invocation; note the target is chosen by `CRAFTPLAN_API_URL`.

- [ ] **Step 3: Commit**

```bash
git add .claude/skills/bottle-import/SKILL.md priv/imports/bottle/README.md
git commit -m "docs(bottle-import): document the API-based import flow"
```

### Task 10: PR2 finalization

- [ ] **Step 1: Full bottle suite + format**

Run: `PATH="$HOME/.local/share/mise/shims:$PATH" mix format && PATH="$HOME/.local/share/mise/shims:$PATH" mix test test/craftplan/bottle_import_test.exs test/craftplan/bottle_import/`
Expected: PASS.

- [ ] **Step 2: Open PR against the fork**

```bash
git push -u origin HEAD
gh pr create --repo timchambers/craftplan --base main \
  --title "feat(bottle-import): rewrite Stage 2 onto the GraphQL API" \
  --body "Replaces the Repo write backend with a Req-based GraphQL client targeting CRAFTPLAN_API_URL. Depends on the Order/Product GraphQL exposure PR being deployed."
```

- [ ] **Step 3: Run the real import against prod (manual, post-deploy)**

After PR1+PR2 deploy: set `CRAFTPLAN_API_URL=https://plan.breadparavion.com` + `CRAFTPLAN_API_KEY=cpk_…` (write scopes), re-run `extract.py` if needed, then `mix bottle.import <run_dir> --yes`. Confirm the audit line shows `inserted + skipped == 4305`, `failed == 0`.

---

## Self-Review

**Spec coverage:**
- Goal 1 (API target via `CRAFTPLAN_API_URL`) → Tasks 5, 8. ✓
- Goal 2 (preserve parsing) → Task 7 reuses parsers untouched. ✓
- Goal 3 (idempotent/resumable) → Task 8 `load_existing_orders` + skip/restamp sets. ✓
- Goal 4 (efficient) → Task 8 resolve-first maps + `Task.async_stream`. ✓
- Goal 5 (preview/audit shell) → Task 8 keeps `confirm!`, `append_audit`, `format_summary`. ✓
- Decision 1 (paid via `:update` accept) → Task 3 + Task 7 `restamp`. ✓
- Decision 2 (single API path) → Tasks 7–8 remove Ash/Repo. ✓
- Decision 3 (scale-optimized) → Task 8. ✓
- Decision 4 (public+filterable invoice_number) → Task 2. ✓
- Section 7 prerequisite (Order/Product exposure) → Tasks 1–3; plus the unanticipated `Product.sku` gap (Task 1). ✓

**Placeholder scan:** No TBD/TODO. The doc-only Task 9 describes edits in prose (acceptable for docs, not code). Open items from spec §12 are resolved by the verified-schema section (items is a typed input; `like` exists; exact field set known).

**Type consistency:** `resolve_product/4`, `upsert_customer/1`, `upsert_order/6` signatures match between Task 7 (definition) and Task 8 (call site). The `unpaid` set element shape `%{invoice, id}` matches between `load_existing_orders` (Task 8) and `upsert_order`/test (Task 7). `ApiClient.query/2`, `mutate/3`, and `api_url_for_log/0` are referenced consistently — all three are defined in Task 5's `ApiClient` and consumed in Tasks 7–8.
