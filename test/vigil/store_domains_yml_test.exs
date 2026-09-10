defmodule Vigil.StoreDomainsYmlTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Vigil.Store

  # Vigil.MCP.Tools declares limit (1..25, default 10) and supplies it on
  # every real call, so Store.search/1 requires one rather than defaulting.
  defp search(params), do: Store.search(Map.put_new(params, :limit, 10))

  defp git_init_empty(tmp) do
    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, ".gitkeep"), "")
    System.cmd("git", ["init", "-q"], cd: tmp)
    System.cmd("git", ["symbolic-ref", "HEAD", "refs/heads/main"], cd: tmp)
    System.cmd("git", ["config", "user.name", "Daniel"], cd: tmp)
    System.cmd("git", ["config", "user.email", "daniel@local"], cd: tmp)
    # See Vigil.FixtureVault.build/1: avoids depending on the (flaky, here
    # irrelevant) 1Password-backed commit signing from the global git config.
    System.cmd("git", ["config", "commit.gpgsign", "false"], cd: tmp)
    System.cmd("git", ["add", "-A"], cd: tmp)
    System.cmd("git", ["commit", "-q", "-m", "empty"], cd: tmp)
  end

  test "missing _domains.yml logs a warning but the server starts and instructions still work" do
    tmp = Path.join(System.tmp_dir!(), "vigil_no_domains_#{System.unique_integer([:positive])}")
    git_init_empty(tmp)

    on_exit(fn -> File.rm_rf(tmp) end)

    log =
      capture_log(fn ->
        start_supervised!({Store, vault_path: tmp, exclude: [], git_remote: "origin"})
      end)

    assert log =~ "_domains.yml"
    assert Store.instructions_domains_text() == ""
  end

  test "empty vault starts without error and search returns an empty list" do
    tmp = Path.join(System.tmp_dir!(), "vigil_empty_#{System.unique_integer([:positive])}")
    git_init_empty(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    start_supervised!({Store, vault_path: tmp, exclude: [], git_remote: "origin"})
    assert search(%{query: "irgendwas"}) == []
    assert Store.domain_names() == []
  end

  test "unreadable _domains.yml logs a warning and instructions_domains_text falls back to empty" do
    vault = Vigil.FixtureVault.build()
    on_exit(fn -> Vigil.FixtureVault.cleanup(vault) end)

    start_supervised!({Store, vault_path: vault, exclude: [], git_remote: "origin"})

    path = Path.join(vault, "_domains.yml")
    File.chmod!(path, 0o000)

    log =
      capture_log(fn ->
        assert Store.instructions_domains_text() == ""
      end)

    File.chmod!(path, 0o644)

    assert log =~ "cannot read _domains.yml"
    assert search(%{query: "tires"}) != []
  end

  # Which mismatches are reported, and how they are worded, is Vigil.Vault.Domains'
  # job now and is covered there (domains_test.exs) without a vault or a process.
  # This is the wiring smoke test: the Store reaches the parser, logs what comes
  # back, and serves the file's text to the instructions.
  test "drift between _domains.yml and the vault reaches the log, and the file's text reaches the instructions" do
    vault = Vigil.FixtureVault.build()
    on_exit(fn -> Vigil.FixtureVault.cleanup(vault) end)

    log =
      capture_log(fn ->
        start_supervised!({Store, vault_path: vault, exclude: [], git_remote: "origin"})
      end)

    assert log =~ "key 'phantom' has no matching directory"

    assert Store.instructions_domains_text() =~ "bike:"
  end
end
