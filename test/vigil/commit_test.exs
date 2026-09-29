defmodule Vigil.CommitTest do
  use ExUnit.Case, async: true

  @moduledoc """
  How `Vigil.Commit` puts a note on disk. What a failed commit leaves behind is
  held to both git adapters in `test/vigil/git_test.exs`; this is the
  filesystem half: a note is written to a temporary file beside it and renamed
  into place, so a crash mid-write never leaves a truncated note
  (docs/design.md, "A failed commit leaves the vault as it was").
  """

  alias Vigil.Commit
  alias Vigil.Git.CommitLog

  setup do
    vault = Vigil.FixtureVault.build()
    on_exit(fn -> Vigil.FixtureVault.cleanup(vault) end)
    {:ok, vault: vault, git: CommitLog.new(vault)}
  end

  defp dir_entries(vault, dir), do: vault |> Path.join(dir) |> File.ls!() |> Enum.sort()

  test "a note is replaced by a rename, not written through", %{git: git, vault: vault} do
    path = "bike/terra-speed.md"
    abs = Path.join(vault, path)
    %File.Stat{inode: before} = File.stat!(abs)
    entries = dir_entries(vault, "bike")

    assert {:ok, _} = Commit.write(git, vault, path, "# Replaced\n", "update: #{path}")

    assert File.read!(abs) == "# Replaced\n"
    assert %File.Stat{inode: after_write} = File.stat!(abs)
    refute after_write == before
    assert dir_entries(vault, "bike") == entries
  end

  test "a write that cannot be renamed into place leaves no temporary file", %{
    git: git,
    vault: vault
  } do
    File.mkdir_p!(Path.join(vault, "bike/a-directory.md"))
    entries = dir_entries(vault, "bike")

    assert {:error, "Could not write file " <> reason} =
             Commit.write(git, vault, "bike/a-directory.md", "# X\n", "create")

    assert reason =~ "directory"
    assert dir_entries(vault, "bike") == entries
  end

  describe "a move with rewrites" do
    test "moves the note and writes every rewrite in one commit", %{vault: vault} do
      {git, log} = CommitLog.recording(vault)

      rewrites = [
        {"bike/via-carolina.md", "# Via\n[[terra-40c]]\n"},
        {"bike/terra-40c.md", "# T\n"}
      ]

      assert {:ok, _} =
               Commit.move(
                 git,
                 vault,
                 "bike/terra-speed.md",
                 "bike/terra-40c.md",
                 "move",
                 rewrites
               )

      refute File.exists?(Path.join(vault, "bike/terra-speed.md"))
      assert File.read!(Path.join(vault, "bike/terra-40c.md")) == "# T\n"
      assert File.read!(Path.join(vault, "bike/via-carolina.md")) == "# Via\n[[terra-40c]]\n"

      assert [
               {:move, "bike/terra-speed.md", "bike/terra-40c.md"},
               {:add, ["bike/via-carolina.md", "bike/terra-40c.md"]},
               {:commit, ["bike/terra-speed.md", "bike/terra-40c.md", "bike/via-carolina.md"],
                "move"}
             ] = CommitLog.calls(log)
    end

    test "a failed commit leaves every file as it was", %{vault: vault} do
      git = %{CommitLog.new(vault) | commit: fn _, _, _ -> {:error, "boom"} end}
      paths = ["bike/terra-speed.md", "bike/via-carolina.md", "training/note-without-anything.md"]
      before = Map.new(paths, &{&1, File.read!(Path.join(vault, &1))})

      rewrites = [
        {"bike/via-carolina.md", "rewritten"},
        {"training/note-without-anything.md", "rewritten"},
        {"gear/terra-40c.md", "rewritten"}
      ]

      assert {:error, "git mv/commit failed: boom"} =
               Commit.move(
                 git,
                 vault,
                 "bike/terra-speed.md",
                 "gear/terra-40c.md",
                 "move",
                 rewrites
               )

      assert Map.new(paths, &{&1, File.read!(Path.join(vault, &1))}) == before
      refute File.exists?(Path.join(vault, "gear"))
    end
  end
end
