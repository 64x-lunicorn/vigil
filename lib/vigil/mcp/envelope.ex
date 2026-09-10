defmodule Vigil.MCP.Envelope do
  @moduledoc """
  The time envelope for one response: the session table it is decided
  against, and the instant it is decided at.

  A `GenServer` only because the table needs an owner that outlives a request —
  exactly as `Vigil.RateLimit`'s does. The table is public and the lookup
  and the insert happen in the caller, so a response costs no process hop to
  do one read and one write. `Vigil.Store.snapshot/1` costs none either, which
  is what keeps a response at one call into the writer: the tool's own.

  What the envelope says is `Vigil.MCP.Envelope.Decision`'s to decide,
  including which form a given tool gets. This module holds the state that
  decision is made against, reads the clock and fetches the snapshot it is
  made with, and nothing else.
  """
  use GenServer

  alias Vigil.Clock
  alias Vigil.MCP.Envelope.Decision
  alias Vigil.Store

  @table :vigil_sessions

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc """
  The envelope for one response to `tool` in `session_id`, recording the
  session state it leaves behind. Returns `{envelope, now}`.

  One entry point for every tool: the router hands over the session and the
  tool's name and asks nothing else. The instant comes back with the envelope
  because the response has exactly one — the tool that answers *what time is
  it* is handed the same one its envelope was decided at, rather than reading
  a second clock a moment later on the other side of the writer.

  Taking the clock and the snapshot together here is also what makes them
  agree: a snapshot from a different instant than the one it is compared
  against would compile and silently mis-decide a phase change, and there is
  no longer a signature that can express it.
  """
  def for_tool(session_id, tool) do
    now = Clock.now()

    {envelope, session_state} =
      Decision.for_tool(tool, previous(session_id), now, Store.snapshot(now))

    :ets.insert(@table, {session_id, session_state})
    {envelope, now}
  end

  defp previous(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, session_state}] -> session_state
      [] -> nil
    end
  end

  @impl true
  def init(_) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :named_table, :public])
    end

    {:ok, %{}}
  end
end
