defmodule Vigil.RateLimit do
  @moduledoc """
  One fixed-window rate limit, as a value its callers hold rather than a
  module they name (`docs/design.md`, "The rate limiter is reached through a
  value").

  Two things live here. The **contract** is a struct of two functions — the
  whole of what a surface asks of a limiter. `limited?` counts one request
  against a budget, and `sweep_expired` reclaims the windows that have
  elapsed. The sweep is part of this surface rather than a concern beside it:
  what counts as an elapsed window is the same fact `limited?` decides on, and
  only one place should hold it.

  The key is whatever the caller counts by and the budget is the caller's to
  choose, so the same window serves `/mcp` keyed by access token (AP-6.3) and
  the authorization server keyed by client address. Both are defence in depth,
  independent of Cloudflare — not a replacement for it.

  `now` is an argument because a test that cannot name the instant can only
  observe the window by waiting a minute for it.

  The **production adapter** is the rest of this module: `over_table/0` wires
  both questions to the one named ETS table this process owns. It is a
  function here, beside the contract it implements, rather than closures
  assembled by a caller — there are three callers, and an adapter assembled at
  the call site would exist three times. Everything below `over_table/0` is
  private, both answers included: they are captured from inside this module,
  so the value is the only way to reach them.

  The **second adapter** is `Vigil.RateLimit.Counter`, which counts in a
  process instead of in a table the node shares; it lives with the tests
  because only they have a use for it, and `test/vigil/rate_limit_test.exs`
  holds both to every claim the contract makes.

  The window's length belongs to the contract rather than to either adapter:
  "the window is fixed rather than sliding" is a claim the suite runs against
  both, and a window each adapter picked for itself would make that claim mean
  two different things. `configured_budget/2` belongs to neither too — it is
  the one read a router makes where it is initialized, and what it read is
  handed to `limited?` from there on.
  """
  use GenServer
  require Logger

  @enforce_keys [
    # Whether `key` has spent `budget` requests inside the window containing
    # `now`; otherwise counts this request against it.
    # (key, budget, now) -> boolean.
    :limited?,
    # Drop the windows that have elapsed at `now` and answer how many were
    # reclaimed. (now) -> non_neg_integer.
    :sweep_expired
  ]

  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @table :vigil_rate_limits
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
  Builds a limiter from an answer to both questions.

  Raises `ArgumentError` when a field is missing or unknown, which is the
  point: an unwired question must fail where the adapter is built, not answer
  something plausible at the moment a request is checked against it. Here the
  rule earns its keep on one answer in particular — a `limited?` nobody wired
  answers `false`, which is not a limiter with a missing part but every caller
  served unlimited.
  """
  @spec new(Enumerable.t()) :: t
  def new(fields), do: struct!(__MODULE__, fields)

  @doc """
  The production adapter: both questions answered over the named table this
  module's process owns.
  """
  @spec over_table() :: t
  def over_table, do: new(limited?: &limited?/3, sweep_expired: &sweep_expired/1)

  @doc "The window's length in seconds — what a refused caller has to wait out."
  def window_seconds, do: @window_seconds

  @doc """
  The one environment read the limiter makes: what the deployment configured
  under `key`, judged by `budget/3`.

  A router makes this read once, at `init/1`. The default goes into the read
  rather than after it, so an unset key reaches the judgement as a budget
  already: not configuring one is not a mistake, and nothing is warned about.
  """
  def configured_budget(key, default),
    do: budget(key, Application.get_env(:vigil, key, default), default)

  @doc """
  `configured` as a budget, or `default` when it is not one.

  Both surfaces take their budget from application configuration, which means
  both can be handed a mistyped environment variable. Falling back keeps that
  from producing a limit that refuses everything or crashes on the comparison,
  and the warning keeps it from being invisible: a limit that is quietly not
  the one you configured is worse than a loud one.

  `key` is taken for that warning and nothing else, and this is where it
  belongs: the function that decides to ignore what a deployment configured is
  the one that has to say so, and a deployment configures three budgets, so it
  has to say which. A caller that warned on this function's behalf would leave
  every other caller falling back in silence.
  """
  def budget(_key, rpm, _default) when is_integer(rpm) and rpm > 0, do: rpm

  def budget(key, configured, default) do
    Logger.warning("#{key} is #{inspect(configured)}, not a positive integer — using #{default}")

    default
  end

  # True if `key` has exceeded `budget` requests for the fixed window
  # containing `now`; otherwise records the request and returns false.
  defp limited?(key, budget, now) do
    cutoff = cutoff(now)

    case :ets.lookup(@table, key) do
      [{^key, count, window_start}] when window_start >= cutoff ->
        if count >= budget do
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

  # Drops the windows that have elapsed at `now` and returns how many were
  # reclaimed.
  #
  # The table is keyed on what arrives from outside — one row per client
  # address per authorization-server endpoint, and one per access token ever
  # presented at `/mcp`. Refresh rotation mints a new access token about every
  # hour, so even normal single-user traffic adds keys for tokens that no
  # longer exist. The budget bounds how fast rows arrive and this sweep bounds
  # how many there are; neither substitutes for the other.
  #
  # Only a window `limited?/3` would already ignore is dropped, so a sweep can
  # never let a caller past a limit it is still subject to — reclaiming an
  # elapsed row and starting a fresh window on the next request are the same
  # decision.
  #
  # The table belongs to this module's process and is gone while that process
  # is restarting, so a sweep can arrive to no table at all. That is not an
  # error to report: the restart already dropped every window, so there is
  # nothing left to reclaim, and the janitor that asked must not go down over
  # it. This guard is this adapter's own and not part of the contract — an
  # adapter with no table to lose has nothing to say about it. `limited?/3`
  # deliberately does not do the same: on the request path a missing table
  # means the limiter is not running, and crashing the request is the honest
  # answer where answering "not limited" would quietly serve every caller
  # unlimited.
  defp sweep_expired(now) do
    case :ets.whereis(@table) do
      :undefined ->
        0

      table ->
        cutoff = cutoff(now)
        :ets.select_delete(table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    end
  end

  # The one statement of where the current window begins. Both readers of it
  # compare the same stored instant against it, so they cannot drift apart:
  # `limited?/3` counts a window at or after the cutoff, and the sweep reclaims
  # exactly the ones before it.
  defp cutoff(now), do: now - @window_seconds
end
