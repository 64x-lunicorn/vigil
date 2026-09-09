defmodule Vigil.IndexTest do
  use ExUnit.Case, async: true

  alias Vigil.{Index, Parser, VaultDiscovery}

  @fixtures Path.expand("../fixtures/vault", __DIR__)
  @git_meta %{
    created_at: ~U[2026-01-01 10:00:00Z],
    updated_at: ~U[2026-01-01 10:00:00Z],
    last_author: "Daniel"
  }

  defp parse(rel_path) do
    content = File.read!(Path.join(@fixtures, rel_path))
    {:ok, file} = Parser.parse(rel_path, content, @git_meta)
    file
  end

  defp parsed_fixture_files do
    @fixtures
    |> VaultDiscovery.discover_files()
    |> Enum.map(&parse/1)
  end

  setup do
    %{index: Index.build(parsed_fixture_files())}
  end

  describe "read/3 — chunk by id" do
    test "returns exactly that chunk, without backlinks by default", %{index: index} do
      {:ok, result} = Index.read(index, "bike/via-carolina.md#fueling", false)

      assert result.heading == "Fueling"
      assert result.body =~ "baseline"
      refute Map.has_key?(result, :backlinks)
    end

    test "backlinks is opt-in (note-level, even for a chunk read)", %{index: index} do
      {:ok, with_backlinks} = Index.read(index, "bike/terra-speed.md#dimensions", true)
      assert with_backlinks.backlinks == ["bike/via-carolina.md"]

      {:ok, without_backlinks} = Index.read(index, "bike/terra-speed.md#dimensions", false)
      refute Map.has_key?(without_backlinks, :backlinks)
    end
  end

  describe "read/3 — note by path" do
    test "returns a table of contents and links out/in/broken counters", %{index: index} do
      {:ok, result} = Index.read(index, "bike/via-carolina.md", false)

      assert result.title == "Via Carolina"
      refute Map.has_key?(result, :body)
      assert Enum.map(result.toc, & &1.heading) == ["Fueling", "Second Half", "Gear"]

      # via-carolina.md links out to terra-speed.md, and is itself linked to
      # from training/note-without-anything.md — see fixture vault.
      assert result.links == %{out: 1, in: 1, broken: 0}
    end

    test "backlinks is opt-in", %{index: index} do
      {:ok, result} = Index.read(index, "bike/terra-speed.md", true)
      assert "bike/via-carolina.md" in result.backlinks
    end
  end

  describe "read/3 — lenient path" do
    test "an id that misses exactly is retried once through path normalization", %{index: index} do
      {:ok, result} = Index.read(index, "Bike/Via-Carolina.md", false)
      assert result.path == "bike/via-carolina.md"
    end
  end

  describe "read/3 — invalid and missing" do
    test "a path that fails the safety check answers Invalid path", %{index: index} do
      assert Index.read(index, "../etc/passwd", false) == {:error, "Invalid path"}
    end

    test "anything else answers Not found", %{index: index} do
      assert {:error, "Not found: bike/nope.md"} = Index.read(index, "bike/nope.md", false)
    end
  end

  describe "put/2 and remove/2" do
    test "put makes a new note (and its links) show up in read", %{index: index} do
      {:ok, file} = Parser.parse("bike/new.md", "# New\n\nSee [[via-carolina]].\n", @git_meta)

      updated = Index.put(index, file)

      assert {:ok, result} = Index.read(updated, "bike/new.md", false)
      assert result.title == "New"

      {:ok, via_carolina} = Index.read(updated, "bike/via-carolina.md", false)
      assert via_carolina.links == %{out: 1, in: 2, broken: 0}
    end

    test "remove makes read answer Not found again, and drops its links", %{index: index} do
      {:ok, file} = Parser.parse("bike/new.md", "# New\n\nSee [[via-carolina]].\n", @git_meta)
      with_new = Index.put(index, file)

      removed = Index.remove(with_new, "bike/new.md")

      assert Index.read(removed, "bike/new.md", false) == {:error, "Not found: bike/new.md"}

      {:ok, via_carolina} = Index.read(removed, "bike/via-carolina.md", false)
      assert via_carolina.links == %{out: 1, in: 1, broken: 0}
    end
  end

  describe "note/2 and size/1" do
    test "note/2 returns the Note struct at a path, or nil", %{index: index} do
      assert %Index.Note{path: "bike/via-carolina.md", title: "Via Carolina"} =
               Index.note(index, "bike/via-carolina.md")

      assert Index.note(index, "bike/nope.md") == nil
    end

    test "size/1 counts notes and chunks", %{index: index} do
      files = parsed_fixture_files()

      assert Index.size(index) == %{
               notes: length(files),
               chunks: files |> Enum.flat_map(& &1.chunks) |> length()
             }
    end
  end
end
