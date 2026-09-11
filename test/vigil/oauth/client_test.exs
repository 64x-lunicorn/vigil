defmodule Vigil.OAuth.ClientTest do
  @moduledoc """
  The registered-client record: written and read in one module.

  It used to be a map literal in `Vigil.OAuth.Flow` at registration and a
  destructuring in `Vigil.OAuth.Client` at resolution — one record, two places
  and a round trip. This is that round trip, asked of the module that owns
  both halves.
  """
  use ExUnit.Case, async: false

  alias Vigil.OAuth.Client

  setup do
    Vigil.OAuthCase.setup!()
  end

  test "a registered client resolves to exactly what registration wrote", %{
    persistence: persistence
  } do
    now = System.system_time(:second)

    client = Client.register(persistence, "App", ["https://app.example/cb"], now)

    assert client.name == "App"
    assert client.redirect_uris == ["https://app.example/cb"]
    assert is_binary(client.client_id)

    assert {:ok, client} == Client.resolve(persistence, client.client_id, now)
  end

  test "each registration mints its own client_id", %{persistence: persistence} do
    now = System.system_time(:second)

    first = Client.register(persistence, "App", ["https://app.example/cb"], now)
    second = Client.register(persistence, "App", ["https://app.example/cb"], now)

    refute first.client_id == second.client_id
  end

  test "a client_id that was never registered and is no CIMD URL does not resolve", %{
    persistence: persistence
  } do
    assert Client.resolve(persistence, "never-registered") == :error
  end
end
