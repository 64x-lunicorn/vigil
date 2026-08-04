defmodule Vigil.MCP.RateLimit do
  @moduledoc """
  Fixed-window rate limit for `/mcp`, keyed by access token (AP-6.3).
  Defense in depth, independent of Cloudflare — not a replacement for it.
  """
  use GenServer

  @table :vigil_mcp_rate_limits
  @window_seconds 60

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :named_table, :public])
    end

    {:ok, %{}}
  end

  @doc """
  True if `key` has exceeded the request budget for the current window;
  otherwise records the request and returns false.
  """
  def limited?(key, now \\ System.system_time(:second)) do
    case :ets.lookup(@table, key) do
      [{^key, count, window_start}] when now - window_start <= @window_seconds ->
        if count >= max_requests() do
          true
        else
          :ets.insert(@table, {key, count + 1, window_start})
          false
        end

      _ ->
        :ets.insert(@table, {key, 1, now})
        false
    end
  end

  defp max_requests, do: Application.get_env(:vigil, :rate_limit_rpm, 60)
end
