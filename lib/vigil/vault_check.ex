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

  alias Vigil.{Parser, Slug, VaultDiscovery}

  @heading_re ~r/^(\#{2,4})\s+(.+?)\s*$/
  @h1_re ~r/^\#\s+(.+?)\s*$/
  @sentence_heading_length_threshold 60
  @max_headings 30
  @max_words 2000
  @max_basisname_laenge 60
  @max_frontmatter_bytes 1024

  def run(vault_path) do
    unless File.dir?(vault_path) do
      raise "Not a directory: #{vault_path}"
    end

    domain_dirs = VaultDiscovery.domain_dirs(vault_path)
    files = VaultDiscovery.discover_files(vault_path)

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
    case String.split(content, "\n") do
      ["---" | rest] ->
        case find_closing(rest, 0) do
          {:ok, yaml_lines, _idx} -> {:ok, Enum.join(yaml_lines, "\n")}
          :not_found -> :missing
        end

      _ ->
        :missing
    end
  end

  defp find_closing(lines, idx) do
    case Enum.at(lines, idx) do
      nil -> :not_found
      "---" -> {:ok, Enum.take(lines, idx), idx}
      _ -> find_closing(lines, idx + 1)
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
        basename = Path.basename(rel_path, ".md")

        file_diff =
          case {Slug.legacy_slugify(basename), Slug.slugify(basename)} do
            {old, {:ok, new}} when old != new ->
              [%{kind: "file", path: rel_path, old: old, new: new}]

            {old, {:error, _}} ->
              [%{kind: "file", path: rel_path, old: old, new: nil}]

            _ ->
              []
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
    |> String.split("\n")
    |> Enum.filter(fn line ->
      Regex.match?(@heading_re, line) and not Regex.match?(@h1_re, line)
    end)
    |> Enum.flat_map(fn line ->
      [_, _, text] = Regex.run(@heading_re, line)
      text = String.trim(text)

      case {Slug.legacy_slugify(text), Slug.slugify(text)} do
        {old, {:ok, new}} when old != new ->
          [%{kind: "heading", path: rel_path, old: old, new: new}]

        {old, {:error, _}} ->
          [%{kind: "heading", path: rel_path, old: old, new: nil}]

        _ ->
          []
      end
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

  ## Consolidation thresholds

  defp b6_checks(path, parsed_file) do
    heading_chunks = Enum.filter(parsed_file.chunks, & &1.heading)
    heading_count = length(heading_chunks)

    word_count =
      parsed_file.chunks
      |> Enum.map(& &1.body)
      |> Enum.join(" ")
      |> String.split(~r/\s+/, trim: true)
      |> length()

    duplicates =
      heading_chunks
      |> Enum.group_by(& &1.heading)
      |> Enum.filter(fn {_h, group} -> length(group) > 1 end)
      |> Enum.map(fn {heading, group} -> %{heading: heading, count: length(group)} end)

    sentence_headings =
      heading_chunks
      |> Enum.filter(fn c -> sentence_heading?(c.heading) end)
      |> Enum.map(& &1.heading)

    if heading_count > @max_headings or word_count > @max_words or duplicates != [] or
         sentence_headings != [] do
      [
        %{
          path: path,
          headings: heading_count,
          words: word_count,
          over_heading_threshold: heading_count > @max_headings,
          over_word_threshold: word_count > @max_words,
          duplicate_headings: duplicates,
          sentence_headings: sentence_headings
        }
      ]
    else
      []
    end
  end

  defp sentence_heading?(heading) do
    String.length(heading) > @sentence_heading_length_threshold or
      String.ends_with?(heading, [".", "!", "?"])
  end
end
