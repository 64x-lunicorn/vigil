defmodule Vigil.Vault.LayoutTest do
  use ExUnit.Case, async: true

  alias Vigil.Vault.{AbsentFacts, Layout, Policy}

  setup do
    root = Path.join(System.tmp_dir!(), "vigil_layout_#{System.unique_integer([:positive])}")

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

  describe "what a vault is made of" do
    test "skills, dotfiles and underscore directories are never domains", %{root: root} do
      assert Layout.over_vault(root).domains == ["bike", "projects", "work"]
    end

    test "excluded domains are dropped", %{root: root} do
      assert Layout.over_vault(root, ["work"]).domains == ["bike", "projects"]
    end

    test "the project directories inside the nesting domain are part of the layout", %{root: root} do
      assert Layout.over_vault(root).project_dirs == ["vigil"]
    end

    test "a root with no directories has no domains" do
      root =
        Path.join(System.tmp_dir!(), "vigil_layout_empty_#{System.unique_integer([:positive])}")

      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf(root) end)

      assert Layout.over_vault(root, []).domains == []
    end

    test "an unreadable vault has no domains, and says so when asked to raise" do
      missing = Path.join(System.tmp_dir!(), "nope_does_not_exist")

      assert Layout.over_vault(missing).domains == []
      assert_raise File.Error, fn -> Layout.over_vault!(missing) end
    end
  end

  describe "note_paths/1" do
    test "notes live one level down, except under projects", %{root: root} do
      assert root |> Layout.over_vault() |> Layout.note_paths() == [
               "bike/terra.md",
               "projects/vigil/vigil.md",
               "work/secret.md"
             ]
    end

    test "an excluded domain contributes no files", %{root: root} do
      paths = root |> Layout.over_vault(["work"]) |> Layout.note_paths()
      refute "work/secret.md" in paths
    end
  end

  # The point of the value: one statement, two readers. What the write gate
  # lets in and what a load takes back must be the same set of paths, so this
  # table asks both about every shape a vault can hold — and asks the layout
  # itself, which is the statement the other two now consult.
  #
  # `created?` says whether the path is a file in the fixture vault above: a
  # missing project directory and a domain that is not there cannot be, and
  # the discovery half of those rows is answered by their absence.
  @table [
    {"bike/terra.md", {:note, "bike"}, "a note lives one level down", true},
    {"projects/vigil/vigil.md", {:note, "projects"}, "projects/ nests one deeper", true},
    {"projects/loose.md", :not_a_note, "and a note directly in projects/ is not one", true},
    {"bike/deep/terra.md", :not_a_note, "no other domain nests", true},
    {"work/secret.md", :excluded, "VIGIL_EXCLUDE is the hard boundary", true},
    {"skills/tdd.md", :skill, "skills are never notes", true},
    {"_internal/notes.md", :not_a_note, "underscore directories are not domains", true},
    {".obsidian/notes.md", :not_a_note, "and neither are dot directories", true},
    {"bike/terra.txt", :not_a_note, "only .md files are notes", true},
    {"garden/x.md", {:unknown_domain, "garden"}, "a directory that is not there", false},
    {"projects/ghost/x.md", {:missing_project, "projects", "ghost"}, "nor is a project", false}
  ]

  test "writability and discovery are answered by the same statement", %{root: root} do
    for {path, _classification, _why, true} <- @table do
      abs = Path.join(root, path)
      File.mkdir_p!(Path.dirname(abs))
      File.write!(abs, "---\ntype: reference\n---\n# T\n\nbody\n")
    end

    layout = Layout.over_vault(root, ["work"])
    discovered = Layout.note_paths(layout)

    for {path, classification, why, created?} <- @table do
      assert Layout.classify(layout, path) == classification, why

      note? = match?({:note, _domain}, classification)

      if created?, do: assert(note? == path in discovered, why)

      assert note? != path_refused?(layout, path), why
    end
  end

  # The write gate's answer, reduced to the one thing the layout decides: a
  # path it will not write to at all. A note that is already there is refused
  # for existing, which is a different refusal and not this one.
  defp path_refused?(layout, path) do
    facts =
      AbsentFacts.answering_nothing(
        layout: layout,
        path_exists?: fn _path -> false end
      )

    match?(
      {:error, "Invalid path" <> _},
      Policy.check(:create, %{path: path, type: "reference", content: "# T\n\nbody"}, facts)
    )
  end
end
