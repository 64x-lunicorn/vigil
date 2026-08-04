defmodule Vigil.StoreDomainsYmlTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Vigil.Store

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
    assert Store.search(%{query: "irgendwas"}) == []
    assert Store.domain_names() == []
  end

  test "key without folder and folder without key both log warnings, and content reaches instructions" do
    vault = Vigil.FixtureVault.build()
    on_exit(fn -> Vigil.FixtureVault.cleanup(vault) end)

    log =
      capture_log(fn ->
        start_supervised!({Store, vault_path: vault, exclude: [], git_remote: "origin"})
      end)

    assert log =~ "key 'phantom' has no matching directory"
    assert log =~ "domain 'garden' has no entry"

    assert Store.instructions_domains_text() =~ "bike:"
  end
end
