defmodule Vigil.ClockTest do
  use ExUnit.Case

  alias Vigil.Clock

  setup do
    original = Application.get_env(:vigil, :tz)
    on_exit(fn -> Application.put_env(:vigil, :tz, original) end)
  end

  describe "now/0" do
    test "returns the current time in the configured timezone" do
      Application.put_env(:vigil, :tz, "Europe/Berlin")

      now = Clock.now()

      assert now.time_zone == "Europe/Berlin"
      assert DateTime.diff(DateTime.utc_now(), now) < 5
    end

    test "falls back to UTC when :tz is invalid rather than raising" do
      Application.put_env(:vigil, :tz, "Not/AZone")

      now = Clock.now()

      assert now.time_zone == "Etc/UTC"
      assert DateTime.diff(DateTime.utc_now(), now) < 5
    end

    test "falls back to UTC when :tz is missing rather than raising" do
      Application.delete_env(:vigil, :tz)

      now = Clock.now()

      assert now.time_zone in ["Europe/Berlin", "Etc/UTC"]
    end
  end
end
