defmodule Craftplan.BottleImport.ApiClientEnvTest do
  # async: false — these mutate global Application/System env to exercise the
  # "no configuration" path, so they must not run alongside other tests.
  use ExUnit.Case, async: false

  alias Craftplan.BottleImport.ApiClient

  setup do
    saved = %{
      url_cfg: Application.get_env(:craftplan, :bottle_api_url),
      key_cfg: Application.get_env(:craftplan, :bottle_api_key),
      url_env: System.get_env("CRAFTPLAN_API_URL"),
      key_env: System.get_env("CRAFTPLAN_API_KEY")
    }

    on_exit(fn ->
      restore_app(:bottle_api_url, saved.url_cfg)
      restore_app(:bottle_api_key, saved.key_cfg)
      restore_env("CRAFTPLAN_API_URL", saved.url_env)
      restore_env("CRAFTPLAN_API_KEY", saved.key_env)
    end)

    :ok
  end

  test "raises when CRAFTPLAN_API_URL is unset — no localhost fallback" do
    Application.delete_env(:craftplan, :bottle_api_url)
    System.delete_env("CRAFTPLAN_API_URL")

    assert_raise RuntimeError, ~r/CRAFTPLAN_API_URL is not set/, fn ->
      ApiClient.query("query { __typename }", %{})
    end
  end

  test "raises when CRAFTPLAN_API_KEY is unset" do
    Application.put_env(:craftplan, :bottle_api_url, "http://test.local")
    Application.delete_env(:craftplan, :bottle_api_key)
    System.delete_env("CRAFTPLAN_API_KEY")

    assert_raise RuntimeError, ~r/CRAFTPLAN_API_KEY is not set/, fn ->
      ApiClient.query("query { __typename }", %{})
    end
  end

  defp restore_app(key, nil), do: Application.delete_env(:craftplan, key)
  defp restore_app(key, val), do: Application.put_env(:craftplan, key, val)
  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, val), do: System.put_env(name, val)
end
