defmodule Mix.Tasks.Bottle.Import do
  @shortdoc "Import a Bottle order-report run into Craftplan via the GraphQL API"

  @moduledoc """
  Imports a Bottle order-report run directory into Craftplan via the GraphQL API.

      mix bottle.import <run_dir> [--yes] [--price-map PATH] [--concurrency N]

  The run directory must contain `products.csv`, `customers.csv`, `orders.csv`,
  `order_items.csv` as produced by `priv/imports/bottle/extract.py`.

  Default price map: `priv/imports/bottle/price_map.yml`.
  Pass `--price-map PATH` to override.
  Pass `--yes` (or `-y`) to skip the interactive confirmation prompt.
  Pass `--concurrency N` to control async order-write parallelism (default: 8).

  Exits non-zero (code 2) if any PIDs in order_items.csv are absent from both
  the price map and the existing product catalogue.
  """
  use Mix.Task

  alias Craftplan.BottleImport.ApiClient
  alias Craftplan.BottleImport.PhoneNormalizer
  alias Craftplan.BottleImport.Queries
  alias Craftplan.BottleImport.Upserts

  @default_price_map "priv/imports/bottle/price_map.yml"
  @audit_log "priv/imports/bottle/bottle_import_log.jsonl"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    result = run_args(args)
    Mix.shell().info(IO.iodata_to_binary(format_summary(result)))
    if result.unknown_pids != [], do: System.halt(2)
    :ok
  end

  @doc """
  Programmatic entry point used by tests. Returns a result map.
  """
  def run_args(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        switches: [yes: :boolean, price_map: :string, concurrency: :integer],
        aliases: [y: :yes]
      )

    [run_dir | _] = positional
    price_map_path = opts[:price_map] || @default_price_map
    yes? = opts[:yes] || false
    concurrency = opts[:concurrency] || 8

    price_map = load_price_map(price_map_path)
    csvs = load_csvs(run_dir)

    {preview_result, _} = preview(csvs, price_map)

    if preview_result.unknown_pids == [] do
      yes? || confirm!(preview_result)
      execute(csvs, price_map, run_dir, concurrency)
    else
      summary = %{
        unknown_pids: preview_result.unknown_pids,
        inserted_orders: 0,
        skipped_orders: 0,
        restamped_orders: 0,
        failed_orders: 0,
        elapsed_ms: 0,
        api_url: ApiClient.api_url_for_log()
      }

      append_audit(summary, run_dir)
      summary
    end
  end

  # ---------- pipeline ----------

  # preview/2 scans order_items PIDs to detect unknowns before touching the API.
  # A PID is "known" if it already exists as a BOTTLE- product via listProducts,
  # or if the price map has an entry for it (meaning we can create it on demand).
  defp preview(csvs, price_map) do
    unknowns =
      csvs.order_items
      |> Enum.map(& &1["pid"])
      |> Enum.uniq()
      |> Enum.reject(fn pid ->
        Map.has_key?(price_map, pid) or product_exists?(pid)
      end)

    {%{unknown_pids: unknowns}, csvs}
  end

  defp product_exists?(pid) do
    sku = "BOTTLE-#{pid}"

    case ApiClient.query(Queries.list_product_by_sku(), %{"sku" => sku}) do
      {:ok, %{"listProducts" => %{"results" => [_ | _]}}} -> true
      _ -> false
    end
  end

  defp execute(csvs, price_map, run_dir, concurrency) do
    started_at = System.monotonic_time(:millisecond)

    # Step 1: resolve products -> %{pid => %{id, price}}
    {product_map, _prod_errors} = resolve_products(csvs.products, price_map)

    # Step 2: resolve customers once per unique phone -> %{bottle_id => customer_id}
    customer_map = resolve_customers(csvs.orders)

    # Step 3: idempotency — page listOrders for BOTTLE-% -> already_imported + unpaid sets
    {already_imported, unpaid} = load_existing_orders()

    # Step 4: write orders with bounded concurrency
    results =
      csvs.orders
      |> Task.async_stream(
        fn order_row ->
          items =
            Enum.filter(
              csvs.order_items,
              &(to_string(&1["Bottle ID"]) == to_string(order_row["Bottle ID"]))
            )

          customer_id = Map.get(customer_map, order_row["Bottle ID"])

          Upserts.upsert_order(
            order_row,
            items,
            product_map,
            customer_id,
            already_imported,
            unpaid
          )
        end,
        max_concurrency: concurrency,
        timeout: 30_000
      )
      |> Enum.reduce({0, 0, 0, []}, fn
        {:ok, {:ok, :created}}, {ins, re, sk, fl} -> {ins + 1, re, sk, fl}
        {:ok, {:ok, :restamped}}, {ins, re, sk, fl} -> {ins, re + 1, sk, fl}
        {:ok, {:skip, :already_imported}}, {ins, re, sk, fl} -> {ins, re, sk + 1, fl}
        {:ok, {:error, reason}}, {ins, re, sk, fl} -> {ins, re, sk, [reason | fl]}
        {:exit, reason}, {ins, re, sk, fl} -> {ins, re, sk, [reason | fl]}
      end)

    {inserted, restamped, skipped, failed} = results
    elapsed = System.monotonic_time(:millisecond) - started_at

    summary = %{
      unknown_pids: [],
      inserted_orders: inserted,
      skipped_orders: skipped,
      restamped_orders: restamped,
      failed_orders: length(failed),
      failures: Enum.reverse(failed),
      elapsed_ms: elapsed,
      api_url: ApiClient.api_url_for_log()
    }

    append_audit(summary, run_dir)
    summary
  end

  # resolve_products/2 calls Upserts.resolve_product/4 once per product row,
  # building a %{pid => %{id, price}} map. Errors are collected but not fatal.
  defp resolve_products(product_rows, price_map) do
    Enum.reduce(product_rows, {%{}, []}, fn row, {map, errors} ->
      pid = row["pid"]
      name = row["name"]
      category = row["category"] || "manufactured"

      case Upserts.resolve_product(pid, name, category, price_map) do
        {:ok, entry} -> {Map.put(map, pid, entry), errors}
        {:error, reason} -> {map, [reason | errors]}
      end
    end)
  end

  # resolve_customers/1 de-dupes by normalized phone:
  # 1. Group order rows by normalized phone, call upsert_customer once per unique phone.
  # 2. Build a %{bottle_id => customer_id} map for use in upsert_order.
  # Orders whose phone fails normalization are mapped to nil customer_id (handled downstream).
  defp resolve_customers(order_rows) do
    # Build phone -> representative row (first occurrence)
    phone_to_row =
      Enum.reduce(order_rows, %{}, fn row, acc ->
        case PhoneNormalizer.normalize(row["Phone"]) do
          {:ok, phone} -> Map.put_new(acc, phone, row)
          :error -> acc
        end
      end)

    # Upsert each unique customer once -> %{phone => customer_id}
    phone_to_id =
      Enum.reduce(phone_to_row, %{}, fn {phone, row}, acc ->
        case Upserts.upsert_customer(row) do
          {:ok, %{id: id}} -> Map.put(acc, phone, id)
          {:error, _} -> acc
        end
      end)

    # Map each order's Bottle ID -> customer_id via its phone
    Enum.reduce(order_rows, %{}, fn row, acc ->
      bottle_id = row["Bottle ID"]

      customer_id =
        case PhoneNormalizer.normalize(row["Phone"]) do
          {:ok, phone} -> Map.get(phone_to_id, phone)
          :error -> nil
        end

      Map.put(acc, bottle_id, customer_id)
    end)
  end

  # load_existing_orders/0 pages listOrders via the API and builds:
  # - already_imported: MapSet of invoiceNumber strings
  # - unpaid: MapSet of %{invoice: invoiceNumber, id: id} for non-PAID orders
  defp load_existing_orders do
    nil
    |> Stream.unfold(fn
      :done ->
        nil

      after_cursor ->
        case ApiClient.query(Queries.list_bottle_orders(), %{"after" => after_cursor}) do
          {:ok, %{"listOrders" => %{"results" => [], "endKeyset" => _}}} ->
            nil

          {:ok, %{"listOrders" => %{"results" => rows, "endKeyset" => nil}}} ->
            {rows, :done}

          {:ok, %{"listOrders" => %{"results" => rows, "endKeyset" => cur}}} ->
            {rows, cur}

          {:error, reason} ->
            Mix.shell().error(
              "load_existing_orders: listOrders query failed — #{inspect(reason)}; treating as empty (idempotency lost)"
            )

            nil

          other ->
            Mix.shell().error(
              "load_existing_orders: unexpected listOrders response — #{inspect(other)}; treating as empty (idempotency lost)"
            )

            nil
        end
    end)
    |> Enum.concat()
    |> Enum.reduce({MapSet.new(), MapSet.new()}, fn row, {imp, unpaid} ->
      inv = row["invoiceNumber"]
      imp = MapSet.put(imp, inv)

      unpaid =
        if row["paymentStatus"] == "PAID",
          do: unpaid,
          else: MapSet.put(unpaid, %{invoice: inv, id: row["id"]})

      {imp, unpaid}
    end)
  end

  defp confirm!(preview_result) do
    Mix.shell().info("""
    Unknown PIDs: #{length(preview_result.unknown_pids)}
    """)

    if Mix.shell().yes?("Proceed?") do
      true
    else
      Mix.raise("Aborted by user.")
    end
  end

  # ---------- I/O ----------

  defp load_csvs(run_dir) do
    %{
      products: read_csv(Path.join(run_dir, "products.csv")),
      customers: read_csv(Path.join(run_dir, "customers.csv")),
      orders: read_csv(Path.join(run_dir, "orders.csv")),
      order_items: read_csv(Path.join(run_dir, "order_items.csv"))
    }
  end

  defp read_csv(path) do
    [header | rows] =
      path
      |> File.stream!()
      |> NimbleCSV.RFC4180.parse_stream(skip_headers: false)
      |> Enum.to_list()

    Enum.map(rows, fn row -> header |> Enum.zip(row) |> Map.new() end)
  end

  # Reads the price map YAML. Supports both forms:
  #
  #   prices: {}
  #   prices:
  #     "PID-47420": "10.00"
  #
  # Implemented with a line-by-line scanner to avoid a YAML dependency.
  defp load_price_map(path) do
    case File.read(path) do
      {:ok, body} ->
        body
        |> String.split("\n")
        |> Enum.reduce(%{}, fn line, acc ->
          case Regex.run(~r/^\s+"(PID-[\d-]+)":\s*"?([\d.]+)"?\s*$/, line) do
            [_, pid, price] -> Map.put(acc, pid, Decimal.new(price))
            _ -> acc
          end
        end)

      {:error, _} ->
        %{}
    end
  end

  defp append_audit(summary, run_dir) do
    File.mkdir_p!(Path.dirname(@audit_log))

    line =
      Jason.encode!(%{
        at: DateTime.to_iso8601(DateTime.utc_now()),
        run_dir: run_dir,
        unknown_pids: summary.unknown_pids,
        inserted_orders: summary.inserted_orders,
        skipped_orders: summary.skipped_orders,
        restamped_orders: Map.get(summary, :restamped_orders, 0),
        failed_orders: summary.failed_orders,
        elapsed_ms: summary.elapsed_ms,
        api_url: Map.get(summary, :api_url, "")
      })

    File.write!(@audit_log, line <> "\n", [:append])
  end

  defp format_summary(s) do
    [
      "Bottle import summary\n",
      "  inserted orders:  #{s.inserted_orders}\n",
      "  skipped orders:   #{s.skipped_orders}\n",
      "  restamped orders: #{Map.get(s, :restamped_orders, 0)}\n",
      "  failed orders:    #{s.failed_orders}\n",
      "  unknown PIDs:     #{length(s.unknown_pids)}#{format_unknowns(s.unknown_pids)}\n",
      "  elapsed: #{s.elapsed_ms}ms\n"
    ]
  end

  defp format_unknowns([]), do: ""
  defp format_unknowns(list), do: " (" <> Enum.join(list, ", ") <> ")"
end
