defmodule Vigil.LinkIndexTest do
  use ExUnit.Case, async: true

  alias Vigil.LinkIndex

  defp file(path, domain \\ nil) do
    %{path: path, domain: domain || path |> String.split("/") |> hd()}
  end

  defp chunk(id, path, links) do
    %{id: id, path: path, links: links}
  end

  defp link(raw, fragment \\ nil), do: %{raw: raw, fragment: fragment}

  describe "basename cascade" do
    test "same-folder candidate wins over a same-domain and a vault-wide one" do
      files = [
        file("bike/via-carolina.md"),
        file("bike/terra-speed.md"),
        file("bike/other/terra-speed.md")
      ]

      chunks = [chunk("bike/via-carolina.md#c1", "bike/via-carolina.md", [link("terra-speed")])]

      %{out: out} = LinkIndex.build(files, chunks)

      assert [{"bike/via-carolina.md#c1", resolved}] = out
      assert resolved.status == :ok
      assert resolved.target_note == "bike/terra-speed.md"
    end

    test "same-domain candidate wins when no same-folder match exists" do
      files = [
        file("bike/via-carolina.md"),
        file("bike/sub/terra-speed.md")
      ]

      chunks = [chunk("bike/via-carolina.md#c1", "bike/via-carolina.md", [link("terra-speed")])]

      %{out: [{_, resolved}]} = LinkIndex.build(files, chunks)

      assert resolved.status == :ok
      assert resolved.target_note == "bike/sub/terra-speed.md"
    end

    test "vault-wide fallback when no folder or domain match exists" do
      files = [
        file("training/note.md"),
        file("bike/via-carolina.md")
      ]

      chunks = [chunk("training/note.md#c1", "training/note.md", [link("via-carolina")])]

      %{out: [{_, resolved}]} = LinkIndex.build(files, chunks)

      assert resolved.status == :ok
      assert resolved.target_note == "bike/via-carolina.md"
    end

    test "ambiguous when the winning stage has more than one match" do
      files = [
        file("garden/note.md"),
        file("bike/doppelganger.md"),
        file("training/doppelganger.md")
      ]

      chunks = [chunk("garden/note.md#c1", "garden/note.md", [link("doppelganger")])]

      %{out: [{_, resolved}]} = LinkIndex.build(files, chunks)

      assert resolved.status == :ambiguous
      assert resolved.target_note == nil

      assert Enum.sort(resolved.candidates) == [
               "bike/doppelganger.md",
               "training/doppelganger.md"
             ]
    end

    test "same-folder match wins even when an ambiguous sibling exists elsewhere" do
      files = [
        file("bike/doppelganger.md"),
        file("training/doppelganger.md"),
        file("bike/note.md")
      ]

      chunks = [chunk("bike/note.md#c1", "bike/note.md", [link("doppelganger")])]

      %{out: [{_, resolved}]} = LinkIndex.build(files, chunks)

      assert resolved.status == :ok
      assert resolved.target_note == "bike/doppelganger.md"
    end

    test "broken when no candidate exists at all" do
      files = [file("bike/note.md")]
      chunks = [chunk("bike/note.md#c1", "bike/note.md", [link("does-not-exist")])]

      %{out: [{_, resolved}]} = LinkIndex.build(files, chunks)

      assert resolved.status == :broken
      assert resolved.target_note == nil
    end

    test "slug case/diacritic variants all resolve to the same note" do
      files = [file("bike/note.md"), file("bike/painpoints.md")]

      chunks =
        for {raw, n} <- Enum.with_index(["Painpoints", "painpoints", "PAINPOINTS"]) do
          chunk("bike/note.md##{n}", "bike/note.md", [link(raw)])
        end

      %{out: out} = LinkIndex.build(files, chunks)

      assert Enum.all?(out, fn {_, resolved} ->
               resolved.status == :ok and resolved.target_note == "bike/painpoints.md"
             end)
    end
  end

  describe "explicit path links" do
    test "resolves independent of basename ambiguity" do
      files = [
        file("bike/doppelganger.md"),
        file("training/doppelganger.md"),
        file("garden/note.md")
      ]

      chunks = [
        chunk("garden/note.md#c1", "garden/note.md", [link("bike/doppelganger.md")])
      ]

      %{out: [{_, resolved}]} = LinkIndex.build(files, chunks)

      assert resolved.status == :ok
      assert resolved.target_note == "bike/doppelganger.md"
    end

    test "an extension-less explicit path is still resolved" do
      files = [file("bike/note.md"), file("bike/target.md")]
      chunks = [chunk("bike/note.md#c1", "bike/note.md", [link("bike/target")])]

      %{out: [{_, resolved}]} = LinkIndex.build(files, chunks)

      assert resolved.status == :ok
      assert resolved.target_note == "bike/target.md"
    end

    test "broken when the exact path does not exist" do
      files = [file("bike/note.md")]
      chunks = [chunk("bike/note.md#c1", "bike/note.md", [link("bike/nope.md")])]

      %{out: [{_, resolved}]} = LinkIndex.build(files, chunks)

      assert resolved.status == :broken
    end
  end

  describe "fragment resolution" do
    test "a fragment link resolves to the specific chunk when it exists" do
      files = [file("bike/via-carolina.md"), file("bike/note.md")]

      chunks = [
        chunk("bike/via-carolina.md#fueling", "bike/via-carolina.md", []),
        chunk("bike/note.md#c1", "bike/note.md", [link("via-carolina", "fueling")])
      ]

      %{out: out} = LinkIndex.build(files, chunks)
      {_, resolved} = Enum.find(out, fn {id, _} -> id == "bike/note.md#c1" end)

      assert resolved.status == :ok
      assert resolved.target_note == "bike/via-carolina.md"
      assert resolved.target_chunk == "bike/via-carolina.md#fueling"
    end

    test "a link to an existing note with a nonexistent fragment is broken" do
      files = [file("bike/via-carolina.md"), file("bike/note.md")]

      chunks = [
        chunk("bike/note.md#c1", "bike/note.md", [link("via-carolina", "does-not-exist")])
      ]

      %{out: [{_, resolved}]} = LinkIndex.build(files, chunks)

      assert resolved.status == :broken
      assert resolved.target_note == nil
      assert resolved.target_chunk == nil
    end
  end

  describe "in index" do
    test "a note-level link records exactly one incoming entry" do
      files = [file("bike/via-carolina.md"), file("bike/note.md")]
      chunks = [chunk("bike/note.md#c1", "bike/note.md", [link("via-carolina")])]

      %{in: in_} = LinkIndex.build(files, chunks)

      assert in_ == [{"bike/via-carolina.md", "bike/note.md#c1"}]
    end

    test "a chunk-level link records both the note and the chunk as targets" do
      files = [file("bike/via-carolina.md"), file("bike/note.md")]

      chunks = [
        chunk("bike/via-carolina.md#fueling", "bike/via-carolina.md", []),
        chunk("bike/note.md#c1", "bike/note.md", [link("via-carolina", "fueling")])
      ]

      %{in: in_} = LinkIndex.build(files, chunks)

      assert Enum.sort(in_) ==
               Enum.sort([
                 {"bike/via-carolina.md", "bike/note.md#c1"},
                 {"bike/via-carolina.md#fueling", "bike/note.md#c1"}
               ])
    end

    test "ambiguous and broken links record no incoming entries" do
      files = [file("bike/note.md")]
      chunks = [chunk("bike/note.md#c1", "bike/note.md", [link("does-not-exist")])]

      %{in: in_} = LinkIndex.build(files, chunks)

      assert in_ == []
    end
  end

  describe "multiple links and chunks" do
    test "each raw link on a chunk produces its own out entry" do
      files = [file("bike/a.md"), file("bike/b.md"), file("bike/note.md")]
      chunks = [chunk("bike/note.md#c1", "bike/note.md", [link("a"), link("b")])]

      %{out: out} = LinkIndex.build(files, chunks)

      targets = out |> Enum.map(fn {_, r} -> r.target_note end) |> Enum.sort()
      assert targets == ["bike/a.md", "bike/b.md"]
    end

    test "a chunk with no links contributes nothing to out or in" do
      files = [file("bike/note.md")]
      chunks = [chunk("bike/note.md#c1", "bike/note.md", [])]

      assert LinkIndex.build(files, chunks) == %{out: [], in: []}
    end
  end
end
