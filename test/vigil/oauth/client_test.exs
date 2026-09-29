defmodule Vigil.OAuth.ClientTest do
  @moduledoc """
  The registered-client record: written and read in one module.

  It used to be a map literal in `Vigil.OAuth.Flow` at registration and a
  destructuring in `Vigil.OAuth.Client` at resolution — one record, two places
  and a round trip. This is that round trip, asked of the module that owns
  both halves.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Vigil.OAuth.{Client, Persistence}

  @uris ["https://app.example/cb"]

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

  describe "the cap on stored clients" do
    # Filled through the seam rather than through `register/4`: what is being
    # asked is what registration does once the table is full, not how it got
    # there.
    defp fill(persistence, n) do
      for i <- 1..n do
        :ok = persistence.put_client.("filler-#{i}", %{name: "F", redirect_uris: @uris})
      end
    end

    test "registration is refused at the cap, with a warning, and nothing is stored", %{
      persistence: persistence
    } do
      fill(persistence, Client.max_clients())

      log =
        capture_log(fn ->
          assert_raise Persistence.Unavailable, fn ->
            Client.register(persistence, "App", @uris, 0)
          end
        end)

      assert log =~ "registration refused"
      assert log =~ "#{Client.max_clients()} clients stored"
      assert persistence.count_clients.() == Client.max_clients()
    end

    test "one under the cap still registers", %{persistence: persistence} do
      fill(persistence, Client.max_clients() - 1)

      assert %{client_id: _} = Client.register(persistence, "App", @uris, 0)
    end
  end

  test "a record that could not be stored is not handed out", %{persistence: persistence} do
    failing = %{persistence | put_client: fn _id, _attrs -> {:error, :enospc} end}

    assert_raise Persistence.Unavailable, fn -> Client.register(failing, "App", @uris, 0) end
  end

  describe "authorized/3" do
    test "records the first code, and only the first", %{persistence: persistence} do
      client = Client.register(persistence, "App", @uris, 100)
      assert {:ok, %{first_code_at: nil}} = persistence.get_client.(client.client_id)

      :ok = Client.authorized(persistence, client.client_id, 200)
      :ok = Client.authorized(persistence, client.client_id, 300)

      assert {:ok, %{first_code_at: 200, issued_at: 100, name: "App"}} =
               persistence.get_client.(client.client_id)
    end

    test "gives a record written before the field its first code", %{persistence: persistence} do
      :ok = persistence.put_client.("legacy", %{name: "L", redirect_uris: @uris, issued_at: 1})

      :ok = Client.authorized(persistence, "legacy", 200)

      assert {:ok, %{first_code_at: 200}} = persistence.get_client.("legacy")
    end

    test "has nothing to record for a client that is not stored", %{persistence: persistence} do
      assert :ok = Client.authorized(persistence, "https://cimd.example/client", 200)
      assert persistence.count_clients.() == 0
    end
  end

  describe "unused?/2" do
    test "a client never handed a code is unused once its window is up" do
      record = %{first_code_at: nil, issued_at: 1_000}

      refute Client.unused?(record, 1_000 + Client.unused_ttl() - 1)
      assert Client.unused?(record, 1_000 + Client.unused_ttl())
    end

    test "a client handed a code, or written before the field, is never unused" do
      refute Client.unused?(%{first_code_at: 1_100, issued_at: 1_000}, 10_000_000)
      refute Client.unused?(%{issued_at: 1_000}, 10_000_000)
    end
  end
end
