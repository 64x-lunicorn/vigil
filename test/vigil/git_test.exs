defmodule Vigil.GitTest do
  use ExUnit.Case, async: true

  alias Vigil.Git
  alias Vigil.Git.CommitLog

  @moduledoc """
  The git contract, and the only file in the suite that touches a repository
  (docs/design.md, "Git is reached through a value").

  Everything git actually owns is asserted here, against both adapters: what a
  commit is authored as, what a failed push leaves behind, that a move and a
  delete are git operations, and that a first commit is what `log_metadata`
  reports as a creation date. Every other test in the suite asserts something
  about vigil and merely used to travel through git to do it.
  """

  setup do
    {vault, remote} = Vigil.FixtureVault.build(remote: true)
    on_exit(fn -> Vigil.FixtureVault.cleanup(vault) end)
    {:ok, vault: vault, remote: remote}
  end

  defp real_git(_context), do: {:ok, git: Git.over_repository()}

  defp commit_log(%{vault: vault}) do
    {git, log} = CommitLog.recording(vault, remote: "origin")
    {:ok, git: git, log: log}
  end

  defp note(vault, path, body) do
    abs = Path.join(vault, path)
    File.mkdir_p!(Path.dirname(abs))
    File.write!(abs, "---\ntype: reference\n---\n# #{body}\ntext\n")
    path
  end

  # One body per claim, run against the repository and against the commit log.
  # The two agreeing is what lets every other test in the suite stay off git;
  # the two drifting apart is the one thing that could go wrong with a second
  # adapter, so it is tested rather than assumed.
  for {adapter, setup_fun} <- [
        {"the repository", :real_git},
        {"the commit log", :commit_log}
      ] do
    describe "#{adapter}" do
      setup(setup_fun)

      test "log_metadata reports what the vault was committed with", %{git: git, vault: vault} do
        meta = git.log_metadata.(vault)

        assert %{created_at: %DateTime{}, updated_at: %DateTime{}, last_author: "Daniel"} =
                 meta["bike/terra-speed.md"]
      end

      test "add_commit authors as vigil and push succeeds", %{git: git, vault: vault} do
        path = note(vault, "bike/new.md", "New")

        assert {:ok, %{updated_at: %DateTime{}, last_author: "vigil"}} =
                 git.add_commit.(vault, path, "create: #{path}")

        assert :ok = git.push.(vault, "origin")
      end

      # Creation date = first commit (docs/design.md, principle 3), read back
      # out of the same metadata a load builds every note's `created_at` from.
      test "a first commit is what log_metadata reports as the creation date", %{
        git: git,
        vault: vault
      } do
        path = note(vault, "bike/fresh.md", "Fresh")

        {:ok, commit_meta} = git.add_commit.(vault, path, "create: #{path}")

        assert %{created_at: created_at, updated_at: updated_at, last_author: "vigil"} =
                 git.log_metadata.(vault)[path]

        assert DateTime.compare(created_at, updated_at) == :eq
        assert DateTime.compare(created_at, commit_meta.updated_at) == :eq
      end

      test "push failure is reported without losing the local commit", %{git: git, vault: vault} do
        path = note(vault, "bike/new2.md", "New2")
        {:ok, _} = git.add_commit.(vault, path, "create: #{path}")

        assert {:error, _reason} = git.push.(vault, "nonexistent-remote")

        assert %{last_author: "vigil"} = git.log_metadata.(vault)[path]
        assert File.exists?(Path.join(vault, path))
      end

      test "pull fast-forwards from the vault's remote", %{git: git, vault: vault} do
        assert :ok = git.pull.(vault, "origin")
      end

      test "pull against a nonexistent remote returns an error", %{git: git, vault: vault} do
        assert {:error, _reason} = git.pull.(vault, "nonexistent-remote")
      end

      test "remove_commit removes the file", %{git: git, vault: vault} do
        assert :ok =
                 git.remove_commit.(vault, "bike/terra-speed.md", "delete: bike/terra-speed.md")

        refute File.exists?(Path.join(vault, "bike/terra-speed.md"))
      end

      test "move_commit renames the file and commits it at its new path", %{
        git: git,
        vault: vault
      } do
        assert {:ok, %{updated_at: %DateTime{}, last_author: "vigil"}} =
                 git.move_commit.(
                   vault,
                   "bike/terra-speed.md",
                   "bike/terra-speed-new.md",
                   "move: bike/terra-speed.md -> bike/terra-speed-new.md"
                 )

        refute File.exists?(Path.join(vault, "bike/terra-speed.md"))
        assert File.exists?(Path.join(vault, "bike/terra-speed-new.md"))

        # A rename is neither an addition nor a modification: git reports it
        # as `R`, and log_metadata's `--diff-filter=AM` drops it. The moved
        # note's creation date survives in Vigil.Index, which is what carries
        # it across a move (Vigil.Index.move/3) — not in the commit log.
        refute git.log_metadata.(vault)["bike/terra-speed-new.md"]
      end
    end
  end

  # What only a repository can be asked. The identity a commit carries down to
  # its email address, the ambient configuration it has to survive, and a pull
  # that actually brings something back.
  describe "the repository alone" do
    setup :real_git

    test "a commit carries vigil's full identity", %{git: git, vault: vault} do
      path = note(vault, "bike/new.md", "New")
      {:ok, _} = git.add_commit.(vault, path, "create: #{path}")

      {out, 0} = System.cmd("git", ["log", "-1", "--format=%an <%ae>"], cd: vault)
      assert String.trim(out) == "vigil <vigil@local>"
    end

    test "commits succeed even when the repo config forces signing with a broken signer", %{
      git: git,
      vault: vault
    } do
      # The service user has no signing key. A commit.gpgsign=true coming from
      # outside (a rebuilt container, an edited ~/.gitconfig, a desktop agent)
      # would, without the -c safeguard in Vigil.Git, abort every write with
      # "failed to sign the data".
      {_, 0} = System.cmd("git", ["config", "commit.gpgsign", "true"], cd: vault)
      {_, 0} = System.cmd("git", ["config", "gpg.program", "/bin/false"], cd: vault)

      note(vault, "bike/signed.md", "S")

      assert {:ok, %{last_author: "vigil"}} =
               git.add_commit.(vault, "bike/signed.md", "create: bike/signed.md")

      note(vault, "bike/signed2.md", "S2")
      {:ok, _} = git.add_commit.(vault, "bike/signed2.md", "create: bike/signed2.md")

      assert {:ok, _} =
               git.move_commit.(vault, "bike/signed2.md", "bike/signed3.md", "move: s2 -> s3")

      assert :ok = git.remove_commit.(vault, "bike/signed3.md", "delete: bike/signed3.md")
    end

    test "delete and move are git operations, not filesystem calls", %{git: git, vault: vault} do
      assert :ok = git.remove_commit.(vault, "bike/terra-speed.md", "delete: bike/terra-speed.md")

      {out, 0} = System.cmd("git", ["log", "-1", "--format=%s"], cd: vault)
      assert String.trim(out) == "delete: bike/terra-speed.md"

      {out, 0} = System.cmd("git", ["status", "--porcelain"], cd: vault)
      assert String.trim(out) == ""
    end

    test "pull/2 brings a commit made elsewhere into the vault", %{
      git: git,
      vault: vault,
      remote: remote
    } do
      other = vault <> "_other_clone"
      {_out, 0} = System.cmd("git", ["clone", "-q", remote, other])
      File.write!(Path.join(other, "note.md"), "---\ntype: reference\n---\n# Note\ntext\n")
      {_out, 0} = System.cmd("git", ["add", "-A"], cd: other)

      {_out, 0} =
        System.cmd(
          "git",
          [
            "-c",
            "user.name=x",
            "-c",
            "user.email=x@x",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-q",
            "-m",
            "external"
          ],
          cd: other
        )

      {_out, 0} = System.cmd("git", ["push", "-q"], cd: other)
      File.rm_rf(other)

      assert :ok = git.pull.(vault, "origin")
      assert File.exists?(Path.join(vault, "note.md"))
    end
  end

  # The log is the point of the second adapter: an order that used to need a
  # repository to observe can be asked for. Vigil.StoreTest is where the write
  # sequence itself is pinned.
  describe "the commit log's record" do
    setup :commit_log

    test "records what it was asked to do, in the order it was asked", %{
      git: git,
      vault: vault,
      log: log
    } do
      path = note(vault, "bike/new.md", "New")
      {:ok, _} = git.add_commit.(vault, path, "create: #{path}")
      :ok = git.push.(vault, "origin")

      assert CommitLog.calls(log) == [
               {:add_commit, path, "create: #{path}"},
               {:push, "origin"}
             ]
    end
  end
end
