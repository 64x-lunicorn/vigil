defmodule Vigil.Settings.CheckTest do
  @moduledoc """
  Every setting checked once at boot, and a bad one named.

  async: true because the configuration under test is an argument: each test
  states the deployment it is about as a keyword list, the shape
  `Application.get_all_env(:vigil)` has, and nothing here writes into global
  application env.
  """
  use ExUnit.Case, async: true

  alias Vigil.Settings.Check

  # A deployment that passes every check, in the shape `config/runtime.exs`
  # leaves it: integers where the variable read as one, strings elsewhere.
  @good [
    vault_path: "/var/lib/vigil/vault",
    state_dir: "/var/lib/vigil",
    port: 4000,
    bind: "127.0.0.1",
    tz: "Europe/Berlin",
    issuer: "https://vault.example.org",
    resource: "https://vault.example.org/mcp",
    auth_password: "correct-horse-battery-staple",
    allowed_origins: [],
    skillkey_ttl_seconds: 3600,
    rate_limit_rpm: 60,
    reload_rate_limit_rpm: 6,
    oauth_rate_limit_rpm: 30,
    oauth_register_rate_limit_rpm: 5,
    https_required: true
  ]

  defp check_with(overrides), do: Check.check(Keyword.merge(@good, overrides))

  defp refused(overrides) do
    assert {:error, messages} = check_with(overrides)
    messages
  end

  test "a good deployment passes, and the listen address comes back parsed" do
    assert {:ok, checked} = Check.check(@good)
    assert checked.bind == {127, 0, 0, 1}
    assert checked.port == 4000
  end

  describe "positive integers" do
    @integers [
      port: "VIGIL_PORT",
      rate_limit_rpm: "VIGIL_RATE_LIMIT_RPM",
      reload_rate_limit_rpm: "VIGIL_RELOAD_RATE_LIMIT_RPM",
      oauth_rate_limit_rpm: "VIGIL_OAUTH_RATE_LIMIT_RPM",
      oauth_register_rate_limit_rpm: "VIGIL_OAUTH_REGISTER_RATE_LIMIT_RPM",
      skillkey_ttl_seconds: "VIGIL_SKILLKEY_TTL"
    ]

    test "a value that is not an integer is refused, naming the variable" do
      for {key, var} <- @integers do
        assert [message] = refused([{key, "sixty"}])
        assert message =~ var
        assert message =~ "positive integer"
        assert message =~ ~s("sixty")
      end
    end

    test "zero and negative values are refused, naming the variable" do
      for {key, var} <- @integers, bad <- [0, -1] do
        assert [message] = refused([{key, bad}])
        assert message =~ var
        assert message =~ "positive integer"
      end
    end

    test "a port above 65535 is refused" do
      assert [message] = refused(port: 70_000)
      assert message =~ "VIGIL_PORT"
    end
  end

  describe "the timezone" do
    test "an unknown zone is refused rather than quietly becoming UTC" do
      assert [message] = refused(tz: "Europe/Atlantis")
      assert message =~ "VIGIL_TZ"
      assert message =~ ~s("Europe/Atlantis")
    end

    test "any zone the database knows passes" do
      assert {:ok, _} = check_with(tz: "America/New_York")
      assert {:ok, _} = check_with(tz: "Etc/UTC")
    end
  end

  describe "the authorization server's identity" do
    test "in prod, an issuer that is not https is refused" do
      messages =
        refused(issuer: "http://vault.example.org", resource: "http://vault.example.org/mcp")

      assert [message] = Enum.filter(messages, &(&1 =~ "VIGIL_ISSUER"))
      assert message =~ "https"
    end

    test "in prod, a resource that is not https is refused" do
      assert [message] = refused(resource: "http://vault.example.org/mcp")
      assert message =~ "VIGIL_RESOURCE"
      assert message =~ "https"
    end

    test "in prod, a resource on another origin than the issuer is refused" do
      for resource <- [
            "https://other.example.org/mcp",
            "https://vault.example.org:8443/mcp"
          ] do
        assert [message] = refused(resource: resource)
        assert message =~ "VIGIL_RESOURCE"
        assert message =~ "https://vault.example.org"
      end
    end

    test "an issuer that is no URL at all is refused" do
      assert Enum.any?(refused(issuer: "vault.example.org"), &(&1 =~ "VIGIL_ISSUER"))
    end

    test "outside prod, the localhost defaults pass" do
      assert {:ok, _} =
               check_with(
                 https_required: false,
                 issuer: "http://localhost:4000",
                 resource: "http://localhost:4000/mcp"
               )
    end
  end

  describe "the allowed origins" do
    test "none is fine, and listed ones come back serialized" do
      assert {:ok, %{allowed_origins: []}} = check_with([])

      assert {:ok, %{allowed_origins: ["https://claude.ai", "http://localhost:6274"]}} =
               check_with(allowed_origins: ["https://Claude.ai/", "http://localhost:6274"])
    end

    test "an entry that is not an origin is refused, naming the variable and the entry" do
      assert [message] =
               refused(allowed_origins: ["https://claude.ai", "claude.ai", "https://x.org/mcp"])

      assert message =~ "VIGIL_ALLOWED_ORIGINS"
      assert message =~ ~s("claude.ai")
      assert message =~ ~s("https://x.org/mcp")
      refute message =~ ~s("https://claude.ai")
    end
  end

  describe "what was checked before this module existed" do
    test "a setting prod leaves unset is named" do
      messages = refused(vault_path: nil, state_dir: "")

      assert Enum.any?(messages, &(&1 =~ "VIGIL_VAULT_PATH is not set"))
      assert Enum.any?(messages, &(&1 =~ "VIGIL_STATE_DIR is not set"))
    end

    test "a short consent password is refused without being echoed" do
      assert [message] = refused(auth_password: "shortsecret")
      assert message =~ "VIGIL_AUTH_PASSWORD"
      assert message =~ "12 characters"
      refute message =~ "shortsecret"
    end

    test "a missing consent password is refused" do
      assert [message] = refused(auth_password: nil)
      assert message =~ "VIGIL_AUTH_PASSWORD"
    end

    test "a listen address that is not an IP address is refused" do
      assert [message] = refused(bind: "localhost")
      assert message =~ "VIGIL_BIND"
      assert message =~ ~s("localhost")
    end
  end

  test "every bad setting is named at once, not the first one only" do
    messages = refused(port: "abc", tz: "Nowhere", rate_limit_rpm: 0)

    assert length(messages) == 3
  end

  describe "check!/1" do
    test "raises one message naming every bad setting" do
      error =
        assert_raise RuntimeError, fn ->
          Check.check!(Keyword.merge(@good, port: "abc", skillkey_ttl_seconds: 0))
        end

      assert error.message =~ "VIGIL_PORT"
      assert error.message =~ "VIGIL_SKILLKEY_TTL"
      assert error.message =~ "/etc/vigil/env"
    end

    test "returns what was checked when nothing is wrong" do
      assert %{port: 4000, bind: {127, 0, 0, 1}} = Check.check!(@good)
    end
  end
end
