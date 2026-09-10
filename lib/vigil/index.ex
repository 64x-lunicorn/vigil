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

  alias Vigil.{Events, LinkIndex, Parser, Search, Slug}
  alias Vigil.Vault.{Policy, Rules}

  @overlong_note_chunk_threshold 40
  @stale_decision_days 180

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

    @type t :: %__MODULE__{}
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

  @doc "Incoming references to `key` (a note path or a full chunk id) — the write path's backlinks question."
  def backlinks(index, key), do: backlinks_for(index, key)

  @doc """
  The adapters `Vigil.Vault.Facts` carries for the questions only the index can
  answer, as a map ready to be merged into a `Facts` struct.

  The policy asks them about the path it derived itself, which is why they are
  closures over the index rather than values looked up ahead of the decision.
  """
  def lookups(index) do
    %{
      count_headings: fn path -> heading_count(index, path) end,
      find_chunk: fn id -> find_chunk(index, id) end
    }
  end

  # The chunk a section id resolves to, or nil — through the same lenient
  # resolution `read/3` uses, so an id that reads is an id that writes. The
  # record carries the canonical path, which is what makes leniency safe: the
  # write goes where the lookup landed, not where the id pointed.
  defp find_chunk(index, id) do
    case String.split(id, "#", parts: 2) do
      [path_part, _fragment] ->
        case lookup_chunk(index, id, path_part) do
          {:ok, chunk} -> chunk
          :not_found -> nil
        end

      [_without_fragment] ->
        nil
    end
  end

  # How many of `path`'s chunks carry a heading — the `rewrite_note` shrink
  # gate's baseline, reached through `lookups/1`.
  defp heading_count(index, path) do
    case Map.get(index.notes, path) do
      nil -> 0
      note -> Enum.count(note.chunk_ids, &heading_chunk?(index, &1))
    end
  end

  defp heading_chunk?(index, chunk_id) do
    case Map.get(index.chunks, chunk_id) do
      nil -> false
      chunk -> chunk.heading != nil
    end
  end

  @doc "The chunk in `path` whose heading slug matches `target_slug`, or `nil` — `append`'s existing-section lookup."
  def chunk_by_heading(index, path, target_slug) do
    case Map.get(index.notes, path) do
      nil ->
        nil

      note ->
        note.chunk_ids
        |> Enum.map(&Map.get(index.chunks, &1))
        |> Enum.find(fn chunk ->
          chunk && chunk.heading && Parser.slug(chunk.heading) == target_slug
        end)
    end
  end

  @doc """
  Answers the `search` tool: the domain and type filters apply before
  matching, `journal/` is hidden unless asked for by name, ranking and
  previews come from `Vigil.Search`, and `hub` is attached when exactly one
  other note links to the hit's note.
  """
  def search(index, params) do
    query = Map.fetch!(params, :query)
    domain = Map.get(params, :domain)
    type_filter = Map.get(params, :type)
    prefer = Map.get(params, :prefer)
    limit = Map.get(params, :limit, 10)

    index.chunks
    |> Map.values()
    |> Enum.filter(&search_filter?(&1, domain, type_filter))
    |> Enum.map(&search_item/1)
    |> Search.run(query, %{limit: limit, prefer: prefer})
    |> Enum.map(&attach_hub(index, &1))
  end

  defp search_filter?(chunk, domain, type_filter) do
    domain_ok =
      case domain do
        nil -> chunk.domain != "journal"
        d -> chunk.domain == d
      end

    type_ok = type_filter == nil or chunk.type == type_filter
    domain_ok and type_ok
  end

  defp search_item(chunk) do
    %{
      id: chunk.id,
      file_title: chunk.file_title,
      heading_path: chunk.heading_path,
      type: chunk.type,
      body: chunk.body,
      body_downcased: chunk.body_downcased,
      updated_at: chunk.updated_at
    }
  end

  # The hub of a note, when exactly one other note links to it. Linked from
  # several notes means the hub is ambiguous, and the field is omitted rather
  # than guessed.
  defp attach_hub(index, result) do
    note_path = result.id |> String.split("#", parts: 2) |> hd()

    source_notes =
      index
      |> backlinks_for(note_path)
      |> Enum.map(fn source_chunk_id ->
        source_chunk_id |> String.split("#", parts: 2) |> hd()
      end)
      |> Enum.uniq()
      |> Enum.reject(&(&1 == note_path))

    case source_notes do
      [hub] -> Map.put(result, :hub, hub)
      _ -> result
    end
  end

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

  @doc """
  Answers the `links` tool: outgoing references per chunk with status
  ok/ambiguous/broken (an ambiguous link lists its candidates; a broken
  link to an existing note with a missing fragment names the fragment),
  incoming references, direction `:out`/`:in`/`:both`, depth 1, depth 2
  adding each directly connected note's own depth-1 view with no further
  recursion, any other depth an error, and the same lenient id resolution
  `read/3` uses.
  """
  def links(index, id, direction, depth) do
    path_part = id |> String.split("#", parts: 2) |> hd()

    with :ok <- Policy.safe_path(path_part),
         :ok <- validate_depth(depth) do
      if String.contains?(id, "#") do
        case lookup_chunk(index, id, path_part) do
          {:ok, chunk} -> {:ok, build_links_result(index, chunk.id, [chunk.id], direction, depth)}
          :not_found -> {:error, "Not found: #{id}"}
        end
      else
        case lookup_note(index, id) do
          {:ok, note} ->
            {:ok, build_links_result(index, note.path, note.chunk_ids, direction, depth)}

          :not_found ->
            {:error, "Not found: #{id}"}
        end
      end
    else
      {:error, msg} -> {:error, msg}
    end
  end

  defp validate_depth(d) when d in [1, 2], do: :ok
  defp validate_depth(_), do: {:error, "depth must be 1 or 2 (no deeper value allowed)"}

  defp build_links_result(index, id, chunk_ids, direction, depth) do
    base = %{id: id}

    base =
      if direction in [:out, :both],
        do: Map.put(base, :outgoing, outgoing_for(index, chunk_ids)),
        else: base

    base =
      if direction in [:in, :both],
        do: Map.put(base, :incoming, incoming_for(index, id)),
        else: base

    if depth == 2, do: Map.put(base, :neighbors, neighbors_for(index, base, id)), else: base
  end

  defp outgoing_for(index, chunk_ids) do
    Enum.flat_map(chunk_ids, fn cid ->
      index.links_out
      |> Map.get(cid, [])
      |> Enum.map(&format_outgoing(cid, &1))
    end)
  end

  defp format_outgoing(from_chunk, %{status: :ok, target_chunk: nil, target_note: note}) do
    %{target: note, from_chunk: from_chunk, status: "ok"}
  end

  defp format_outgoing(from_chunk, %{status: :ok, target_chunk: chunk_id}) do
    %{target: chunk_id, from_chunk: from_chunk, status: "ok"}
  end

  defp format_outgoing(from_chunk, %{status: :ambiguous, candidates: candidates} = resolved) do
    %{
      target: link_label(resolved),
      from_chunk: from_chunk,
      status: "ambiguous",
      candidates: candidates
    }
  end

  defp format_outgoing(from_chunk, %{status: :broken} = resolved) do
    %{target: link_label(resolved), from_chunk: from_chunk, status: "broken"}
  end

  # A link to an existing note with a non-existent fragment is `broken` too.
  # Without the fragment in the label the finding would read as "note
  # missing" when only the section is missing.
  defp link_label(%{raw: raw, fragment: nil}), do: raw
  defp link_label(%{raw: raw, fragment: fragment}), do: "#{raw}##{fragment}"

  defp incoming_for(index, id) do
    index
    |> backlinks_for(id)
    |> Enum.map(fn source -> %{source: source, status: "ok"} end)
  end

  # depth: 2 — for each directly connected note its own depth-1 out/in, with
  # no further recursion. Beyond that the value drops off fast while the
  # response size does not.
  defp neighbors_for(index, base, own_id) do
    own_note = own_id |> String.split("#", parts: 2) |> hd()

    outgoing_notes =
      base
      |> Map.get(:outgoing, [])
      |> Enum.filter(&(&1.status == "ok"))
      |> Enum.map(fn %{target: t} -> t |> String.split("#", parts: 2) |> hd() end)

    incoming_notes =
      base
      |> Map.get(:incoming, [])
      |> Enum.map(fn %{source: s} -> s |> String.split("#", parts: 2) |> hd() end)

    (outgoing_notes ++ incoming_notes)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == own_note))
    |> Map.new(fn note_path ->
      chunk_ids = note_chunk_ids(index, note_path)

      {note_path,
       %{outgoing: outgoing_for(index, chunk_ids), incoming: incoming_for(index, note_path)}}
    end)
  end

  defp note_chunk_ids(index, note_path) do
    case Map.get(index.notes, note_path) do
      %Note{chunk_ids: ids} -> ids
      nil -> []
    end
  end

  @doc """
  Answers the `lint` tool's five findings: duplicate headings, sentence-like
  headings (via `Vigil.Vault.Rules`), orphaned links (broken outgoing links,
  labelled with their fragment where present), overlong notes past the
  chunk threshold, and decision notes stale relative to `now`.
  """
  def lint(index, now) do
    notes = Map.values(index.notes)
    chunks = Map.values(index.chunks)

    %{
      duplicate_headings: lint_duplicate_headings(chunks),
      sentence_headings: lint_sentence_headings(chunks),
      orphaned_links: lint_orphaned_links(index),
      overlong_notes: lint_overlong_notes(notes),
      stale_decisions: lint_stale_decisions(notes, now)
    }
  end

  defp lint_duplicate_headings(chunks) do
    chunks
    |> Enum.filter(& &1.heading)
    |> Enum.group_by(&{&1.path, &1.heading_path})
    |> Enum.filter(fn {_key, group} -> length(group) > 1 end)
    |> Enum.map(fn {{path, heading_path}, group} ->
      %{path: path, heading_path: heading_path, ids: Enum.map(group, & &1.id)}
    end)
  end

  defp lint_sentence_headings(chunks) do
    chunks
    |> Enum.filter(fn c -> c.heading && Rules.sentence_heading?(c.heading) end)
    |> Enum.map(fn c -> %{id: c.id, heading: c.heading} end)
  end

  defp lint_orphaned_links(index) do
    index.links_out
    |> Map.values()
    |> List.flatten()
    |> Enum.filter(&(&1.status == :broken))
    |> Enum.map(&link_label/1)
    |> Enum.uniq()
  end

  defp lint_overlong_notes(notes) do
    notes
    |> Enum.filter(fn n -> length(n.chunk_ids) > @overlong_note_chunk_threshold end)
    |> Enum.map(fn n -> %{path: n.path, chunk_count: length(n.chunk_ids)} end)
  end

  defp lint_stale_decisions(notes, now) do
    cutoff = DateTime.add(now, -@stale_decision_days * 86_400, :second)

    notes
    |> Enum.filter(fn n ->
      n.type == :decision and n.updated_at != nil and
        DateTime.compare(n.updated_at, cutoff) == :lt
    end)
    |> Enum.map(fn n -> %{path: n.path, updated_at: iso(n.updated_at)} end)
  end

  @doc "%{now:, active:, upcoming:, recently_past:} from `Vigil.Events`, over the index's event-typed notes."
  def current(index, now), do: Events.current(event_notes(index), now)

  @doc "%{active_ids:, near:, titles:} from `Vigil.Events`, over the index's event-typed notes."
  def snapshot(index, now), do: Events.snapshot(event_notes(index), now)

  defp event_notes(index) do
    index.notes |> Map.values() |> Enum.filter(&(&1.type == :event))
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
