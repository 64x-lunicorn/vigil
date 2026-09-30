defmodule Vigil.AtOnce do
  @moduledoc """
  Runs one function in many processes released at the same instant, for the
  claims that a budget holds under concurrency.

  `Task.async_stream/3` starts its tasks one after another, and a counter
  check is over in well under a microsecond, so tasks started that way mostly
  run in turn and a lookup-then-insert race is almost never hit. Here every
  process is spawned first and parked on a message; only when all of them are
  waiting is the message sent, so they reach the counter together.
  """

  @doc "Runs `fun` in `n` processes at once and answers their results, in no particular order."
  @spec run(pos_integer(), (-> term())) :: [term()]
  def run(n, fun) do
    parent = self()
    ref = make_ref()

    pids =
      for _ <- 1..n do
        spawn_link(fn ->
          receive do
            {:go, ^ref} -> send(parent, {ref, fun.()})
          end
        end)
      end

    Enum.each(pids, &send(&1, {:go, ref}))

    for _ <- 1..n do
      receive do
        {^ref, result} -> result
      end
    end
  end
end
