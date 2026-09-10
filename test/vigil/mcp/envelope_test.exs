defmodule Vigil.MCP.EnvelopeTest do
  # Vigil.MCP.Envelope is a named singleton also started by ServerTest, so
  # this stays async: false to avoid a name collision with it.
  use ExUnit.Case, async: false

  alias Vigil.MCP.Envelope
  alias Vigil.Store

  # What the envelope *says* is Vigil.MCP.Envelope.Decision's, and
  # DecisionTest pins every form it can take against a hand-built snapshot.
  # What is left for this module — and so for this file — is the three things
  # Decision cannot do for itself: carry a session's state from one response
  # to the next, read the clock once, and fetch the snapshot that instant is
  # decided against out of the vault the Store actually holds.
  setup do
    {vault, _remote} = Vigil.FixtureVault.build(remote: true)
    on_exit(fn -> Vigil.FixtureVault.cleanup(vault) end)
    start_supervised!({Store, vault_path: vault, exclude: [], git_remote: "origin"})
    start_supervised!(Envelope)
    %{vault: vault}
  end

  defp create_event!(path, title, starts, ends) do
    {:ok, _} =
      Store.call(:create, %{
        path: path,
        type: :event,
        content: "# #{title}\n\nBody.\n",
        starts: DateTime.to_iso8601(starts),
        ends: DateTime.to_iso8601(ends),
        force: false,
        create_dirs: false
      })
  end

  test "the session's state is carried from one response to the next" do
    assert {%{"_" => _}, _now} = Envelope.for_tool("session-1", "search")
    assert {%{"_t" => _}, _now} = Envelope.for_tool("session-1", "search")
  end

  test "two parallel sessions have independent envelope state" do
    assert {%{"_" => _}, _} = Envelope.for_tool("session-a", "search")
    assert {%{"_" => _}, _} = Envelope.for_tool("session-b", "search")
    assert {%{"_t" => _}, _} = Envelope.for_tool("session-a", "search")
    assert {%{"_t" => _}, _} = Envelope.for_tool("session-b", "search")
  end

  test "the instant it returns is the one it decided the envelope at" do
    {%{"_t" => _}, now} = Envelope.for_tool("session-2", "current")

    assert %DateTime{} = now
    assert {%{"_t" => time}, later} = Envelope.for_tool("session-2", "current")
    assert time == Calendar.strftime(later, "%H:%M")
    assert DateTime.compare(later, now) != :lt
  end

  # The snapshot is fetched here, not handed in: an event that becomes active
  # between two responses of the same session is one this module has to
  # notice on its own — including the note's title, which only the vault
  # knows.
  test "it decides against the vault's events as they are at that moment" do
    assert {%{"_" => _}, now} = Envelope.for_tool("session-3", "search")

    create_event!(
      "bike/phasentest.md",
      "Phasentest",
      DateTime.add(now, -3600),
      DateTime.add(now, 3600)
    )

    assert {%{"_!" => "Phasentest now active"}, _} = Envelope.for_tool("session-3", "search")
    assert {%{"_t" => _}, _} = Envelope.for_tool("session-3", "search")
  end

  # An empty snapshot is not an answer, it is a different vault: whatever the
  # envelope decides against is recorded as the session's state, so answering
  # "no events" while the writer is down would be read as every active event
  # having finished, and the next response would report a phase change that
  # never happened.
  test "with the writer down a response fails rather than recording an empty vault", %{
    vault: vault
  } do
    {_envelope, now} = Envelope.for_tool("session-4", "search")

    create_event!(
      "bike/laufend.md",
      "Laufend",
      DateTime.add(now, -3600),
      DateTime.add(now, 3600)
    )

    assert {%{"_!" => "Laufend now active"}, _} = Envelope.for_tool("session-4", "search")

    stop_supervised!(Vigil.Store)
    assert_raise ArgumentError, fn -> Envelope.for_tool("session-4", "search") end

    start_supervised!({Store, vault_path: vault, exclude: [], git_remote: "origin"})
    assert {%{"_t" => _}, _} = Envelope.for_tool("session-4", "search")
  end

  test "the table is public, so no response pays a call into the owning process" do
    assert :ets.info(:vigil_sessions, :protection) == :public
    assert :ets.info(:vigil_sessions, :owner) == Process.whereis(Envelope)
  end

  # The other half of the same claim: the snapshot the envelope is decided
  # against is read out of a public table too, so a response costs one call
  # into the writer — the tool's own — and not a second one behind it.
  test "the events the snapshot is built from are published, not asked for" do
    assert :ets.info(:vigil_events, :protection) == :public
    assert :ets.info(:vigil_events, :owner) == Process.whereis(Store)
  end
end
