defmodule Vigil.MCP.Envelope do
  @moduledoc false
  use GenServer

  alias Vigil.MCP.Envelope.Decision

  @table :vigil_sessions

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Envelope for the `current` tool: always \"_t\", but counts as the session's first call."
  def for_current(session_id, now, snapshot) do
    GenServer.call(__MODULE__, {:for_current, session_id, now, snapshot})
  end

  @doc "Envelope for any other tool call."
  def for_call(session_id, now, snapshot) do
    GenServer.call(__MODULE__, {:for_call, session_id, now, snapshot})
  end

  @impl true
  def init(_) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :named_table, :private])
    end

    {:ok, %{}}
  end

  @impl true
  def handle_call({:for_current, session_id, now, snapshot}, _from, state) do
    {result, session_state} = Decision.for_current(now, snapshot)
    :ets.insert(@table, {session_id, session_state})
    {:reply, result, state}
  end

  def handle_call({:for_call, session_id, now, snapshot}, _from, state) do
    prev_state =
      case :ets.lookup(@table, session_id) do
        [] -> nil
        [{_, session_state}] -> session_state
      end

    {result, session_state} = Decision.for_call(prev_state, now, snapshot)
    :ets.insert(@table, {session_id, session_state})
    {:reply, result, state}
  end
end
