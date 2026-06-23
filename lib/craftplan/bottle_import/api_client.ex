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

  defp api_url,
    do: Application.get_env(:craftplan, :bottle_api_url) || System.get_env("CRAFTPLAN_API_URL") || "http://localhost:4000"

  defp api_key, do: Application.get_env(:craftplan, :bottle_api_key) || System.get_env("CRAFTPLAN_API_KEY") || ""
end
