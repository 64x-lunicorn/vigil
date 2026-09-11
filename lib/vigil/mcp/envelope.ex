defmodule Vigil.MCP.Envelope do
  @moduledoc """
  The time envelope for one response: the session table it is decided
  against, and the instant it is decided at.

  A `GenServer` only because the table needs an owner that outlives a request —
  exactly as `Vigil.RateLimit`'s does. The table is public and the lookup
  and the insert happen in the caller, so a response costs no process hop to
  do one read and one write. `Vigil.Store.snapshot/2` costs none either, which
  is what keeps a response at one call into the writer: the tool's own.

  The session table carries the name its caller supplied, the way
  `Vigil.Store`'s registration already does: production supplies none and the
  router falls back to `default_name/0`, and a caller that supplies a name gets
  session state of its own rather than sharing one table with the node. The
  writer the snapshot comes from is an argument for the same reason. Neither is
  defaulted here: one response is decided against one session table and one
  vault, and which ones those are belongs to the router that took the request —
  a default read on this side is how the envelope came to reach a writer nobody
  had handed it.

  What the envelope says is `Vigil.MCP.Envelope.Decision`'s to decide,
  including which form a given tool gets. This module holds the state that
  decision is made against, reads the clock and fetches the snapshot it is
  made with, and nothing else.
  """
  use GenServer

  alias Vigil.Clock
  alias Vigil.MCP.Envelope.Decision
  alias Vigil.Store

  # The name an envelope registers under, and — the same atom — the name of the
  # session table it keeps. One fact, stated here, asked for through
  # `default_name/0` by the router that defaults to it.
  @default_name __MODULE__

  @doc """
  The name production registers an envelope under, for a caller that defaults
  to it rather than restating it.
  """
  @spec default_name() :: atom()
  def default_name, do: @default_name

  def start_link(opts) do
    name = Keyword.get(opts, :name, @default_name)
    GenServer.start_link(__MODULE__, name, name: name)
  end

  @doc """
  The envelope for one response to `tool` in `session_id`, decided against the
  vault `store` holds and recorded in the session table `sessions` names.
  Returns `{envelope, now}`.

  One entry point for every tool: the router hands over the session table, the
  session, the tool's name and the writer, and asks nothing else. The instant
  comes back with the envelope because the response has exactly one — the tool that answers *what time is
  it* is handed the same one its envelope was decided at, rather than reading
  a second clock a moment later on the other side of the writer.

  Taking the clock and the snapshot together here is also what makes them
  agree: a snapshot from a different instant than the one it is compared
  against would compile and silently mis-decide a phase change, and there is
  no longer a signature that can express it.
  """
  def for_tool(sessions, session_id, tool, store) do
    now = Clock.now()

    {envelope, session_state} =
      Decision.for_tool(tool, previous(sessions, session_id), now, Store.snapshot(store, now))

    :ets.insert(sessions, {session_id, session_state})
    {envelope, now}
  end

  defp previous(sessions, session_id) do
    case :ets.lookup(sessions, session_id) do
      [{^session_id, session_state}] -> session_state
      [] -> nil
    end
  end

  @impl true
  def init(name) do
    if :ets.whereis(name) == :undefined do
      :ets.new(name, [:set, :named_table, :public])
    end

    {:ok, %{}}
  end
end
