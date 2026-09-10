defmodule Vigil.VaultCheck do
  @moduledoc """
  Read-only vault adoption check ("vault doctor").

  Touches neither the vault nor a service that may already be running: no
  `Vigil.Store`, no `git pull`, no write tools — filesystem reads only.

  `run/1` returns the report-only findings plus an inventory overview. The
  automatic repairs (.gitignore, git config, upstream, minimal `_domains.yml`
  entries, directory permissions) are plain filesystem operations that need
  no knowledge of vault content and deliberately live in `scripts/init.sh`.
  """

  alias Vigil.{Markdown, Parser, Slug, VaultDiscovery}
  alias Vigil.Vault.Rules

  @max_basisname_laenge 60
  @max_frontmatter_bytes 1024

  def run(vault_path) do
    unless File.dir?(vault_path) do
      raise "Not a directory: #{vault_path}"
    end

    # The doctor honours VIGIL_EXCLUDE too: docs/design.md calls it the hard
    # boundary — "not filtered — not read" — and a report that lists notes the
    # server deliberately never reads would breach it.
    exclude = Application.get_env(:vigil, :exclude, [])
    domain_dirs = VaultDiscovery.domain_dirs!(vault_path, exclude)
    files = VaultDiscovery.discover_files!(vault_path, exclude)

    entries =
      Enum.map(files, fn rel_path ->
        content = File.read!(Path.join(vault_path, rel_path))
        {:ok, parsed} = Parser.parse(rel_path, content)
        {rel_path, content, parsed}
      end)

    %{
      overview: overview(vault_path, domain_dirs, entries),
      b1_frontmatter:
        Enum.flat_map(entries, fn {path, content, _} -> b1_checks(path, content) end),
      b2_filenames: b2_checks(files),
      b3_chunk_diff: b3_diff(files, vault_path),
      b4_domain_drift: b4_drift(vault_path, domain_dirs),
      b5_separators:
        Enum.flat_map(entries, fn {path, _content, parsed} -> b5_checks(path, parsed) end),
      b6_consolidation:
        Enum.flat_map(entries, fn {path, _content, parsed} -> b6_checks(path, parsed) end)
    }
  end

  ## Inventory overview

  defp overview(vault_path, domain_dirs, entries) do
    chunk_count =
      entries |> Enum.map(fn {_p, _c, parsed} -> length(parsed.chunks) end) |> Enum.sum()

    size_bytes = entries |> Enum.map(fn {_p, c, _} -> byte_size(c) end) |> Enum.sum()
    {head_sha, head_date} = git_head(vault_path)

    %{
      domains: length(domain_dirs),
      domain_names: Enum.sort(domain_dirs),
      notes: length(entries),
      chunks: chunk_count,
      size_bytes: size_bytes,
      head_sha: head_sha,
      head_date: head_date
    }
  end

  defp git_head(vault_path) do
    case System.cmd("git", ["-C", vault_path, "log", "-1", "--format=%h|%as"],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        case out |> String.trim() |> String.split("|", parts: 2) do
          [sha, date] -> {sha, date}
          _ -> {nil, nil}
        end

      _ ->
        {nil, nil}
    end
  end

  ## Frontmatter checks

  defp b1_checks(path, content) do
    case frontmatter_block(content) do
      :missing ->
        [%{path: path, message: "no frontmatter — treated as reference"}]

      {:ok, yaml_text} ->
        size_finding =
          if byte_size(yaml_text) > @max_frontmatter_bytes do
            [%{path: path, message: "frontmatter exceeds 1 KB"}]
          else
            []
          end

        case YamlElixir.read_from_string(yaml_text) do
          {:ok, map} when is_map(map) -> b1_type_checks(path, map) ++ size_finding
          _ -> [%{path: path, message: "frontmatter YAML is not parsable"} | size_finding]
        end
    end
  end

  defp frontmatter_block(content) do
    case Markdown.frontmatter(content) do
      {:ok, yaml_text, _body_lines, _offset} -> {:ok, yaml_text}
      _ -> :missing
    end
  end

  defp b1_type_checks(path, frontmatter) do
    type = Map.get(frontmatter, "type")
    starts = Map.get(frontmatter, "starts")
    ends = Map.get(frontmatter, "ends")

    base_findings =
      cond do
        type == nil ->
          [%{path: path, message: "field 'type' is missing"}]

        type not in ["reference", "decision", "event"] ->
          [
            %{
              path: path,
              message: "unknown type '#{type}' (allowed: reference, decision, event)"
            }
          ]

        type == "event" and starts == nil ->
          [%{path: path, message: "event without starts — will never be picked up by current"}]

        type != "event" and (starts != nil or ends != nil) ->
          [%{path: path, message: "starts/ends have no effect on type '#{type}'"}]

        true ->
          []
      end

    base_findings ++ ends_before_starts(path, type, starts, ends)
  end

  defp ends_before_starts(path, "event", starts, ends)
       when is_binary(starts) and is_binary(ends) do
    with {:ok, s, _} <- DateTime.from_iso8601(starts),
         {:ok, e, _} <- DateTime.from_iso8601(ends),
         :lt <- DateTime.compare(e, s) do
      [%{path: path, message: "ends is before starts"}]
    else
      _ -> []
    end
  end

  defp ends_before_starts(_path, _type, _starts, _ends), do: []

  ## Filename checks

  defp b2_checks(files) do
    normalized_list =
      Enum.map(files, fn path ->
        case Slug.normalize_path(path) do
          {:ok, normalized, changed?} -> {path, normalized, changed?}
          {:error, _} -> {path, nil, false}
        end
      end)

    non_canonical =
      normalized_list
      |> Enum.filter(fn {_p, _n, changed?} -> changed? end)
      |> Enum.map(fn {path, normalized, _} ->
        %{
          path: path,
          normalized: normalized,
          message: "is not canonical → #{normalized}"
        }
      end)

    long_basenames =
      files
      |> Enum.filter(fn path ->
        String.length(Path.basename(path, ".md")) > @max_basisname_laenge
      end)
      |> Enum.map(fn path -> %{path: path, message: "basename longer than 60 characters"} end)

    collisions =
      normalized_list
      |> Enum.filter(fn {_p, n, _} -> n != nil end)
      |> Enum.group_by(fn {_p, n, _} -> n end)
      |> Enum.filter(fn {_n, group} -> length(group) > 1 end)
      |> Enum.map(fn {normalized, group} ->
        %{
          paths: Enum.map(group, fn {p, _n, _} -> p end),
          normalized: normalized,
          message: "possible collision: several files normalize to #{normalized}"
        }
      end)

    non_canonical ++ long_basenames ++ collisions
  end

  ## Chunk-id diff (old vs. new slug logic)

  defp b3_diff(files, vault_path) do
    changes =
      Enum.flat_map(files, fn rel_path ->
        file_diff =
          case Rules.filename_slug_change(rel_path) do
            nil -> []
            %{old: old, new: new} -> [%{kind: "file", path: rel_path, old: old, new: new}]
          end

        heading_diffs =
          case File.read(Path.join(vault_path, rel_path)) do
            {:ok, content} -> b3_heading_diffs(rel_path, content)
            {:error, _} -> []
          end

        file_diff ++ heading_diffs
      end)

    %{checked: length(files), changes: changes}
  end

  defp b3_heading_diffs(rel_path, content) do
    content
    |> Rules.heading_slug_changes()
    |> Enum.map(fn %{old: old, new: new} ->
      %{kind: "heading", path: rel_path, old: old, new: new}
    end)
  end

  ## Domain drift

  defp b4_drift(vault_path, domain_dirs) do
    domains_yml_keys =
      case YamlElixir.read_from_file(Path.join(vault_path, "_domains.yml")) do
        {:ok, map} when is_map(map) -> Map.keys(map)
        _ -> []
      end

    dirs_without_config =
      domain_dirs
      |> Enum.reject(&(&1 in domains_yml_keys))
      |> Enum.map(fn d ->
        %{message: "domain '#{d}' exists in the vault but is unknown to the runtime"}
      end)

    config_without_dirs =
      domains_yml_keys
      |> Enum.reject(&(&1 in domain_dirs))
      |> Enum.map(fn d ->
        %{message: "domain '#{d}' is configured but does not exist in the vault"}
      end)

    dirs_without_config ++ config_without_dirs
  end

  ## Section separators

  # A heading with no blank line above it. `replace_section` used to eat that
  # line when it rewrote a mid-file section, and the fix (#36, #44) is not
  # retroactive: every note damaged before it still reads that way, and nothing
  # else in the codebase notices. A report, not a repair — principle 5 in
  # docs/design.md.
  #
  # The parse result already answers this, so nothing here re-reads the note: a
  # chunk's body ends at its last **non-blank** line, because the blank lines
  # between two sections belong to neither (docs/design.md, "Chunking"). A
  # heading that starts on the very next line after the previous chunk's body
  # ended therefore has nothing at all between it and that body.
  #
  # Two consequences of taking the chunks as given, both wanted. The H1 title
  # creates no chunk, so it is never checked — its own spacing is a separate
  # question, and never what a section-shaped write could damage. And a heading
  # with no chunk before it opens the note's body, where there was no separator
  # to lose; `chunk_every/4` drops it for free.
  defp b5_checks(path, parsed_file) do
    parsed_file.chunks
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.filter(fn [previous, chunk] ->
      chunk.heading != nil and chunk.heading_line == previous.body_end_line + 1
    end)
    |> Enum.map(fn [_previous, chunk] ->
      %{
        path: path,
        heading: chunk.heading,
        message: "heading '#{chunk.heading}' is not preceded by a blank line"
      }
    end)
  end

  ## Consolidation thresholds

  defp b6_checks(path, parsed_file) do
    heading_chunks = Enum.filter(parsed_file.chunks, & &1.heading)
    note_length = Rules.note_length(parsed_file.chunks)

    duplicates =
      parsed_file.chunks
      |> Rules.duplicate_headings()
      |> Enum.map(fn %{chunks: [first | _] = group} ->
        %{heading: first.heading, count: length(group)}
      end)

    sentence_headings =
      heading_chunks
      |> Enum.filter(fn c -> Rules.sentence_heading?(c.heading) end)
      |> Enum.map(& &1.heading)

    if Rules.overlong?(note_length) or duplicates != [] or sentence_headings != [] do
      [
        note_length
        |> Map.put(:path, path)
        |> Map.put(:duplicate_headings, duplicates)
        |> Map.put(:sentence_headings, sentence_headings)
      ]
    else
      []
    end
  end
end
