defmodule Vigil.MCP.Envelope do
  @moduledoc """
  The session table behind the time envelope.

  A `GenServer` only because the table needs an owner that outlives a request —
  exactly as `Vigil.MCP.RateLimit`'s does. The table is public and the lookup
  and the insert happen in the caller, so a response costs no process hop to
  do one read and one write.

  What the envelope says is `Vigil.MCP.Envelope.Decision`'s to decide,
  including which form a given tool gets. This module holds the state that
  decision is made against, and nothing else.
  """
  use GenServer

  alias Vigil.MCP.Envelope.Decision

  @table :vigil_sessions

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc """
  The envelope for one response to `tool` in `session_id`, recording the
  session state it leaves behind.

  One entry point for every tool: the router hands over the tool's name and
  asks nothing else.
  """
  def for_tool(session_id, tool, now, snapshot) do
    {envelope, session_state} = Decision.for_tool(tool, previous(session_id), now, snapshot)
    :ets.insert(@table, {session_id, session_state})
    envelope
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
