defmodule Vigil.SkillsTest do
  use ExUnit.Case, async: false

  alias Vigil.Skills

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

  describe "read/2 (FixtureVault-backed)" do
    setup do
      vault = Vigil.FixtureVault.build()
      on_exit(fn -> Vigil.FixtureVault.cleanup(vault) end)
      %{vault: vault}
    end

    test "with and without .md returns the same content", %{vault: vault} do
      {:ok, %{content: c1}} = Skills.read("tdd", vault)
      {:ok, %{content: c2}} = Skills.read("tdd.md", vault)
      assert c1 == c2
      assert c1 =~ "Failing Test"
    end

    test "prefixes the response with the current SkillKey token", %{vault: vault} do
      {:ok, %{content: content}} = Skills.read("tdd", vault)
      assert content =~ "SkillKey: #{Vigil.SkillKey.current(Vigil.SkillKey.config())}"
    end

    test "a not-found skill lists available names and still carries a SkillKey token", %{
      vault: vault
    } do
      assert {:error, msg} = Skills.read("does-not-exist", vault)
      assert msg =~ "tdd"

      [_, token] = Regex.run(~r/SkillKey: ([0-9a-f]+)/, msg)
      assert token == Vigil.SkillKey.current(Vigil.SkillKey.config())
    end
  end

  describe "write/3 (FixtureVault-backed)" do
    test "writes, commits, and pushes; does not parse or index the file" do
      {vault, _remote} = Vigil.FixtureVault.build(remote: true)
      on_exit(fn -> Vigil.FixtureVault.cleanup(vault) end)

      assert {:ok, %{name: "new", pushed: true}} =
               Skills.write(
                 "new",
                 "---\nname: new\ndescription: test skill\n---\n# New\n1. one",
                 %{vault_path: vault, git_remote: "origin"}
               )

      assert File.exists?(Path.join(vault, "skills/new.md"))

      {out, 0} = System.cmd("git", ["log", "-1", "--format=%an"], cd: vault)
      assert String.trim(out) == "vigil"

      {:ok, %{content: content}} = Skills.read("new", vault)
      assert content =~ "1. one"
    end

    test "rejects content missing required frontmatter fields, without touching git" do
      {vault, _remote} = Vigil.FixtureVault.build(remote: true)
      on_exit(fn -> Vigil.FixtureVault.cleanup(vault) end)

      assert {:error, msg} =
               Skills.write("broken", "---\nname: broken\n---\n# x", %{
                 vault_path: vault,
                 git_remote: "origin"
               })

      assert msg =~ "name' and 'description'"
      refute File.exists?(Path.join(vault, "skills/broken.md"))
    end
  end

  describe "fixture-free unit tests: valid_skill_name?/1 (via read/2, write/3)" do
    test "read/2 rejects a name with path-hostile characters, without touching disk" do
      vault = tmp_dir()
      assert {:error, "Invalid path"} = Skills.read("../evil", vault)
      assert {:error, "Invalid path"} = Skills.read("Has Spaces", vault)
      refute File.exists?(Path.join(vault, "skills"))
    end

    test "write/3 rejects a name with path-hostile characters, without touching disk" do
      vault = tmp_dir()

      assert {:error, "Invalid path"} =
               Skills.write("../evil", "---\nname: x\ndescription: x\n---\n# X", %{
                 vault_path: vault,
                 git_remote: "origin"
               })

      refute File.exists?(Path.join(vault, "skills"))
    end

    test "a lowercase alphanumeric/hyphen/underscore name passes validation and reaches disk" do
      vault = tmp_dir() |> tmp_dir_with_git()

      # No "origin" remote configured — push fails, but that failure itself
      # proves valid_skill_name?/1 and validate_skill_frontmatter/1 both let
      # this write through to the git-write path.
      assert {:error, msg} =
               Skills.write("valid-name_1", "---\nname: x\ndescription: x\n---\n# X", %{
                 vault_path: vault,
                 git_remote: "origin"
               })

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

      assert {:ok, %{name: "foo"}} = Skills.read("  foo  ", vault)
      assert {:ok, %{name: "foo"}} = Skills.read("foo.md", vault)
    end
  end

  describe "fixture-free unit tests: validate_skill_frontmatter/1 (via write/3)" do
    test "content with no frontmatter at all is rejected" do
      vault = tmp_dir()

      assert {:error, "content must start with frontmatter"} =
               Skills.write("x", "# X\nno frontmatter", %{vault_path: vault, git_remote: "origin"})
    end

    test "unterminated frontmatter is rejected" do
      vault = tmp_dir()

      assert {:error, "Unterminated frontmatter"} =
               Skills.write("x", "---\nname: x\ndescription: d\n# X", %{
                 vault_path: vault,
                 git_remote: "origin"
               })
    end

    test "frontmatter missing 'name' or 'description' is rejected" do
      vault = tmp_dir()

      assert {:error, msg} =
               Skills.write("x", "---\ndescription: d\n---\n# X", %{
                 vault_path: vault,
                 git_remote: "origin"
               })

      assert msg =~ "name' and 'description'"
    end

    test "none of the rejected writes touch the filesystem" do
      vault = tmp_dir()

      Skills.write("x", "no frontmatter", %{vault_path: vault, git_remote: "origin"})
      refute File.exists?(Path.join(vault, "skills"))
    end
  end

  defp tmp_dir_with_git(path) do
    System.cmd("git", ["init", "-q"], cd: path)
    System.cmd("git", ["config", "user.name", "vigil"], cd: path)
    System.cmd("git", ["config", "user.email", "vigil@local"], cd: path)
    System.cmd("git", ["config", "commit.gpgsign", "false"], cd: path)
    System.cmd("git", ["commit", "-q", "--allow-empty", "-m", "init"], cd: path)
    path
  end
end
