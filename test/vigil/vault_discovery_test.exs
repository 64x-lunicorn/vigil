defmodule Vigil.VaultDiscoveryTest do
  use ExUnit.Case, async: true

  alias Vigil.VaultDiscovery

  setup do
    root = Path.join(System.tmp_dir!(), "vigil_disc_#{System.unique_integer([:positive])}")

    for dir <- ~w(bike work skills .obsidian _internal), do: File.mkdir_p!(Path.join(root, dir))
    File.mkdir_p!(Path.join([root, "projects", "vigil"]))

    File.write!(Path.join(root, "bike/terra.md"), "# T")
    File.write!(Path.join(root, "work/secret.md"), "# S")
    File.write!(Path.join(root, "skills/tdd.md"), "# TDD")
    File.write!(Path.join([root, "projects", "vigil", "vigil.md"]), "# V")
    File.write!(Path.join(root, "_domains.yml"), "bike: x\n")

    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  describe "domain_dirs/2" do
    test "skills, dotfiles and underscore directories are never domains", %{root: root} do
      assert VaultDiscovery.domain_dirs(root) == ["bike", "projects", "work"]
    end

    test "excluded domains are dropped", %{root: root} do
      assert VaultDiscovery.domain_dirs(root, ["work"]) == ["bike", "projects"]
    end

    test "the result is sorted" do
      assert VaultDiscovery.domain_dirs(System.tmp_dir!() <> "/nope_does_not_exist") == []
    end
  end

  describe "discover_files/2" do
    test "notes live one level down, except under projects", %{root: root} do
      assert VaultDiscovery.discover_files(root) == [
               "bike/terra.md",
               "projects/vigil/vigil.md",
               "work/secret.md"
             ]
    end

    test "an excluded domain contributes no files", %{root: root} do
      refute "work/secret.md" in VaultDiscovery.discover_files(root, ["work"])
    end
  end
end
