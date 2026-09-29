defmodule Vigil.Settings.RuntimeConfigTest do
  @moduledoc """
  `config/runtime.exs` hands a malformed setting on instead of raising on it,
  so that `Vigil.Settings.Check` is the one place that refuses it — by name.

  async: false because what is under test is a read of the process
  environment: each test sets the variables it is about and restores them.
  """
  use ExUnit.Case, async: false

  alias Vigil.Settings.Check

  @runtime Path.expand("../../../config/runtime.exs", __DIR__)

  # A prod deployment that passes, as /etc/vigil/env would state it.
  @prod_env %{
    "VIGIL_VAULT_PATH" => "/var/lib/vigil/vault",
    "VIGIL_STATE_DIR" => "/var/lib/vigil",
    "VIGIL_ISSUER" => "https://vault.example.org",
    "VIGIL_RESOURCE" => "https://vault.example.org/mcp",
    "VIGIL_AUTH_PASSWORD" => "correct-horse-battery-staple",
    "VIGIL_SKILLKEY_SECRET" => "itTnVnZk/sC37IrApqZhoUWOfli819Xl7zZx6DSYKPrXRrOsez+p930plUaYNzV6"
  }

  @touched Map.keys(@prod_env) ++
             ~w(VIGIL_PORT VIGIL_TZ VIGIL_SKILLKEY_TTL VIGIL_RATE_LIMIT_RPM
                VIGIL_RELOAD_RATE_LIMIT_RPM VIGIL_OAUTH_RATE_LIMIT_RPM
                VIGIL_OAUTH_REGISTER_RATE_LIMIT_RPM VIGIL_ALLOWED_ORIGINS)

  setup do
    previous = Map.new(@touched, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)
    end)

    Enum.each(@touched, &System.delete_env/1)
    System.put_env(@prod_env)
  end

  defp prod_config, do: @runtime |> Config.Reader.read!(env: :prod) |> Keyword.fetch!(:vigil)

  test "the prod defaults pass the check, with integers parsed" do
    assert {:ok, checked} = Check.check(prod_config())
    assert checked.port == 4000
    assert checked.rate_limit_rpm == 60
  end

  test "a non-integer reaches the check as written and is refused by name" do
    for var <-
          ~w(VIGIL_PORT VIGIL_SKILLKEY_TTL VIGIL_RATE_LIMIT_RPM VIGIL_RELOAD_RATE_LIMIT_RPM
             VIGIL_OAUTH_RATE_LIMIT_RPM VIGIL_OAUTH_REGISTER_RATE_LIMIT_RPM) do
      System.put_env(var, "12abc")

      assert {:error, [message]} = Check.check(prod_config())
      assert message =~ var
      assert message =~ ~s("12abc")

      System.delete_env(var)
    end
  end

  test "a SkillKey TTL of zero is refused" do
    System.put_env("VIGIL_SKILLKEY_TTL", "0")

    assert {:error, [message]} = Check.check(prod_config())
    assert message =~ "VIGIL_SKILLKEY_TTL"
  end

  test "an unset required setting in prod is refused by name" do
    System.delete_env("VIGIL_STATE_DIR")

    assert {:error, [message]} = Check.check(prod_config())
    assert message =~ "VIGIL_STATE_DIR is not set"
  end

  # The upgrade path: a host set up before the SkillKey had a secret of its own
  # has an env file without one. It refuses to boot rather than fall back to
  # the consent password, and says which line to add and how to make it.
  test "an env file from before the SkillKey secret existed is refused, naming it" do
    System.delete_env("VIGIL_SKILLKEY_SECRET")

    assert {:error, [message]} = Check.check(prod_config())
    assert message =~ "VIGIL_SKILLKEY_SECRET is not set"
    assert message =~ "openssl rand -base64 48"
  end

  test "an http issuer is refused in prod" do
    System.put_env("VIGIL_ISSUER", "http://vault.example.org")

    assert {:error, messages} = Check.check(prod_config())
    assert Enum.any?(messages, &(&1 =~ "VIGIL_ISSUER"))
  end

  test "the allowed origins arrive as a list, and a bad one is refused by name" do
    assert {:ok, %{allowed_origins: []}} = Check.check(prod_config())

    System.put_env("VIGIL_ALLOWED_ORIGINS", " https://claude.ai, http://localhost:6274 ,")

    assert {:ok, %{allowed_origins: ["https://claude.ai", "http://localhost:6274"]}} =
             Check.check(prod_config())

    System.put_env("VIGIL_ALLOWED_ORIGINS", "https://claude.ai,claude.ai")

    assert {:error, [message]} = Check.check(prod_config())
    assert message =~ "VIGIL_ALLOWED_ORIGINS"
    assert message =~ ~s("claude.ai")
  end
end
