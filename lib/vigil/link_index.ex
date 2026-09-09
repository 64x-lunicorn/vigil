defmodule Vigil.LinkIndex do
  @moduledoc """
  Resolves `[[...]]`/path links across the vault into an out/in index.

  Pure: `build/2` takes `files` and `chunks` as plain data — the same
  record shapes `Vigil.Store` builds during indexing — and returns the
  resolved index as data, with no ETS reads or writes of its own. The two
  returned lists are shaped so a caller can bulk-insert them straight into
  `:bag`-type ETS tables (`:ets.insert(table, list)`).
  """

  alias Vigil.Slug

  @doc """
  `files`: list of `%{path:, domain:, ...}`.
  `chunks`: list of `%{id:, path:, raw_links: [%{raw:, fragment:}], ...}`.

  Returns `%{out: [{chunk_id, resolved}, ...], in: [{target_key, source_chunk_id}, ...]}`.
  """
  def build(files, chunks) do
    index = build_resolution_index(files)
    chunk_ids = MapSet.new(chunks, & &1.id)

    out =
      for chunk <- chunks, raw_link <- chunk.raw_links do
        {chunk.id, resolve_link(raw_link, chunk.path, index, chunk_ids)}
      end

    in_ = Enum.flat_map(out, fn {chunk_id, resolved} -> record_incoming(chunk_id, resolved) end)

    %{out: out, in: in_}
  end

  # Built once per build rather than once per link. `slugify/1` is
  # expensive (NFC, transliteration, several regex passes). Without this
  # index every link would re-slugify every filename — O(links × files) — and
  # since the index is rebuilt on EVERY write, that would be the hottest path
  # in the server. Measured: ~14 ms per link at 1000 files, i.e. ~14 s per
  # write at 1000 links, far beyond GenServer.call's 5 s timeout. With the
  # index: one O(files) slugify pass, then map lookups.
  defp build_resolution_index(files) do
    %{
      paths: MapSet.new(files, & &1.path),
      by_slug:
        Enum.group_by(files, fn f ->
          case Slug.slugify(Path.basename(f.path, ".md")) do
            {:ok, s} -> s
            {:error, _} -> nil
          end
        end)
        |> Map.delete(nil)
    }
  end

  defp record_incoming(source_chunk_id, %{status: :ok, target_note: note, target_chunk: nil}) do
    [{note, source_chunk_id}]
  end

  defp record_incoming(source_chunk_id, %{status: :ok, target_note: note, target_chunk: chunk_id}) do
    [{note, source_chunk_id}, {chunk_id, source_chunk_id}]
  end

  defp record_incoming(_source_chunk_id, _resolved), do: []

  # resolve_link(%{raw:, fragment:}, source_path, index, chunk_ids)
  #   → %{raw:, fragment:, status: :ok | :ambiguous | :broken, target_note:,
  #        target_chunk:, candidates:}
  # If raw contains a "/" it is treated as a vault-relative path, otherwise
  # as a basename resolved through the cascade same folder → same domain →
  # vault-wide.
  defp resolve_link(%{raw: raw, fragment: fragment}, source_path, index, chunk_ids) do
    base = %{raw: raw, fragment: fragment, candidates: []}

    case resolve_target_note(raw, source_path, index) do
      {:ok, note_path} ->
        resolve_fragment(base, note_path, fragment, chunk_ids)

      {:ambiguous, candidates} ->
        Map.merge(base, %{
          status: :ambiguous,
          target_note: nil,
          target_chunk: nil,
          candidates: candidates
        })

      :broken ->
        Map.merge(base, %{status: :broken, target_note: nil, target_chunk: nil})
    end
  end

  defp resolve_target_note(raw, source_path, index) do
    if String.contains?(raw, "/") do
      target_path = ensure_md_extension(raw)

      if MapSet.member?(index.paths, target_path) do
        {:ok, target_path}
      else
        :broken
      end
    else
      resolve_basename(raw, source_path, index)
    end
  end

  # Same folder first, then same domain, then vault-wide — each stage only
  # if the previous one came up empty. If a stage finds more than one match
  # the result is ambiguous with exactly those candidates, not with those of
  # later stages.
  defp resolve_basename(raw, source_path, index) do
    case Slug.slugify(raw) do
      {:ok, target_slug} ->
        candidates = Map.get(index.by_slug, target_slug, [])

        source_dir = Path.dirname(source_path)
        source_domain = domain_of(source_path)

        same_folder = Enum.filter(candidates, &(Path.dirname(&1.path) == source_dir))
        same_domain = Enum.filter(candidates, &(&1.domain == source_domain))

        cond do
          same_folder != [] -> pick_candidate(same_folder)
          same_domain != [] -> pick_candidate(same_domain)
          true -> pick_candidate(candidates)
        end

      {:error, _} ->
        :broken
    end
  end

  defp pick_candidate([]), do: :broken
  defp pick_candidate([one]), do: {:ok, one.path}
  defp pick_candidate(many), do: {:ambiguous, Enum.map(many, & &1.path)}

  defp ensure_md_extension(path) do
    if String.ends_with?(path, ".md"), do: path, else: path <> ".md"
  end

  defp resolve_fragment(base, note_path, nil, _chunk_ids) do
    Map.merge(base, %{status: :ok, target_note: note_path, target_chunk: nil})
  end

  defp resolve_fragment(base, note_path, fragment, chunk_ids) do
    case Slug.slugify(fragment) do
      {:ok, fragment_slug} ->
        chunk_id = "#{note_path}##{fragment_slug}"

        if MapSet.member?(chunk_ids, chunk_id) do
          Map.merge(base, %{status: :ok, target_note: note_path, target_chunk: chunk_id})
        else
          Map.merge(base, %{status: :broken, target_note: nil, target_chunk: nil})
        end

      {:error, _} ->
        Map.merge(base, %{status: :broken, target_note: nil, target_chunk: nil})
    end
  end

  defp domain_of(path), do: path |> String.split("/") |> hd()
end
