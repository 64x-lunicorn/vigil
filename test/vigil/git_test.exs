defmodule Vigil.GitTest do
  use ExUnit.Case, async: true

  alias Vigil.{Commit, Git}
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
    vault = Vigil.FixtureVault.build()
    on_exit(fn -> Vigil.FixtureVault.cleanup(vault) end)
    {:ok, vault: vault}
  end

  # The one repository the suite still builds, and it is built here.
  defp real_git(%{vault: vault}) do
    {:ok, git: Git.over_repository(), remote: Vigil.GitRepo.init(vault, remote: true)}
  end

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

  # What a write asks for, as one step: stage the path, commit it.
  defp add_commit(git, vault, path, message) do
    :ok = git.add.(vault, [path])
    git.commit.(vault, [path], message)
  end

  defp remove_commit(git, vault, path, message) do
    with :ok <- git.remove.(vault, [path]),
         {:ok, _} <- git.commit.(vault, [path], message),
         do: :ok
  end

  defp move_commit(git, vault, from, to, message) do
    :ok = git.move.(vault, from, to)
    git.commit.(vault, [from, to], message)
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

      test "add and commit author as vigil and push succeeds", %{git: git, vault: vault} do
        path = note(vault, "bike/new.md", "New")

        assert {:ok, %{updated_at: %DateTime{}, last_author: "vigil"}} =
                 add_commit(git, vault, path, "create: #{path}")

        assert :ok = git.push.(vault, "origin", "main")
      end

      # Creation date = first commit (docs/design.md, principle 3), read back
      # out of the same metadata a load builds every note's `created_at` from.
      test "a first commit is what log_metadata reports as the creation date", %{
        git: git,
        vault: vault
      } do
        path = note(vault, "bike/fresh.md", "Fresh")

        {:ok, commit_meta} = add_commit(git, vault, path, "create: #{path}")

        assert %{created_at: created_at, updated_at: updated_at, last_author: "vigil"} =
                 git.log_metadata.(vault)[path]

        assert DateTime.compare(created_at, updated_at) == :eq
        assert DateTime.compare(created_at, commit_meta.updated_at) == :eq
      end

      test "push failure is reported without losing the local commit", %{git: git, vault: vault} do
        path = note(vault, "bike/new2.md", "New2")
        {:ok, _} = add_commit(git, vault, path, "create: #{path}")

        assert {:error, _reason} = git.push.(vault, "nonexistent-remote", "main")

        assert %{last_author: "vigil"} = git.log_metadata.(vault)[path]
        assert File.exists?(Path.join(vault, path))
      end

      # A path is a path, never a pattern: a note a human named `*.md` is one
      # note, and removing it removes nothing else.
      test "a note named like a glob is removed alone", %{git: git, vault: vault} do
        glob = note(vault, "bike/*.md", "Glob")
        {:ok, _} = add_commit(git, vault, glob, "create: #{glob}")

        assert :ok = Commit.delete(git, vault, glob, "delete: #{glob}")

        refute File.exists?(Path.join(vault, glob))
        assert File.exists?(Path.join(vault, "bike/terra-speed.md"))
        assert File.exists?(Path.join(vault, "bike/via-carolina.md"))
        assert %{last_author: "Daniel"} = git.log_metadata.(vault)["bike/terra-speed.md"]
      end

      test "fetch from the vault's remote succeeds", %{git: git, vault: vault} do
        assert :ok = git.fetch.(vault, "origin", "main")
      end

      @tag :capture_log
      test "push and fetch against a branch the vault does not have return an error", %{
        git: git,
        vault: vault
      } do
        assert {:error, _reason} = git.push.(vault, "origin", "no-such-branch")
        assert {:error, _reason} = git.fetch.(vault, "origin", "no-such-branch")
      end

      test "tracking reports the checked-out branch, the remotes and each upstream", %{
        git: git,
        vault: vault
      } do
        assert {:ok,
                %{head: "main", remotes: ["origin"], branches: %{"main" => {"origin", "main"}}}} =
                 git.tracking.(vault)
      end

      test "remove and commit remove the file", %{git: git, vault: vault} do
        assert :ok =
                 remove_commit(git, vault, "bike/terra-speed.md", "delete: bike/terra-speed.md")

        refute File.exists?(Path.join(vault, "bike/terra-speed.md"))
      end

      test "move and commit rename the file and commits it at its new path", %{
        git: git,
        vault: vault
      } do
        before = git.log_metadata.(vault)

        assert {:ok, %{updated_at: %DateTime{}, last_author: "vigil"}} =
                 move_commit(
                   git,
                   vault,
                   "bike/terra-speed.md",
                   "bike/terra-speed-new.md",
                   "move: bike/terra-speed.md -> bike/terra-speed-new.md"
                 )

        refute File.exists?(Path.join(vault, "bike/terra-speed.md"))
        assert File.exists?(Path.join(vault, "bike/terra-speed-new.md"))

        # A rename carries the note's history to its new path: the creation
        # date a restart rebuilds the index from survives the move, and the
        # old path no longer answers.
        meta = git.log_metadata.(vault)
        refute meta["bike/terra-speed.md"]

        assert %{created_at: created_at, updated_at: updated_at, last_author: "vigil"} =
                 meta["bike/terra-speed-new.md"]

        assert DateTime.compare(created_at, updated_at) in [:lt, :eq]
        assert created_at == before["bike/terra-speed.md"].created_at
      end

      # docs/design.md, "A human edit arrives as a commit, never as a file":
      # what another clone pushed is seen after a fetch and adopted by a
      # fast-forward, and nothing before the fast-forward touches the vault.
      test "a commit pushed elsewhere is behind after a fetch, and a fast-forward adopts it",
           %{git: git, vault: vault} = ctx do
        push_from_elsewhere(ctx, "bike/from-elsewhere.md")

        assert {:ok, %{ahead: 0, behind: 0}} = git.divergence.(vault, "origin", "main")
        assert :ok = git.fetch.(vault, "origin", "main")
        assert {:ok, %{ahead: 0, behind: 1}} = git.divergence.(vault, "origin", "main")
        refute File.exists?(Path.join(vault, "bike/from-elsewhere.md"))

        assert :ok = git.fast_forward.(vault, "origin", "main")

        assert File.exists?(Path.join(vault, "bike/from-elsewhere.md"))
        assert {:ok, %{ahead: 0, behind: 0}} = git.divergence.(vault, "origin", "main")
        assert %{last_author: "x"} = git.log_metadata.(vault)["bike/from-elsewhere.md"]
      end

      test "a commit not yet pushed counts as ahead, and a push brings it to zero", %{
        git: git,
        vault: vault
      } do
        path = note(vault, "bike/ahead.md", "Ahead")
        {:ok, _} = add_commit(git, vault, path, "create: #{path}")

        assert {:ok, %{ahead: 1, behind: 0}} = git.divergence.(vault, "origin", "main")
        assert :ok = git.push.(vault, "origin", "main")
        assert {:ok, %{ahead: 0, behind: 0}} = git.divergence.(vault, "origin", "main")
      end

      test "a push is refused while the remote holds a commit the vault lacks",
           %{git: git, vault: vault} = ctx do
        push_from_elsewhere(ctx, "bike/from-elsewhere.md")
        path = note(vault, "bike/mine.md", "Mine")
        {:ok, _} = add_commit(git, vault, path, "create: #{path}")

        assert {:error, _reason} = git.push.(vault, "origin", "main")
      end

      # Principle 2: no merge. With a commit of its own the vault cannot be
      # fast-forwarded, and it is left exactly as it was.
      test "a fast-forward is refused while the vault holds a commit of its own",
           %{git: git, vault: vault} = ctx do
        push_from_elsewhere(ctx, "bike/from-elsewhere.md")
        path = note(vault, "bike/mine.md", "Mine")
        {:ok, _} = add_commit(git, vault, path, "create: #{path}")
        :ok = git.fetch.(vault, "origin", "main")

        assert {:ok, %{ahead: 1, behind: 1}} = git.divergence.(vault, "origin", "main")
        assert {:error, _reason} = git.fast_forward.(vault, "origin", "main")
        refute File.exists?(Path.join(vault, "bike/from-elsewhere.md"))
      end

      # docs/design.md, principle 2: vigil's own unpushed commits are
      # rebased onto what another clone pushed — never merged — and the push
      # that follows is a fast-forward.
      test "a rebase puts the vault's commit on top of one pushed elsewhere, and the push succeeds",
           %{git: git, vault: vault} = ctx do
        push_from_elsewhere(ctx, "bike/from-elsewhere.md")
        path = note(vault, "bike/mine.md", "Mine")
        {:ok, _} = add_commit(git, vault, path, "create: #{path}")
        :ok = git.fetch.(vault, "origin", "main")

        assert :ok = git.rebase.(vault, "origin", "main")

        assert File.exists?(Path.join(vault, "bike/from-elsewhere.md"))
        assert File.exists?(Path.join(vault, path))
        assert {:ok, %{ahead: 1, behind: 0}} = git.divergence.(vault, "origin", "main")
        assert :ok = git.push.(vault, "origin", "main")
        assert {:ok, %{ahead: 0, behind: 0}} = git.divergence.(vault, "origin", "main")

        meta = git.log_metadata.(vault)
        assert %{last_author: "vigil"} = meta[path]
        assert %{last_author: "x"} = meta["bike/from-elsewhere.md"]
      end

      test "a rebase with nothing fetched leaves the vault's commit as it was", %{
        git: git,
        vault: vault
      } do
        path = note(vault, "bike/mine.md", "Mine")
        {:ok, _} = add_commit(git, vault, path, "create: #{path}")
        :ok = git.fetch.(vault, "origin", "main")

        assert :ok = git.rebase.(vault, "origin", "main")
        assert {:ok, %{ahead: 1, behind: 0}} = git.divergence.(vault, "origin", "main")
      end

      # A real conflict is not vigil's to resolve: the rebase stops, names the
      # path, and aborting it puts the vault back exactly as it was — its
      # commit local, the other side's still only on the remote.
      test "a rebase over the same note stops at a conflict, and aborting it keeps the vault's commit",
           %{git: git, vault: vault} = ctx do
        path = "bike/terra-speed.md"
        push_from_elsewhere(ctx, path, "---\ntype: reference\n---\n# Theirs\nfrom elsewhere\n")
        File.write!(Path.join(vault, path), "---\ntype: reference\n---\n# Ours\nfrom vigil\n")
        {:ok, _} = add_commit(git, vault, path, "update: #{path}")
        :ok = git.fetch.(vault, "origin", "main")

        assert {:conflict, [^path]} = git.rebase.(vault, "origin", "main")
        assert :ok = git.abort_rebase.(vault)

        assert File.read!(Path.join(vault, path)) =~ "from vigil"
        assert {:ok, %{ahead: 1, behind: 1}} = git.divergence.(vault, "origin", "main")
        assert %{last_author: "vigil"} = git.log_metadata.(vault)[path]
        assert {:error, _reason} = git.push.(vault, "origin", "main")
      end

      test "aborting when no rebase is in progress is an error", %{git: git, vault: vault} do
        assert {:error, _reason} = git.abort_rebase.(vault)
      end

      @tag :capture_log
      test "fetch and divergence against a remote the vault does not have are errors", %{
        git: git,
        vault: vault
      } do
        assert {:error, _reason} = git.fetch.(vault, "nonexistent-remote", "main")
        assert {:error, _reason} = git.divergence.(vault, "nonexistent-remote", "main")
      end
    end
  end

  describe "the repository, a move with rewrites" do
    setup :real_git

    test "is one commit holding the rename and every rewritten note", %{git: git, vault: vault} do
      assert {:ok, _} =
               Commit.move(git, vault, "bike/terra-speed.md", "bike/terra-40c.md", "move", [
                 {"bike/via-carolina.md", "# Via\n[[terra-40c]]\n"}
               ])

      {out, 0} =
        System.cmd("git", ["show", "--name-status", "--format=%s", "HEAD"], cd: vault)

      assert out =~ "move"
      assert out =~ ~r/R\d+\tbike\/terra-speed.md\tbike\/terra-40c.md/
      assert out =~ "M\tbike/via-carolina.md"
      {status, 0} = System.cmd("git", ["status", "--porcelain"], cd: vault)
      assert status == ""
    end
  end

  # A commit another clone pushed, authored `x`: through a real second clone
  # for the repository, recorded as such for the commit log.
  @elsewhere "---\ntype: reference\n---\n# Elsewhere\n"

  defp push_from_elsewhere(ctx, path, content \\ @elsewhere)

  defp push_from_elsewhere(%{log: log}, path, content) do
    CommitLog.push_from_elsewhere(log, path, content, "x")
  end

  defp push_from_elsewhere(%{remote: remote, vault: vault}, path, content) do
    other = vault <> "_elsewhere"
    {_out, 0} = System.cmd("git", ["clone", "-q", remote, other])
    File.mkdir_p!(Path.dirname(Path.join(other, path)))
    File.write!(Path.join(other, path), content)
    {_out, 0} = System.cmd("git", ["add", "-A"], cd: other)

    {_out, 0} =
      System.cmd(
        "git",
        ~w(-c user.name=x -c user.email=x@x -c commit.gpgsign=false commit -q -m elsewhere),
        cd: other
      )

    {_out, 0} = System.cmd("git", ["push", "-q"], cd: other)
    File.rm_rf!(other)
    :ok
  end

  # Everything on disk under the vault but git's own directory, with its
  # content: a rollback that leaves a file, a directory or a temporary file
  # behind differs here from the vault it started with.
  defp tree(vault) do
    Path.join(vault, "**")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&String.contains?(Path.relative_to(&1, vault), ".git"))
    |> Map.new(fn abs ->
      {Path.relative_to(abs, vault), if(File.dir?(abs), do: :dir, else: File.read!(abs))}
    end)
  end

  defp failing_commit(git), do: %{git | commit: fn _, _, _ -> {:error, "boom"} end}

  # docs/design.md, "A failed commit leaves the vault as it was". The commit is
  # made to fail through the value, after the staging it follows has happened,
  # and what the working tree and the staging area hold afterwards is compared
  # with what they held before.
  for {adapter, setup_fun} <- [
        {"the repository", :real_git},
        {"the commit log", :commit_log}
      ] do
    describe "#{adapter}, when the commit fails" do
      setup(setup_fun)

      setup %{git: git, vault: vault} do
        {:ok, failing: failing_commit(git), before: tree(vault)}
      end

      test "a write to an existing note leaves it as it was", %{
        git: git,
        failing: failing,
        vault: vault,
        before: before
      } do
        path = "bike/terra-speed.md"
        {:ok, index} = git.snapshot_index.(vault, [path])

        assert {:error, "git commit failed: boom"} =
                 Commit.write(failing, vault, path, "# Replaced\n", "update: #{path}")

        assert tree(vault) == before
        assert git.snapshot_index.(vault, [path]) == {:ok, index}
      end

      test "a new note in a new directory leaves neither behind", %{
        git: git,
        failing: failing,
        vault: vault,
        before: before
      } do
        path = "bike/archive/2026/new.md"
        {:ok, index} = git.snapshot_index.(vault, [path])

        assert {:error, "git commit failed: boom"} =
                 Commit.write(failing, vault, path, "# New\n", "create: #{path}")

        assert tree(vault) == before
        assert git.snapshot_index.(vault, [path]) == {:ok, index}
      end

      test "a removal leaves the note where it was", %{
        git: git,
        failing: failing,
        vault: vault,
        before: before
      } do
        path = "bike/via-carolina.md"
        {:ok, index} = git.snapshot_index.(vault, [path])

        assert {:error, "git rm/commit failed: boom"} =
                 Commit.delete(failing, vault, path, "delete: #{path}")

        assert tree(vault) == before
        assert git.snapshot_index.(vault, [path]) == {:ok, index}
      end

      # `git rm` takes a directory it empties with it.
      test "a removal that empties its directory leaves both where they were", %{
        git: git,
        failing: failing,
        vault: vault
      } do
        path = note(vault, "garden/beds/only.md", "Only")
        {:ok, _} = add_commit(git, vault, path, "create: #{path}")
        before = tree(vault)

        assert {:error, "git rm/commit failed: boom"} =
                 Commit.delete(failing, vault, path, "delete: #{path}")

        assert tree(vault) == before
      end

      test "a move leaves the note at its old path and nothing at the new one", %{
        git: git,
        failing: failing,
        vault: vault,
        before: before
      } do
        paths = ["bike/via-carolina.md", "bike/archive/via-carolina.md"]
        {:ok, index} = git.snapshot_index.(vault, paths)

        assert {:error, "git mv/commit failed: boom"} =
                 Commit.move(failing, vault, hd(paths), List.last(paths), "move: via-carolina")

        assert tree(vault) == before
        assert git.snapshot_index.(vault, paths) == {:ok, index}
      end

      test "a move with rewrites leaves the note and every linking note as they were", %{
        git: git,
        failing: failing,
        vault: vault,
        before: before
      } do
        paths = ["bike/via-carolina.md", "bike/terra-speed.md", "bike/archive/via-carolina.md"]
        {:ok, index} = git.snapshot_index.(vault, paths)

        rewrites = [
          {"bike/terra-speed.md", "# Rewritten\n"},
          {"bike/archive/via-carolina.md", "# Rewritten too\n"}
        ]

        assert {:error, "git mv/commit failed: boom"} =
                 Commit.move(
                   failing,
                   vault,
                   "bike/via-carolina.md",
                   "bike/archive/via-carolina.md",
                   "move: via-carolina",
                   rewrites
                 )

        assert tree(vault) == before
        assert git.snapshot_index.(vault, paths) == {:ok, index}
      end

      # What the failure would otherwise have left staged is swept into the
      # next commit under that commit's message.
      test "the next commit carries only its own change", %{
        git: git,
        failing: failing,
        vault: vault
      } do
        {:error, _} = Commit.delete(failing, vault, "bike/via-carolina.md", "delete")

        assert {:ok, _} =
                 Commit.write(git, vault, "bike/next.md", "# Next\n", "create: bike/next.md")

        assert File.exists?(Path.join(vault, "bike/via-carolina.md"))
        assert git.log_metadata.(vault)["bike/via-carolina.md"].last_author == "Daniel"
      end
    end
  end

  # What only a repository can be asked. The identity a commit carries down to
  # its email address, the ambient configuration it has to survive, and a rebase
  # onto the kind of history only a real clone makes.
  describe "the repository alone" do
    setup :real_git

    test "a commit carries vigil's full identity", %{git: git, vault: vault} do
      path = note(vault, "bike/new.md", "New")
      {:ok, _} = add_commit(git, vault, path, "create: #{path}")

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
               add_commit(git, vault, "bike/signed.md", "create: bike/signed.md")

      note(vault, "bike/signed2.md", "S2")
      {:ok, _} = add_commit(git, vault, "bike/signed2.md", "create: bike/signed2.md")

      assert {:ok, _} =
               move_commit(git, vault, "bike/signed2.md", "bike/signed3.md", "move: s2 -> s3")

      assert :ok = remove_commit(git, vault, "bike/signed3.md", "delete: bike/signed3.md")
    end

    # git quotes every non-ASCII path under the default core.quotePath=true;
    # a German vault is full of them, and a quoted path matches no note.
    test "log_metadata reports non-ASCII paths as the filesystem spells them", %{
      git: git,
      vault: vault
    } do
      path = note(vault, "home/Übersicht Heizöl.md", "Übersicht")
      {:ok, _} = add_commit(git, vault, path, "create: #{path}")

      assert %{created_at: %DateTime{}, last_author: "vigil"} = git.log_metadata.(vault)[path]
    end

    test "committing unchanged content succeeds without a new commit", %{
      git: git,
      vault: vault
    } do
      {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: vault)

      assert {:ok, %{updated_at: %DateTime{}, last_author: "Daniel"}} =
               add_commit(git, vault, "bike/terra-speed.md", "update: unchanged")

      assert {^head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: vault)
    end

    # What git's own staging area says, beyond what the value hands back: the
    # whole of `git status`, and the index entries of every path, unchanged.
    test "a failed commit leaves git status and the index as they were", %{
      git: git,
      vault: vault
    } do
      failing = failing_commit(git)
      status = fn -> System.cmd("git", ["status", "--porcelain"], cd: vault) end
      stage = fn -> System.cmd("git", ["ls-files", "--stage"], cd: vault) end
      {status_before, stage_before} = {status.(), stage.()}

      {:error, _} = Commit.write(failing, vault, "bike/terra-speed.md", "# X\n", "update")
      {:error, _} = Commit.write(failing, vault, "bike/new/x.md", "# X\n", "create")
      {:error, _} = Commit.delete(failing, vault, "bike/via-carolina.md", "delete")
      {:error, _} = Commit.move(failing, vault, "bike/via-carolina.md", "bike/b/v.md", "move")

      {:error, _} =
        Commit.move(failing, vault, "bike/via-carolina.md", "bike/b/v.md", "move", [
          {"bike/terra-speed.md", "# X\n"}
        ])

      assert status.() == status_before
      assert stage.() == stage_before
    end

    # The failure the value simulates, as a repository produces it.
    test "a commit refused by a hook leaves the vault as it was", %{git: git, vault: vault} do
      hook = Path.join(vault, ".git/hooks/pre-commit")
      File.write!(hook, "#!/bin/sh\necho refused by hook\nexit 1\n")
      File.chmod!(hook, 0o755)
      before = tree(vault)

      assert {:error, "git rm/commit failed: refused by hook" <> _} =
               Commit.delete(git, vault, "bike/via-carolina.md", "delete")

      assert tree(vault) == before
      {out, 0} = System.cmd("git", ["status", "--porcelain"], cd: vault)
      assert out == ""
    end

    test "delete and move are git operations, not filesystem calls", %{git: git, vault: vault} do
      assert :ok = remove_commit(git, vault, "bike/terra-speed.md", "delete: bike/terra-speed.md")

      {out, 0} = System.cmd("git", ["log", "-1", "--format=%s"], cd: vault)
      assert String.trim(out) == "delete: bike/terra-speed.md"

      {out, 0} = System.cmd("git", ["status", "--porcelain"], cd: vault)
      assert String.trim(out) == ""
    end

    # What Obsidian Git's "merge" sync puts on the remote: a merge commit.
    # vigil does not make one, and rebases onto one like onto any other.
    test "a rebase onto a merge commit pushed elsewhere", %{
      git: git,
      vault: vault,
      remote: remote
    } do
      other = vault <> "_merging_clone"
      {_out, 0} = System.cmd("git", ["clone", "-q", remote, other])
      as_x = ~w(-c user.name=x -c user.email=x@x -c commit.gpgsign=false)
      {_out, 0} = System.cmd("git", ["checkout", "-q", "-b", "side"], cd: other)
      File.write!(Path.join(other, "side.md"), "# Side\n")
      {_out, 0} = System.cmd("git", ["add", "-A"], cd: other)
      {_out, 0} = System.cmd("git", as_x ++ ~w(commit -q -m side), cd: other)
      {_out, 0} = System.cmd("git", ["checkout", "-q", "main"], cd: other)
      File.write!(Path.join(other, "main.md"), "# Main\n")
      {_out, 0} = System.cmd("git", ["add", "-A"], cd: other)
      {_out, 0} = System.cmd("git", as_x ++ ~w(commit -q -m main), cd: other)
      {_out, 0} = System.cmd("git", as_x ++ ~w(merge -q --no-ff --no-edit side), cd: other)
      {_out, 0} = System.cmd("git", ["push", "-q", "origin", "main"], cd: other)
      File.rm_rf!(other)

      path = note(vault, "bike/mine.md", "Mine")
      {:ok, _} = add_commit(git, vault, path, "create: #{path}")
      :ok = git.fetch.(vault, "origin", "main")

      assert :ok = git.rebase.(vault, "origin", "main")
      assert :ok = git.push.(vault, "origin", "main")

      for file <- ["side.md", "main.md", path], do: assert(File.exists?(Path.join(vault, file)))
      {parents, 0} = System.cmd("git", ["log", "-1", "--format=%p", "HEAD~1"], cd: vault)
      assert parents |> String.split() |> length() == 2
    end

    # A hook in the vault's clone is not vigil's to satisfy, and a rebase
    # rewrites vigil's commits as vigil, unsigned, whatever the ambient
    # configuration says.
    test "a rebase runs no hook and rewrites the vault's commit as vigil, unsigned", %{
      git: git,
      vault: vault,
      remote: remote
    } do
      hook = Path.join(vault, ".git/hooks/pre-rebase")
      File.write!(hook, "#!/bin/sh\necho refused by hook\nexit 1\n")
      File.chmod!(hook, 0o755)
      {_, 0} = System.cmd("git", ["config", "commit.gpgsign", "true"], cd: vault)
      {_, 0} = System.cmd("git", ["config", "gpg.program", "/bin/false"], cd: vault)
      push_from_elsewhere(%{remote: remote, vault: vault}, "bike/from-elsewhere.md")
      path = note(vault, "bike/mine.md", "Mine")
      {:ok, _} = add_commit(git, vault, path, "create: #{path}")
      :ok = git.fetch.(vault, "origin", "main")

      assert :ok = git.rebase.(vault, "origin", "main")

      {out, 0} = System.cmd("git", ["log", "-1", "--format=%an <%ae>|%cn <%ce>"], cd: vault)
      assert String.trim(out) == "vigil <vigil@local>|vigil <vigil@local>"
    end
  end

  # A vault on another branch than `main`: every call that names a branch
  # names the one it is handed, and nothing falls back to `main`.
  describe "a repository on master" do
    setup %{vault: vault} do
      {:ok,
       git: Git.over_repository(),
       remote: Vigil.GitRepo.init(vault, remote: true, branch: "master")}
    end

    test "tracking reports master and its upstream", %{git: git, vault: vault} do
      assert {:ok, %{head: "master", branches: branches}} = git.tracking.(vault)
      assert branches == %{"master" => {"origin", "master"}}
    end

    test "a write pushes master to the remote", %{git: git, vault: vault, remote: remote} do
      path = note(vault, "bike/master.md", "Master")
      {:ok, _} = add_commit(git, vault, path, "create: #{path}")

      assert :ok = git.push.(vault, "origin", "master")
      assert :ok = git.fetch.(vault, "origin", "master")
      assert {:ok, %{ahead: 0, behind: 0}} = git.divergence.(vault, "origin", "master")

      {local, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: vault)
      {pushed, 0} = System.cmd("git", ["--git-dir", remote, "rev-parse", "master"])
      assert pushed == local
    end

    test "a branch without an upstream is reported as having none", %{git: git, vault: vault} do
      {_, 0} = System.cmd("git", ["branch", "draft"], cd: vault)

      assert {:ok, %{branches: %{"draft" => nil}}} = git.tracking.(vault)
    end

    test "a detached HEAD has no checked-out branch", %{git: git, vault: vault} do
      {_, 0} = System.cmd("git", ["checkout", "-q", "--detach"], cd: vault)

      assert {:ok, %{head: nil}} = git.tracking.(vault)
    end

    test "a directory that is not a git clone is an error", %{git: git} do
      dir =
        Path.join(System.tmp_dir!(), "vigil_not_a_clone_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      assert {:error, _reason} = git.tracking.(dir)
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
      {:ok, _} = add_commit(git, vault, path, "create: #{path}")
      :ok = git.push.(vault, "origin", "main")

      assert CommitLog.calls(log) == [
               {:add, [path]},
               {:commit, [path], "create: #{path}"},
               {:push, "origin", "main"}
             ]
    end
  end
end
