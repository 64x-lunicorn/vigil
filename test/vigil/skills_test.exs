defmodule Vigil.SkillsTest do
  # Nothing here is registered under a name: Vigil.Skills takes its vault, its
  # remote and its git adapter as plain arguments, so every test in this file
  # is independent of every other (docs/design.md, "skills/ — one repository,
  # two systems").
  use ExUnit.Case, async: true

  alias Vigil.Git.CommitLog
  alias Vigil.{SkillKey, Skills}

  # The deployment's SkillKey, stated here rather than resolved. `read/3` takes
  # it the way it takes the vault path and the git adapter — this module holds
  # no configuration to build one from — so the token asserted against below is
  # the token this file handed in.
  @key %{secret: "skills-test-secret", window: 3600}

  # Where a skill write goes and what it reaches git through. The commit log
  # is the adapter (docs/design.md, "Git is reached through a value"): what
  # these tests assert is vigil's — the file that lands, the newline it ends
  # with, the sentence a failure carries — and git_test.exs is where the
  # commit itself is asserted, against a repository and against this.
  # `remote: nil` is a vault with no remote configured, which is how a push
  # failure is provoked.
  defp target(vault, opts \\ []) do
    %{vault_path: vault, git_remote: "origin", git: CommitLog.new(vault, opts)}
  end

  defp tmp_dir do
    path = Path.join(System.tmp_dir!(), "vigil_skills_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  describe "list/1 (FixtureVault-backed)" do
    test "returns name + description for every skill file" do
      vault = Vigil.FixtureVault.build()
      on_exit(fn -> Vigil.FixtureVault.cleanup(vault) end)

      assert [skill] = Skills.list(vault)
      assert skill.name == "tdd"
      assert skill.description =~ "test coverage"
    end

    test "a vault with no skills/ directory returns an empty list" do
      vault = tmp_dir()
      assert Skills.list(vault) == []
    end
  end

  describe "read/3 (FixtureVault-backed)" do
    setup do
      vault = Vigil.FixtureVault.build()
      on_exit(fn -> Vigil.FixtureVault.cleanup(vault) end)
      %{vault: vault}
    end

    test "with and without .md returns the same content", %{vault: vault} do
      {:ok, %{content: c1}} = Skills.read("tdd", vault, @key)
      {:ok, %{content: c2}} = Skills.read("tdd.md", vault, @key)
      assert c1 == c2
      assert c1 =~ "Failing Test"
    end

    test "prefixes the response with the current SkillKey token", %{vault: vault} do
      {:ok, %{content: content}} = Skills.read("tdd", vault, @key)
      assert content =~ "SkillKey: #{SkillKey.current(@key)}"
    end

    test "a not-found skill lists available names and still carries a SkillKey token", %{
      vault: vault
    } do
      assert {:error, msg} = Skills.read("does-not-exist", vault, @key)
      assert msg =~ "tdd"

      [_, token] = Regex.run(~r/SkillKey: ([0-9a-f]+)/, msg)
      assert token == SkillKey.current(@key)
    end
  end

  describe "write/3 (FixtureVault-backed)" do
    test "writes, commits, and pushes; does not parse or index the file" do
      vault = Vigil.FixtureVault.build()
      on_exit(fn -> Vigil.FixtureVault.cleanup(vault) end)

      assert {:ok, %{name: "new", pushed: true}} =
               Skills.write(
                 "new",
                 "---\nname: new\ndescription: test skill\n---\n# New\n1. one",
                 target(vault)
               )

      assert File.exists?(Path.join(vault, "skills/new.md"))

      {:ok, %{content: content}} = Skills.read("new", vault, @key)
      assert content =~ "1. one"
    end

    # Skills are never notes, which is why the trailing-newline rule lives in
    # Vigil.Markdown rather than in the note-editing module (docs/design.md,
    # "How a file is written").
    test "content ending in blank lines is written with exactly one trailing newline" do
      vault = Vigil.FixtureVault.build()
      on_exit(fn -> Vigil.FixtureVault.cleanup(vault) end)

      assert {:ok, _} =
               Skills.write(
                 "trailing",
                 "---\nname: trailing\ndescription: test skill\n---\n# Trailing\n1. one\n\n\n",
                 target(vault)
               )

      assert File.read!(Path.join(vault, "skills/trailing.md")) |> String.ends_with?("1. one\n")
    end

    # The write effect and its POSIX-error wording live in Vigil.Commit, for
    # notes and skills alike. A failed skill write says the same sentence a
    # failed note write says, and is still an error tuple, not a raise.
    test "a failed write returns the shared filesystem error" do
      vault = Vigil.FixtureVault.build()
      on_exit(fn -> Vigil.FixtureVault.cleanup(vault) end)

      dir = Path.join(vault, "skills")
      File.chmod!(dir, 0o555)

      result =
        Skills.write(
          "blocked",
          "---\nname: blocked\ndescription: test skill\n---\n# Blocked\n1. one",
          target(vault)
        )

      File.chmod!(dir, 0o755)

      assert {:error, msg} = result
      assert msg =~ "Could not write file"
      assert msg =~ "no write permission"

      assert {:ok, _} = Skills.read("tdd", vault, @key)
    end

    test "rejects content missing required frontmatter fields, without touching git" do
      vault = Vigil.FixtureVault.build()
      on_exit(fn -> Vigil.FixtureVault.cleanup(vault) end)

      assert {:error, msg} =
               Skills.write("broken", "---\nname: broken\n---\n# x", target(vault))

      assert msg =~ "name' and 'description'"
      refute File.exists?(Path.join(vault, "skills/broken.md"))
    end
  end

  describe "fixture-free unit tests: valid_skill_name?/1 (via read/2, write/3)" do
    test "read/2 rejects a name with path-hostile characters, without touching disk" do
      vault = tmp_dir()
      assert {:error, "Invalid path"} = Skills.read("../evil", vault, @key)
      assert {:error, "Invalid path"} = Skills.read("Has Spaces", vault, @key)
      refute File.exists?(Path.join(vault, "skills"))
    end

    test "write/3 rejects a name with path-hostile characters, without touching disk" do
      vault = tmp_dir()

      assert {:error, "Invalid path"} =
               Skills.write("../evil", "---\nname: x\ndescription: x\n---\n# X", target(vault))

      refute File.exists?(Path.join(vault, "skills"))
    end

    test "a lowercase alphanumeric/hyphen/underscore name passes validation and reaches disk" do
      vault = tmp_dir()

      # No "origin" remote configured — push fails, but that failure itself
      # proves valid_skill_name?/1 and validate_skill_frontmatter/1 both let
      # this write through to the git-write path.
      assert {:error, msg} =
               Skills.write(
                 "valid-name_1",
                 "---\nname: x\ndescription: x\n---\n# X",
                 target(vault, remote: nil)
               )

      assert msg =~ "push failed"
      assert File.exists?(Path.join(vault, "skills/valid-name_1.md"))
    end
  end

  describe "fixture-free unit tests: normalize_skill_name/1 (via read/2)" do
    test "trims whitespace and strips a .md suffix before lookup" do
      vault = tmp_dir()
      skills_dir = Path.join(vault, "skills")
      File.mkdir_p!(skills_dir)
      File.write!(Path.join(skills_dir, "foo.md"), "---\nname: foo\ndescription: d\n---\n# Foo")

      assert {:ok, %{name: "foo"}} = Skills.read("  foo  ", vault, @key)
      assert {:ok, %{name: "foo"}} = Skills.read("foo.md", vault, @key)
    end
  end

  describe "fixture-free unit tests: validate_skill_frontmatter/1 (via write/3)" do
    test "content with no frontmatter at all is rejected" do
      vault = tmp_dir()

      assert {:error, "content must start with frontmatter"} =
               Skills.write("x", "# X\nno frontmatter", target(vault))
    end

    test "unterminated frontmatter is rejected" do
      vault = tmp_dir()

      assert {:error, "Unterminated frontmatter"} =
               Skills.write("x", "---\nname: x\ndescription: d\n# X", target(vault))
    end

    test "frontmatter missing 'name' or 'description' is rejected" do
      vault = tmp_dir()

      assert {:error, msg} =
               Skills.write("x", "---\ndescription: d\n---\n# X", target(vault))

      assert msg =~ "name' and 'description'"
    end

    test "none of the rejected writes touch the filesystem" do
      vault = tmp_dir()

      Skills.write("x", "no frontmatter", target(vault))

      refute File.exists?(Path.join(vault, "skills"))
    end
  end
end
