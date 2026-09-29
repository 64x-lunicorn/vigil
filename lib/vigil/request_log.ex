defmodule Vigil.RequestLog do
  @moduledoc """
  The writes the writer has already applied, by the `request_id` their caller
  gave them (`docs/design.md`, "A retried write is applied once").

  A write can outlive the client's call timeout and still complete. The client
  sees an error and retries, and an `append` retried is an `append` twice. A
  caller that names its write with an id gets the first answer back for the
  retry instead of a second write.

  An id is remembered with a fingerprint of the write it named. The same id
  for a different write is a `:conflict`, never the first write's answer: a
  client that reuses an id by mistake must be told so, not handed the result
  of something it did not ask for.

  Bounded twice, so a client that sends a fresh id with every write cannot
  grow the writer without limit: by count — past `max_entries` the oldest id
  goes first — and by age — an id older than `max_age_ms` is forgotten. A
  retry comes within minutes of the call it repeats; one that comes later is a
  new write.

  Pure: the instant is handed in, in milliseconds on a clock that only moves
  forward (`Vigil.Store` hands in `System.monotonic_time/1`), so both bounds
  are tested without waiting. Kept in memory only — a restart forgets every
  id, which is the cost of not writing a second store next to the vault.
  """

  @default_max_entries 1_000
  @default_max_age_ms :timer.hours(1)

  @enforce_keys [:max_entries, :max_age_ms]
  defstruct [:max_entries, :max_age_ms, entries: %{}, order: :queue.new()]

  @type t :: %__MODULE__{
          max_entries: pos_integer(),
          max_age_ms: pos_integer(),
          entries: %{String.t() => {term(), term(), integer()}},
          order: :queue.queue({String.t(), integer()})
        }

  @doc """
  An empty log. `max_entries` (default #{@default_max_entries}) and
  `max_age_ms` (default one hour) are the two bounds.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      max_entries: Keyword.get(opts, :max_entries, @default_max_entries),
      max_age_ms: Keyword.get(opts, :max_age_ms, @default_max_age_ms)
    }
  end

  @doc """
  What `id` was remembered with at `now`: `{:applied, result}` for the same
  write, `:conflict` for a different one, `:unknown` for an id never seen or
  already forgotten.
  """
  @spec lookup(t(), String.t(), term(), integer()) :: {:applied, term()} | :conflict | :unknown
  def lookup(%__MODULE__{} = log, id, fingerprint, now) do
    case Map.fetch(log.entries, id) do
      {:ok, {_fingerprint, _result, at}} when now - at > log.max_age_ms -> :unknown
      {:ok, {^fingerprint, result, _at}} -> {:applied, result}
      {:ok, _other} -> :conflict
      :error -> :unknown
    end
  end

  @doc "Remembers `result` for `id` and the write `fingerprint` names, at `now`."
  @spec remember(t(), String.t(), term(), term(), integer()) :: t()
  def remember(%__MODULE__{} = log, id, fingerprint, result, now) do
    log = forget_expired(log, now)

    log = %{
      log
      | entries: Map.put(log.entries, id, {fingerprint, result, now}),
        order: :queue.in({id, now}, log.order)
    }

    forget_oldest(log)
  end

  @doc "How many ids are remembered."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{} = log), do: map_size(log.entries)

  # The queue is in the order ids were remembered, which is the order of their
  # instants, so everything expired is at its front. An id remembered again
  # after it expired was at the front too, and is gone before it goes back in.
  defp forget_expired(log, now) do
    case :queue.peek(log.order) do
      {:value, {id, at}} when now - at > log.max_age_ms ->
        forget_expired(drop_front(log, id), now)

      _ ->
        log
    end
  end

  defp forget_oldest(log) do
    if map_size(log.entries) > log.max_entries do
      {:value, {id, _at}} = :queue.peek(log.order)
      forget_oldest(drop_front(log, id))
    else
      log
    end
  end

  defp drop_front(log, id) do
    %{log | entries: Map.delete(log.entries, id), order: :queue.drop(log.order)}
  end
end
