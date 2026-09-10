defmodule Vigil.Vault.Frontmatter do
  @moduledoc """
  Whether a note's frontmatter says something the vault allows, and what its
  timestamps are worth.

  The rule of `docs/design.md`, "Frontmatter — exactly one required field",
  stated once: three types, only `event` may carry `starts` and `ends`, both
  or neither, ISO 8601 with an offset, and `ends` not before `starts`.

  Pure, and it renders nothing. `check/3` answers with the parsed values or
  with a typed problem, and a caller renders that verdict in its own register
  rather than stating the rule again: `Vigil.Vault.Policy` renders it as the
  refusal the write gate hands back. `Vigil.Parser` still states the rule
  itself, as a downgrade to `reference` plus a warning, and so does the
  doctor, as a finding; both are to be moved onto this module.

  Stating it three times is how the write gate came to accept an event whose
  `ends` preceded its `starts` — a note the parser then downgraded to
  `reference` when it indexed it, so the file on disk said one thing and the
  index another. Vigil is the vault's only writer; a write path that can
  produce a note its own reader refuses has no second writer to blame.
  """

  @enforce_keys [:type, :starts, :ends]
  defstruct [:type, :starts, :ends]

  @typedoc "A frontmatter the vault accepts, with its timestamps parsed."
  @type t :: %__MODULE__{
          type: type(),
          starts: DateTime.t() | nil,
          ends: DateTime.t() | nil
        }

  @type type :: :reference | :decision | :event

  @typedoc """
  What is wrong with a frontmatter, in the terms the rule is stated in rather
  than in any caller's wording. `{:unknown_type, value}` carries the value it
  refused, because a caller reporting on a note wants to quote it.
  """
  @type problem ::
          :type_missing
          | {:unknown_type, term()}
          | :times_missing
          | :times_not_allowed
          | :times_unparsable
          | :ends_before_starts

  @types %{
    "reference" => :reference,
    "decision" => :decision,
    "event" => :event
  }

  @doc """
  The verdict on one frontmatter: a `type` and the raw `starts`/`ends` beside
  it, as they were written.

  A timestamp is a string, or a `DateTime` the YAML reader already recognised
  as one. Absent values are `nil` — which for a non-event is the only thing
  they may be.
  """
  @spec check(term(), term(), term()) :: {:ok, t()} | {:error, problem()}
  def check(type, starts, ends) do
    with {:ok, type} <- type(type),
         :ok <- times_declared(type, starts, ends),
         {:ok, starts, ends} <- times(type, starts, ends) do
      {:ok, %__MODULE__{type: type, starts: starts, ends: ends}}
    end
  end

  defp type(nil), do: {:error, :type_missing}

  defp type(type) when is_binary(type) do
    case Map.fetch(@types, type) do
      {:ok, type} -> {:ok, type}
      :error -> {:error, {:unknown_type, type}}
    end
  end

  # An atom is what a request built in Elixir rather than parsed out of a tool
  # call carries. The same three names, and no others: an atom the vault has
  # no meaning for is as unknown as a string it has no meaning for.
  defp type(type) when is_atom(type) do
    if type in Map.values(@types), do: {:ok, type}, else: {:error, {:unknown_type, type}}
  end

  defp type(type), do: {:error, {:unknown_type, type}}

  # Both or neither, and only on an event. `starts` without `ends` is the case
  # the vault cannot represent: `current` needs both to place a note in a
  # phase.
  defp times_declared(:event, starts, ends) when is_nil(starts) or is_nil(ends),
    do: {:error, :times_missing}

  defp times_declared(:event, _starts, _ends), do: :ok

  defp times_declared(_type, starts, ends) when is_nil(starts) and is_nil(ends), do: :ok

  defp times_declared(_type, _starts, _ends), do: {:error, :times_not_allowed}

  defp times(:event, starts, ends) do
    with {:ok, starts} <- timestamp(starts),
         {:ok, ends} <- timestamp(ends) do
      if DateTime.compare(ends, starts) == :lt do
        {:error, :ends_before_starts}
      else
        {:ok, starts, ends}
      end
    end
  end

  defp times(_type, _starts, _ends), do: {:ok, nil, nil}

  defp timestamp(%DateTime{} = timestamp), do: {:ok, timestamp}

  defp timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, timestamp, _offset} -> {:ok, timestamp}
      {:error, _reason} -> {:error, :times_unparsable}
    end
  end

  defp timestamp(_timestamp), do: {:error, :times_unparsable}
end
