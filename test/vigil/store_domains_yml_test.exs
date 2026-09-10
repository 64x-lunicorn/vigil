defmodule Vigil.StoreDomainsYmlTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Vigil.Store

  # One writer for this file, under a name of its own — see Vigil.StoreTest.
  @store __MODULE__

  # Vigil.MCP.Tools declares limit (1..25, default 10) and supplies it on
  # every real call, so `Store.call(@store, :search, ...)` requires one rather than defaulting.
  defp search(params), do: Store.call(@store, :search, Map.put_new(params, :limit, 10))

  defp empty_vault(tmp) do
    File.mkdir_p!(tmp)
    tmp
  end

  # The Store reaches git through the commit log here, like every other
  # vault-backed file (docs/design.md, "Git is reached through a value").
  defp start_store(vault) do
    start_supervised!(
      {Store,
       vault_path: vault,
       exclude: [],
       git_remote: "origin",
       git: Vigil.Git.CommitLog.new(vault),
       name: @store}
    )
  end

  test "missing _domains.yml logs a warning but the server starts and instructions still work" do
    tmp = Path.join(System.tmp_dir!(), "vigil_no_domains_#{System.unique_integer([:positive])}")
    empty_vault(tmp)

    on_exit(fn -> File.rm_rf(tmp) end)

    log =
      capture_log(fn ->
        start_store(tmp)
      end)

    assert log =~ "_domains.yml"
    assert Store.instructions_domains_text(@store) == ""
  end

  test "empty vault starts without error and search returns an empty list" do
    tmp = Path.join(System.tmp_dir!(), "vigil_empty_#{System.unique_integer([:positive])}")
    empty_vault(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    start_store(tmp)
    assert search(%{query: "irgendwas"}) == []
  end

  test "unreadable _domains.yml logs a warning and instructions_domains_text falls back to empty" do
    vault = Vigil.FixtureVault.build()
    on_exit(fn -> Vigil.FixtureVault.cleanup(vault) end)

    start_store(vault)

    path = Path.join(vault, "_domains.yml")
    File.chmod!(path, 0o000)

    log =
      capture_log(fn ->
        assert Store.instructions_domains_text(@store) == ""
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
        start_store(vault)
      end)

    assert log =~ "key 'phantom' has no matching directory"

    assert Store.instructions_domains_text(@store) =~ "bike:"
  end
end
