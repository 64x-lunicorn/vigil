defmodule Vigil.StoreEncodingTest do
  # docs/design.md, "A note that is not UTF-8 is skipped" and "How a file is
  # written": one note saved by the wrong editor costs that note, never the
  # store, and a note written on Windows reads and writes back as its author
  # wrote it.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Vigil.Git.CommitLog
  alias Vigil.Store

  @store __MODULE__

  # "Café Größe" in Windows-1252: é is 0xE9, ö 0xF6, ß 0xDF — none of them
  # UTF-8 on their own. In the heading and in a link, where they used to reach
  # the slug function and raise while the store loaded.
  @cp1252_path "bike/windows-note.md"
  @cp1252 "---\ntype: reference\n---\n# Caf\xE9\n\n## Gr\xF6\xDFe\nSee [[caf\xE9]].\n"

  @crlf_path "bike/crlf-note.md"
  @crlf "---\r\ntype: decision\r\n---\r\n# Crlf Note\r\n\r\n## Setup\r\nBody line.\r\n"

  @bom_path "bike/bom-note.md"
  @bom "﻿---\ntype: decision\n---\n# Bom Note\n\n## Setup\nBody line.\n"

  defp start_store(vault) do
    start_supervised!(
      {Store,
       vault_path: vault,
       exclude: [],
       git_remote: "origin",
       git_branch: "main",
       git: CommitLog.new(vault),
       name: @store}
    )
  end

  setup do
    vault = Vigil.FixtureVault.build()
    on_exit(fn -> Vigil.FixtureVault.cleanup(vault) end)

    File.write!(Path.join(vault, @cp1252_path), @cp1252)
    File.write!(Path.join(vault, @crlf_path), @crlf)
    File.write!(Path.join(vault, @bom_path), @bom)

    log = capture_log(fn -> start_store(vault) end)
    %{vault: vault, log: log}
  end

  defp read(id), do: Store.call(@store, :read, %{id: id, backlinks: false})

  # The name, not the content: it used to reach the slug function while the
  # index was built and raise, which at boot is a restart loop.
  describe "a note whose file name is not UTF-8" do
    @describetag :non_utf8_file_names

    @non_utf8_name "bike/caf" <> <<0xE9>> <> ".md"

    test "the vault boots without it, the warning names it, and lint lists it", %{vault: vault} do
      File.write!(Path.join(vault, @non_utf8_name), "---\ntype: reference\n---\n# Cafe\n")

      log =
        capture_log(fn ->
          assert %{reloaded: true} = Store.call(@store, :reload, %{})
        end)

      assert log =~ "skipping bike/caf\\xE9.md: file name is not valid UTF-8"

      lint = Store.call(@store, :lint, %{})
      assert lint.invalid_utf8 == ["bike/caf\\xE9.md", @cp1252_path]
      assert Jason.encode!(lint)
      assert {:ok, %{type: :reference}} = read("bike/terra-speed.md")
    end
  end

  describe "a note that is not UTF-8" do
    test "the vault boots without it, and the warning names its path", %{log: log} do
      assert log =~ "skipping #{@cp1252_path}: not valid UTF-8"

      assert {:error, _} = read(@cp1252_path)
      assert {:ok, %{type: :reference}} = read("bike/terra-speed.md")
    end

    test "lint names it" do
      assert Store.call(@store, :lint, %{}).invalid_utf8 == [@cp1252_path]
    end

    test "a reload skips it again rather than going down" do
      capture_log(fn -> assert %{reloaded: true} = Store.call(@store, :reload, %{}) end)
      assert Store.call(@store, :lint, %{}).invalid_utf8 == [@cp1252_path]
    end

    test "is not edited or moved, and the file stays as it was", %{vault: vault} do
      assert {:error, msg} =
               Store.call(@store, :update_frontmatter, %{path: @cp1252_path, type: "decision"})

      assert msg =~ "not valid UTF-8"

      assert {:error, msg} =
               Store.call(@store, :append, %{path: @cp1252_path, content: "More."})

      assert msg =~ "not valid UTF-8"

      assert {:error, msg} =
               Store.call(@store, :move_note, %{
                 from: @cp1252_path,
                 to: "bike/moved-note.md",
                 confirm: true
               })

      assert msg =~ "not valid UTF-8"
      assert File.read!(Path.join(vault, @cp1252_path)) == @cp1252
    end

    test "deleting it takes it out of lint" do
      assert {:ok, _} = Store.call(@store, :delete_note, %{path: @cp1252_path, confirm: true})
      assert Store.call(@store, :lint, %{}).invalid_utf8 == []
    end
  end

  describe "a CRLF note" do
    test "its frontmatter is parsed, and its chunks carry no carriage return" do
      assert {:ok, %{type: :decision, title: "Crlf Note"}} = read(@crlf_path)
      assert {:ok, %{body: "Body line."}} = read("#{@crlf_path}#setup")
    end

    test "update_frontmatter replaces its block and keeps its line endings", %{vault: vault} do
      assert {:ok, _} =
               Store.call(@store, :update_frontmatter, %{path: @crlf_path, type: "reference"})

      assert File.read!(Path.join(vault, @crlf_path)) ==
               "---\r\ntype: reference\r\n---\r\n# Crlf Note\r\n\r\n## Setup\r\nBody line.\r\n"

      assert {:ok, %{type: :reference}} = read(@crlf_path)
    end

    test "a section edit keeps its line endings", %{vault: vault} do
      assert {:ok, _} =
               Store.call(@store, :replace_section, %{
                 id: "#{@crlf_path}#setup",
                 content: "New line.\nSecond line."
               })

      assert File.read!(Path.join(vault, @crlf_path)) ==
               "---\r\ntype: decision\r\n---\r\n# Crlf Note\r\n\r\n## Setup\r\n" <>
                 "New line.\r\nSecond line.\r\n"
    end
  end

  describe "a note with a byte order mark" do
    test "its frontmatter is parsed" do
      assert {:ok, %{type: :decision, title: "Bom Note"}} = read(@bom_path)
    end

    test "update_frontmatter replaces its block and keeps the mark", %{vault: vault} do
      assert {:ok, _} =
               Store.call(@store, :update_frontmatter, %{path: @bom_path, type: "reference"})

      assert File.read!(Path.join(vault, @bom_path)) ==
               "﻿---\ntype: reference\n---\n# Bom Note\n\n## Setup\nBody line.\n"
    end
  end
end
