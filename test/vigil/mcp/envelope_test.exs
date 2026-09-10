defmodule Vigil.MCP.EnvelopeTest do
  # Vigil.MCP.Envelope is a named singleton also started by ServerTest, so
  # this stays async: false to avoid a name collision with it — nothing here
  # needs a vault, Store, or git fixture any more, which was the real cost.
  use ExUnit.Case, async: false

  alias Vigil.MCP.Envelope

  setup do
    start_supervised!(Envelope)
    :ok
  end

  @now ~U[2026-07-09 11:20:00Z] |> DateTime.shift_zone!("Europe/Berlin")
  @later DateTime.add(@now, 60)

  defp snapshot(opts \\ []) do
    %{
      active_ids: Keyword.get(opts, :active_ids, MapSet.new()),
      near: Keyword.get(opts, :near, %{active: [], upcoming: []}),
      titles: Keyword.get(opts, :titles, %{})
    }
  end

  test "first call gets '_', second unchanged call gets '_t'" do
    assert %{"_" => line} = Envelope.for_tool("session-1", "search", @now, snapshot())
    assert line =~ ~r/^(Mon|Tue|Wed|Thu|Fri|Sat|Sun) \d{2}\.\d{2}\. \d{2}:\d{2}/

    assert %{"_t" => time} = Envelope.for_tool("session-1", "search", @later, snapshot())
    assert time =~ ~r/^\d{2}:\d{2}$/
  end

  test "current always gets '_t' and still counts as the session's first call" do
    assert %{"_t" => _} = Envelope.for_tool("session-2", "current", @now, snapshot())
    assert %{"_t" => _} = Envelope.for_tool("session-2", "search", @later, snapshot())
  end

  test "a phase change during the session is reported as '_!'" do
    assert %{"_" => _} = Envelope.for_tool("session-3", "search", @now, snapshot())

    active_ids = MapSet.new(["bike/phasentest.md"])
    titles = %{"bike/phasentest.md" => "Phasentest"}
    near = %{active: [%{id: "bike/phasentest.md", ends_in: "1h"}], upcoming: []}

    result =
      Envelope.for_tool(
        "session-3",
        "search",
        @later,
        snapshot(active_ids: active_ids, titles: titles, near: near)
      )

    assert %{"_!" => text} = result
    assert text =~ "now active"
  end

  test "the table is public, so no response pays a call into the owning process" do
    assert :ets.info(:vigil_sessions, :protection) == :public
    assert :ets.info(:vigil_sessions, :owner) == Process.whereis(Envelope)
  end

  test "two parallel sessions have independent envelope state" do
    assert %{"_" => _} = Envelope.for_tool("session-a", "search", @now, snapshot())
    assert %{"_" => _} = Envelope.for_tool("session-b", "search", @now, snapshot())
    assert %{"_t" => _} = Envelope.for_tool("session-a", "search", @later, snapshot())
    assert %{"_t" => _} = Envelope.for_tool("session-b", "search", @later, snapshot())
  end
end
