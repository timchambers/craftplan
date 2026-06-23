defmodule Craftplan.BottleImport.ApiClient do
  @moduledoc """
  Minimal GraphQL transport for the Bottle importer. POSTs to
  `{CRAFTPLAN_API_URL}/api/graphql` with a `cpk_` bearer token.
  """

  @spec query(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def query(document, variables \\ %{}) do
    case Req.post(req(), json: %{query: document, variables: variables}) do
      {:ok, %{status: 200, body: %{"errors" => errors}}} when errors not in [nil, []] ->
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

  # The importer always targets a deployed Craftplan instance over its GraphQL
  # API. There is intentionally no localhost fallback: an unset CRAFTPLAN_API_URL
  # raises rather than silently importing somewhere unexpected. (Tests set
  # :bottle_api_url via Application config, so they never hit this path.)
  defp api_url do
    Application.get_env(:craftplan, :bottle_api_url) || System.get_env("CRAFTPLAN_API_URL") ||
      raise """
      CRAFTPLAN_API_URL is not set. The Bottle importer writes to a deployed Craftplan
      instance via its GraphQL API and will not fall back to a default. Set it explicitly:

          export CRAFTPLAN_API_URL=https://plan.breadparavion.com   # production
      """
  end

  defp api_key do
    Application.get_env(:craftplan, :bottle_api_key) || System.get_env("CRAFTPLAN_API_KEY") ||
      raise """
      CRAFTPLAN_API_KEY is not set. Export a cpk_ bearer token with scopes: products
      (create+read), customers (create+read), orders (create+read+update), order_items (create).
      """
  end
end
