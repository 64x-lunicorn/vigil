defmodule Vigil.Settings.CheckTest do
  @moduledoc """
  Every setting checked once at boot, and a bad one named.

  async: true because the configuration under test is an argument: each test
  states the deployment it is about as a keyword list, the shape
  `Application.get_all_env(:vigil)` has, and nothing here writes into global
  application env.
  """
  use ExUnit.Case, async: true

  alias Vigil.Git.CommitLog
  alias Vigil.Settings.Check

  # A deployment that passes every check, in the shape `config/runtime.exs`
  # leaves it: integers where the variable read as one, strings elsewhere.
  @good [
    vault_path: "/var/lib/vigil/vault",
    git_remote: "github",
    git_branch: nil,
    state_dir: "/var/lib/vigil",
    port: 4000,
    bind: "127.0.0.1",
    tz: "Europe/Berlin",
    issuer: "https://vault.example.org",
    resource: "https://vault.example.org/mcp",
    auth_password: "correct-horse-battery-staple",
    allowed_origins: [],
    skillkey_secret: "itTnVnZk/sC37IrApqZhoUWOfli819Xl7zZx6DSYKPrXRrOsez+p930plUaYNzV6",
    skillkey_ttl_seconds: 3600,
    rate_limit_rpm: 60,
    reload_rate_limit_rpm: 6,
    oauth_rate_limit_rpm: 30,
    oauth_register_rate_limit_rpm: 5,
    https_required: true
  ]

  # The vault clone the deployment is checked against, as the git adapter
  # answers for it: by default one remote, `github`, and `main` checked out
  # and tracking `github/main`. The path is never read: the adapter is what
  # says what is there (test/vigil/git_test.exs holds it to a repository).
  defp clone(opts \\ []) do
    CommitLog.new("/var/lib/vigil/vault", Keyword.put_new(opts, :remote, "github"))
  end

  defp check_with(overrides, clone \\ clone()),
    do: Check.check(Keyword.merge(@good, overrides), clone)

  defp refused(overrides) do
    assert {:error, messages} = check_with(overrides)
    messages
  end

  test "a good deployment passes, and the listen address comes back parsed" do
    assert {:ok, checked} = Check.check(@good, clone())
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

  describe "the SkillKey secret" do
    # What `openssl rand` prints for 32 random bytes, in the two encodings an
    # operator is likely to reach for.
    @base64_32 "3q2+7wABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhs="
    @hex_32 "deadbeef000102030405060708090a0b0c0d0e0f101112131415161718191a1b"

    test "an unset secret is named, with how to generate one" do
      assert [message] = refused(skillkey_secret: nil)
      assert message =~ "VIGIL_SKILLKEY_SECRET is not set"
      assert message =~ "openssl rand -base64 48"
    end

    test "32 random bytes pass, base64 or hex" do
      assert {:ok, _} = check_with(skillkey_secret: @base64_32)
      assert {:ok, _} = check_with(skillkey_secret: @hex_32)
    end

    test "fewer than 32 bytes are refused without being echoed" do
      short_base64 = Base.encode64(:binary.copy(<<7>>, 31))
      short_hex = Base.encode16(:binary.copy(<<7>>, 31), case: :lower)

      for short <- [short_base64, short_hex] do
        assert [message] = refused(skillkey_secret: short)
        assert message =~ "VIGIL_SKILLKEY_SECRET"
        assert message =~ "32 random bytes"
        refute message =~ short
      end
    end

    test "a chosen phrase is refused, however long, and not echoed" do
      phrase = "correct horse battery staple, and then some more words to make it long"

      assert [message] = refused(skillkey_secret: phrase)
      assert message =~ "VIGIL_SKILLKEY_SECRET"
      assert message =~ "openssl rand -base64 48"
      refute message =~ phrase
    end

    test "the consent password is refused as the secret, and neither is echoed" do
      assert [message] = refused(auth_password: @base64_32, skillkey_secret: @base64_32)
      assert message =~ "VIGIL_SKILLKEY_SECRET"
      assert message =~ "VIGIL_AUTH_PASSWORD"
      refute message =~ @base64_32
    end
  end

  describe "the vault's remote and branch" do
    # A clone on `master`, tracking `github/master`, with a second branch that
    # tracks nothing.
    defp master_clone do
      clone(
        tracking:
          {:ok,
           %{
             head: "master",
             remotes: ["github"],
             branches: %{"master" => {"github", "master"}, "draft" => nil}
           }}
      )
    end

    test "unset, the branch is the checked-out one when it tracks the remote" do
      assert {:ok, %{git_remote: "github", git_branch: "master"}} =
               check_with([git_branch: nil], master_clone())
    end

    test "unset, the branch is main when the checked-out one tracks nothing" do
      untracked =
        clone(
          tracking:
            {:ok,
             %{
               head: "draft",
               remotes: ["github"],
               branches: %{"draft" => nil, "main" => {"github", "main"}}
             }}
        )

      assert {:ok, %{git_branch: "main"}} = check_with([git_branch: ""], untracked)
    end

    test "a branch that is set is used as set" do
      assert {:ok, %{git_branch: "master"}} = check_with([git_branch: "master"], master_clone())
    end

    test "a branch the clone does not have is refused, naming the setting" do
      assert [message] = refused_by(master_clone(), git_branch: "main")
      assert message =~ "VIGIL_GIT_BRANCH"
      assert message =~ ~s("main")
      assert message =~ "master"
    end

    test "an unset branch whose default the clone does not have is refused, saying so" do
      detached =
        clone(
          tracking:
            {:ok,
             %{head: nil, remotes: ["github"], branches: %{"master" => {"github", "master"}}}}
        )

      assert [message] = refused_by(detached, git_branch: nil)
      assert message =~ "VIGIL_GIT_BRANCH"
      assert message =~ "the default while it is unset"
    end

    test "a branch without an upstream on the remote is refused, naming the setting" do
      assert [message] = refused_by(master_clone(), git_branch: "draft")
      assert message =~ "VIGIL_GIT_BRANCH"
      assert message =~ "github/draft"
      assert message =~ "no upstream"
    end

    test "a remote the clone does not have is refused, naming the setting" do
      assert [message] = refused_by(master_clone(), git_remote: "origin", git_branch: "master")
      assert message =~ "VIGIL_GIT_REMOTE"
      assert message =~ ~s("origin")
      assert message =~ "github"
    end

    test "a vault path that is no git clone is refused, and the two say nothing more" do
      none = clone(tracking: {:error, "not a git clone"})

      assert [message] = refused_by(none, git_branch: "master")
      assert message =~ "VIGIL_VAULT_PATH"
      assert message =~ "git clone"
    end

    defp refused_by(clone, overrides) do
      assert {:error, messages} = check_with(overrides, clone)
      messages
    end
  end

  test "every bad setting is named at once, not the first one only" do
    messages = refused(port: "abc", tz: "Nowhere", rate_limit_rpm: 0)

    assert length(messages) == 3
  end

  describe "check!/2" do
    test "raises one message naming every bad setting" do
      error =
        assert_raise RuntimeError, fn ->
          Check.check!(Keyword.merge(@good, port: "abc", skillkey_ttl_seconds: 0), clone())
        end

      assert error.message =~ "VIGIL_PORT"
      assert error.message =~ "VIGIL_SKILLKEY_TTL"
      assert error.message =~ "/etc/vigil/env"
    end

    test "returns what was checked when nothing is wrong" do
      assert %{port: 4000, bind: {127, 0, 0, 1}} = Check.check!(@good, clone())
    end
  end
end
