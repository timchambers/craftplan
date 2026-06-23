defmodule Craftplan.Accounts.Checks.ApiScopeCheck do
  @moduledoc """
  Policy check that verifies API key scopes when a request is made via an API key.

  When no API key context is present (normal web user), the check passes.
  When an API key context is present, verifies the key has the required scope
  for the resource and action type.
  """
  use Ash.Policy.SimpleCheck

  @resource_scope_map %{
    Craftplan.Catalog.Product => "products",
    Craftplan.Catalog.BOM => "boms",
    Craftplan.Catalog.BOMComponent => "bom_components",
    Craftplan.Orders.Order => "orders",
    Craftplan.Orders.OrderItem => "order_items",
    Craftplan.Orders.ProductionBatch => "production_batches",
    Craftplan.Inventory.Material => "materials",
    Craftplan.Inventory.Lot => "lots",
    Craftplan.Inventory.Movement => "movements",
    Craftplan.Inventory.Supplier => "suppliers",
    Craftplan.Inventory.PurchaseOrder => "purchase_orders",
    Craftplan.Inventory.PurchaseOrderItem => "purchase_order_items",
    Craftplan.CRM.Customer => "customers",
    Craftplan.Settings.Settings => "settings"
  }

  @impl true
  def describe(_opts) do
    "API key has required scope for this resource and action"
  end

  @impl true
  def match?(_actor, %{resource: resource, action: action} = _context, _opts) do
    api_scopes = Process.get(:api_key_scopes)

    case api_scopes do
      nil ->
        # No API key context — normal web user, pass through
        true

      scopes when is_map(scopes) ->
        resource_key = Map.get(@resource_scope_map, resource)
        required_permissions = action_type_to_permissions(action.type)

        case Map.get(scopes, resource_key) do
          nil ->
            false

          permissions when is_list(permissions) ->
            Enum.any?(required_permissions, &(&1 in permissions))

          _ ->
            false
        end
    end
  end

  # Returns a list of permission strings that satisfy this action type.
  # "write" is accepted as a legacy coarse-grained permission for all write types.
  # Granular strings ("create", "update", "delete") are also accepted.
  defp action_type_to_permissions(:read), do: ["read"]
  defp action_type_to_permissions(:create), do: ["write", "create"]
  defp action_type_to_permissions(:update), do: ["write", "update"]
  defp action_type_to_permissions(:destroy), do: ["write", "delete"]
  defp action_type_to_permissions(_), do: ["read"]
end
