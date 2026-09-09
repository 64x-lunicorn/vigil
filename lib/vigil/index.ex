defmodule Vigil.Index do
  @moduledoc """
  The note/chunk/link index as a pure value.

  A peer of `Vigil.Store`, `Vigil.Parser`, `Vigil.LinkIndex` and
  `Vigil.Events` — not a process, not ETS. `Vigil.Store` keeps exactly one
  of these in its `GenServer` state, so every read still serializes through
  the Store process; the "one writer, serialized reads" trade-off in
  `docs/design.md` is unchanged, the seam just moves inside the process.

  `build/1` takes the vault's parsed files (`Vigil.Parser.File_` structs) and
  returns an index. `put/2` and `remove/2` return a new index — the link
  index (`Vigil.LinkIndex`) is rebuilt in full on every call, as it was in
  `Vigil.Store`'s ETS tables (`docs/design.md`, "The link index").
  """

  alias Vigil.{LinkIndex, Slug}
  alias Vigil.Vault.Policy

  defmodule Note do
    @moduledoc "One vault note, as the index carries it."
    defstruct [
      :path,
      :domain,
      :title,
      :type,
      :starts,
      :ends,
      :created_at,
      :updated_at,
      :chunk_ids
    ]
  end

  defmodule Chunk do
    @moduledoc "One chunk (a heading and its body, or a file's pre-heading text)."
    defstruct [
      :id,
      :path,
      :domain,
      :heading,
      :heading_path,
      :heading_line,
      :body_start_line,
      :body_end_line,
      :file_title,
      :type,
      :starts,
      :ends,
      :body,
      :body_downcased,
      :raw_links,
      :created_at,
      :updated_at
    ]
  end

  defstruct notes: %{}, chunks: %{}, links_out: %{}, links_in: %{}

  @doc "Builds an index from the vault's parsed files."
  def build(parsed_files) do
    {notes, chunks} =
      Enum.reduce(parsed_files, {%{}, %{}}, fn file, {notes, chunks} ->
        {note, file_chunks} = index_file(file)
        {Map.put(notes, note.path, note), Map.merge(chunks, file_chunks)}
      end)

    rebuild_links(%__MODULE__{notes: notes, chunks: chunks})
  end

  @doc "Replaces one note's chunks with a freshly parsed file, then rebuilds the link index in full."
  def put(index, parsed_file) do
    {note, file_chunks} = index_file(parsed_file)
    old_chunk_ids = old_chunk_ids(index, note.path)

    notes = Map.put(index.notes, note.path, note)
    chunks = index.chunks |> Map.drop(old_chunk_ids) |> Map.merge(file_chunks)

    rebuild_links(%{index | notes: notes, chunks: chunks})
  end

  @doc "Removes a note and its chunks, then rebuilds the link index in full."
  def remove(index, path) do
    case old_chunk_ids(index, path) do
      [] ->
        rebuild_links(%{index | notes: Map.delete(index.notes, path)})

      chunk_ids ->
        notes = Map.delete(index.notes, path)
        chunks = Map.drop(index.chunks, chunk_ids)
        rebuild_links(%{index | notes: notes, chunks: chunks})
    end
  end

  defp old_chunk_ids(index, path) do
    case Map.fetch(index.notes, path) do
      {:ok, note} -> note.chunk_ids
      :error -> []
    end
  end

  @doc "The `Note` at `path`, or `nil`."
  def note(index, path), do: Map.get(index.notes, path)

  @doc "`%{notes:, chunks:}` counts, for the load log line."
  def size(index), do: %{notes: map_size(index.notes), chunks: map_size(index.chunks)}

  @doc """
  A fragment id returns the chunk (with backlinks when asked). A bare path
  returns the note's table of contents, its `links` out/in/broken counters
  and, when asked, its backlinks. An id that misses exactly is retried once
  through path normalization (the lenient lookup). A path that fails the
  safety check answers "Invalid path"; anything else "Not found".
  """
  def read(index, id, backlinks?) do
    path_part = id |> String.split("#", parts: 2) |> hd()

    with :ok <- Policy.safe_path(path_part) do
      if String.contains?(id, "#") do
        case lookup_chunk(index, id, path_part) do
          {:ok, chunk} -> {:ok, chunk_result(index, chunk, backlinks?)}
          :not_found -> {:error, "Not found: #{id}"}
        end
      else
        case lookup_note(index, id) do
          {:ok, note} -> {:ok, note_result(index, note, backlinks?)}
          :not_found -> {:error, "Not found: #{id}"}
        end
      end
    else
      {:error, _} -> {:error, "Invalid path"}
    end
  end

  # If the exact lookup misses, the path part is normalized via
  # Slug.normalize_path/1 and tried again — the record that comes back
  # carries the canonical stored id/path anyway.
  defp lookup_chunk(index, exact_id, path_part) do
    case Map.fetch(index.chunks, exact_id) do
      {:ok, chunk} ->
        {:ok, chunk}

      :error ->
        [_, fragment] = String.split(exact_id, "#", parts: 2)

        with {:ok, normalized_path, true} <- Slug.normalize_path(path_part),
             {:ok, chunk} <- Map.fetch(index.chunks, "#{normalized_path}##{fragment}") do
          {:ok, chunk}
        else
          _ -> :not_found
        end
    end
  end

  defp lookup_note(index, exact_path) do
    case Map.fetch(index.notes, exact_path) do
      {:ok, note} ->
        {:ok, note}

      :error ->
        with {:ok, normalized_path, true} <- Slug.normalize_path(exact_path),
             {:ok, note} <- Map.fetch(index.notes, normalized_path) do
          {:ok, note}
        else
          _ -> :not_found
        end
    end
  end

  defp chunk_result(index, chunk, backlinks?) do
    base = %{
      id: chunk.id,
      heading: chunk.heading,
      heading_path: chunk.heading_path,
      type: chunk.type,
      starts: iso(chunk.starts),
      ends: iso(chunk.ends),
      body: chunk.body,
      created_at: iso(chunk.created_at),
      updated_at: iso(chunk.updated_at)
    }

    if backlinks? do
      Map.put(base, :backlinks, backlinks_for(index, chunk.path))
    else
      base
    end
  end

  defp note_result(index, note, backlinks?) do
    toc =
      note.chunk_ids
      |> Enum.map(&Map.get(index.chunks, &1))
      |> Enum.filter(&(&1 && &1.heading))
      |> Enum.map(fn chunk ->
        %{id: chunk.id, heading: chunk.heading, heading_path: chunk.heading_path}
      end)

    base = %{
      path: note.path,
      title: note.title,
      type: note.type,
      starts: iso(note.starts),
      ends: iso(note.ends),
      created_at: iso(note.created_at),
      updated_at: iso(note.updated_at),
      toc: toc,
      links: note_link_counts(index, note)
    }

    if backlinks? do
      Map.put(base, :backlinks, backlinks_for(index, note.path))
    else
      base
    end
  end

  # A compact counter field on every note `read` response. Details come from
  # the `links` tool, not from `read` itself.
  defp note_link_counts(index, note) do
    outgoing =
      note.chunk_ids
      |> Enum.flat_map(&Map.get(index.links_out, &1, []))

    %{
      out: Enum.count(outgoing, &(&1.status == :ok)),
      in: length(backlinks_for(index, note.path)),
      broken: Enum.count(outgoing, &(&1.status != :ok))
    }
  end

  defp backlinks_for(index, target_key) do
    index.links_in |> Map.get(target_key, []) |> Enum.uniq()
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp index_file(file) do
    domain = domain_of(file.path)
    chunk_ids = Enum.map(file.chunks, & &1.id)

    note = %Note{
      path: file.path,
      domain: domain,
      title: file.title,
      type: file.type,
      starts: file.starts,
      ends: file.ends,
      created_at: file.created_at,
      updated_at: file.updated_at,
      chunk_ids: chunk_ids
    }

    chunks =
      Map.new(file.chunks, fn chunk ->
        {chunk.id,
         %Chunk{
           id: chunk.id,
           path: chunk.path,
           domain: domain,
           heading: chunk.heading,
           heading_path: chunk.heading_path,
           heading_line: chunk.heading_line,
           body_start_line: chunk.body_start_line,
           body_end_line: chunk.body_end_line,
           file_title: file.title,
           type: chunk.type,
           starts: chunk.starts,
           ends: chunk.ends,
           body: chunk.body,
           body_downcased: chunk.body_downcased,
           raw_links: chunk.links,
           created_at: chunk.created_at,
           updated_at: chunk.updated_at
         }}
      end)

    {note, chunks}
  end

  defp domain_of(path), do: path |> String.split("/") |> hd()

  # Rebuilt in full rather than maintained incrementally — see
  # `Vigil.Store`'s former `rebuild_links_index/0` for why (docs/design.md,
  # "The link index"). `Vigil.LinkIndex` returns bag-shaped lists of pairs;
  # grouped here into maps keyed by chunk id / target key so `read/3` can
  # look them up directly instead of scanning.
  defp rebuild_links(index) do
    files = Map.values(index.notes)
    chunks = Map.values(index.chunks)

    %{out: out, in: in_} = LinkIndex.build(files, chunks)

    %{index | links_out: group_pairs(out), links_in: group_pairs(in_)}
  end

  defp group_pairs(pairs) do
    Enum.reduce(pairs, %{}, fn {key, value}, acc ->
      Map.update(acc, key, [value], &[value | &1])
    end)
  end
end
