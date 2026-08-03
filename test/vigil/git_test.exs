defmodule Vigil.GitTest do
  use ExUnit.Case, async: true

  alias Vigil.Git

  setup do
    vault = Vigil.FixtureVault.build(remote: true)
    {tmp, remote} = vault

    on_exit(fn ->
      Vigil.FixtureVault.cleanup(tmp)
      File.rm_rf(remote)
    end)

    {:ok, vault: tmp, remote: remote}
  end

  test "log_metadata returns created_at/updated_at/last_author from a single git log call", %{
    vault: vault
  } do
    meta = Git.log_metadata(vault)

    assert %{created_at: %DateTime{}, updated_at: %DateTime{}, last_author: "Daniel"} =
             meta["bike/terra-speed.md"]
  end

  test "add_commit authors as vigil and push succeeds", %{vault: vault} do
    File.write!(Path.join(vault, "bike/neu.md"), "---\ntype: reference\n---\n# Neu\ntext\n")

    assert {:ok, %{updated_at: %DateTime{}, last_author: "vigil"}} =
             Git.add_commit(vault, "bike/neu.md", "create: bike/neu.md")

    assert :ok = Git.push(vault, "origin")

    {out, 0} = System.cmd("git", ["log", "-1", "--format=%an <%ae>"], cd: vault)
    assert String.trim(out) == "vigil <vigil@local>"
  end

  test "push failure is reported without losing the local commit", %{vault: vault} do
    File.write!(Path.join(vault, "bike/neu2.md"), "---\ntype: reference\n---\n# Neu2\ntext\n")
    {:ok, _} = Git.add_commit(vault, "bike/neu2.md", "create: bike/neu2.md")

    assert {:error, _reason} = Git.push(vault, "nonexistent-remote")

    {out, 0} = System.cmd("git", ["log", "-1", "--format=%s"], cd: vault)
    assert String.trim(out) == "create: bike/neu2.md"
  end

  test "pull/2 fast-forwards from the given remote name", %{vault: vault, remote: remote} do
    other = vault <> "_other_clone"
    {_out, 0} = System.cmd("git", ["clone", "-q", remote, other])
    File.write!(Path.join(other, "note.md"), "---\ntype: reference\n---\n# Note\ntext\n")
    {_out, 0} = System.cmd("git", ["add", "-A"], cd: other)

    {_out, 0} =
      System.cmd(
        "git",
        ["-c", "user.name=x", "-c", "user.email=x@x", "commit", "-q", "-m", "extern"],
        cd: other
      )

    {_out, 0} = System.cmd("git", ["push", "-q"], cd: other)
    File.rm_rf(other)

    assert :ok = Git.pull(vault, "origin")
    assert File.exists?(Path.join(vault, "note.md"))
  end

  test "pull/2 against a nonexistent remote returns an error", %{vault: vault} do
    assert {:error, _reason} = Git.pull(vault, "nonexistent-remote")
  end

  test "remove_commit stages, commits, and removes the file", %{vault: vault} do
    assert :ok = Git.remove_commit(vault, "bike/terra-speed.md", "delete: bike/terra-speed.md")
    refute File.exists?(Path.join(vault, "bike/terra-speed.md"))

    {out, 0} = System.cmd("git", ["log", "-1", "--format=%s"], cd: vault)
    assert String.trim(out) == "delete: bike/terra-speed.md"
  end

  test "move_commit renames the file and commits both paths", %{vault: vault} do
    assert {:ok, %{updated_at: %DateTime{}, last_author: "vigil"}} =
             Git.move_commit(
               vault,
               "bike/terra-speed.md",
               "bike/terra-speed-neu.md",
               "move: bike/terra-speed.md -> bike/terra-speed-neu.md"
             )

    refute File.exists?(Path.join(vault, "bike/terra-speed.md"))
    assert File.exists?(Path.join(vault, "bike/terra-speed-neu.md"))
  end
end
