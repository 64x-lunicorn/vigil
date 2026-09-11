defmodule Vigil.ClockTest do
  @moduledoc """
  The vault's notion of "now", against the timezone it is given.

  async: true, and what makes it possible is that the timezone is an argument:
  these tests used to set `:tz` in global application env and put it back
  afterwards, which is a deployment installed rather than stated. Where the
  value comes from is `Vigil.Settings`' question now, and it is answered once,
  at the composition root.
  """
  use ExUnit.Case, async: true

  alias Vigil.Clock

  describe "now/1" do
    test "returns the current time in the timezone it was given" do
      now = Clock.now("Europe/Berlin")

      assert now.time_zone == "Europe/Berlin"
      assert DateTime.diff(DateTime.utc_now(), now) < 5
    end

    # The write path must stay crash-safe by construction, so a timezone that
    # is not a zone costs the caller its offset and nothing else.
    test "falls back to UTC when the timezone is not a zone rather than raising" do
      now = Clock.now("Not/AZone")

      assert now.time_zone == "Etc/UTC"
      assert DateTime.diff(DateTime.utc_now(), now) < 5
    end

    test "a nil timezone is not a zone either, and is answered the same way" do
      assert Clock.now(nil).time_zone == "Etc/UTC"
    end
  end
end
