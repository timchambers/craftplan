defmodule Craftplan.BottleImport.Upserts do
  @moduledoc false

  alias Craftplan.BottleImport.ApiClient
  alias Craftplan.BottleImport.NameParser
  alias Craftplan.BottleImport.PhoneNormalizer
  alias Craftplan.BottleImport.Queries
  alias Craftplan.BottleImport.SlotTimeParser

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
    availability = if category == "kit", do: "off", else: "available"

    input = %{
      "sku" => sku,
      "name" => name,
      "price" => Decimal.to_string(price),
      "status" => "active",
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
        "type" => "individual",
        "firstName" => names.first_name,
        "lastName" => names.last_name,
        "email" => email,
        "phone" => phone,
        "shippingAddress" => build_address(row)
      }

      case lookup_customer_by_phone(phone) do
        nil ->
          with {:ok, c} <-
                 ApiClient.mutate(
                   Queries.create_customer(),
                   %{"input" => input},
                   "createCustomer"
                 ),
               do: {:ok, %{id: c["id"]}}

        %{"id" => id} ->
          update_input = Map.delete(input, "type")

          with {:ok, _} <-
                 ApiClient.mutate(
                   Queries.update_customer(),
                   %{"id" => id, "input" => update_input},
                   "updateCustomer"
                 ),
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
        if paid?(order_row),
          do: restamp(unpaid_entry.id, paid_at),
          else: {:skip, :already_imported}

      MapSet.member?(already_imported, invoice_number) ->
        {:skip, :already_imported}

      true ->
        create_and_stamp(order_row, items, product_map, customer_id, invoice_number, paid_at)
    end
  end

  defp create_and_stamp(order_row, items, product_map, customer_id, invoice_number, paid_at) do
    with {:ok, item_inputs} <- build_items(items, product_map),
         {:ok, delivery_date} <-
           SlotTimeParser.parse(
             parse_date(order_row["Fulfillment Slot Day"]),
             order_row["Fulfillment Slot Time"]
           ) do
      input = %{
        "customerId" => customer_id,
        "deliveryDate" => DateTime.to_iso8601(delivery_date),
        "deliveryMethod" => map_delivery_method(order_row["Fulfillment Method"]),
        "invoiceNumber" => invoice_number,
        "status" => order_status(delivery_date),
        "paymentMethod" => "card",
        "items" => item_inputs
      }

      with {:ok, order} <-
             ApiClient.mutate(Queries.create_order(), %{"input" => input}, "createOrder") do
        maybe_stamp_paid(order["id"], order_row, paid_at)
      end
    end
  end

  # Order status derives from the delivery slot: a slot still in the future means
  # the order hasn't been fulfilled yet (:unconfirmed); a past/elapsed slot is
  # treated as :completed (the historical-import case).
  defp order_status(%DateTime{} = delivery_date) do
    if DateTime.after?(delivery_date, DateTime.utc_now()) do
      "unconfirmed"
    else
      "completed"
    end
  end

  # Stamp a freshly-created order paid only when the Bottle row says so; otherwise
  # leave it at the resource default (:pending). Returns {:ok, :created} either way.
  defp maybe_stamp_paid(order_id, order_row, paid_at) do
    if paid?(order_row) do
      with {:ok, :restamped} <- restamp(order_id, paid_at), do: {:ok, :created}
    else
      {:ok, :created}
    end
  end

  # A Bottle order counts as paid only when its "Payment Status" is "Paid"
  # (case-insensitive). Anything else — Unpaid, Refunded, blank — stays pending.
  defp paid?(order_row) do
    order_row
    |> Map.get("Payment Status")
    |> to_string()
    |> String.trim()
    |> String.downcase() == "paid"
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
          input = %{
            "productId" => id,
            "quantity" => to_string(item["quantity"]),
            "unitPrice" => Decimal.to_string(price)
          }

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

    Jason.encode!(%{
      "street" => blank_to_nil(street),
      "city" => blank_to_nil(row["City"]),
      "state" => blank_to_nil(row["State"]),
      "zip" => blank_to_nil(row["Zip"]),
      "country" => "US"
    })
  end

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)
  defp to_decimal(s) when is_binary(s), do: Decimal.new(s)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: s)
  defp blank_to_nil(other), do: other

  defp map_delivery_method("Maketto Pickup"), do: "pickup"
  defp map_delivery_method(_), do: "delivery"

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
      "" ->
        nil

      trimmed ->
        case NaiveDateTime.from_iso8601(trimmed) do
          {:ok, ndt} -> parse_utc_datetime(ndt)
          {:error, _} -> nil
        end
    end
  end
end
