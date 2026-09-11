defmodule Vigil.MCP.EnvelopeTest do
  # async: true, and what makes it possible is that neither name here is
  # production's: the session table carries the name this file supplies, the
  # way the writer's registration already did, and the writer the snapshot
  # comes from is handed in rather than found by default.
  use ExUnit.Case, async: true

  alias Vigil.MCP.Envelope
  alias Vigil.Store

  # One writer and one session table for this file. Tests inside a module run
  # one after another, so a name per file is all the isolation an async suite
  # needs.
  @store __MODULE__.Writer
  @sessions __MODULE__.Sessions

  # What the envelope *says* is Vigil.MCP.Envelope.Decision's, and
  # DecisionTest pins every form it can take against a hand-built snapshot.
  # What is left for this module — and so for this file — is the three things
  # Decision cannot do for itself: carry a session's state from one response
  # to the next, read the clock once, and fetch the snapshot that instant is
  # decided against out of the vault the Store actually holds.
  setup do
    vault = Vigil.FixtureVault.build()
    on_exit(fn -> Vigil.FixtureVault.cleanup(vault) end)

    start_store(vault)
    start_supervised!({Envelope, name: @sessions})
    %{vault: vault}
  end

  defp start_store(vault) do
    start_supervised!(
      {Store,
       vault_path: vault,
       exclude: [],
       git_remote: "origin",
       git: Vigil.Git.CommitLog.new(vault),
       name: @store}
    )
  end

  # The envelope for one response in this file's session table, decided against
  # this file's vault.
  defp for_tool(session_id, tool), do: Envelope.for_tool(@sessions, session_id, tool, @store)

  defp create_event!(path, title, starts, ends) do
    {:ok, _} =
      Store.call(@store, :create, %{
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
    assert {%{"_" => _}, _now} = for_tool("session-1", "search")
    assert {%{"_t" => _}, _now} = for_tool("session-1", "search")
  end

  test "two parallel sessions have independent envelope state" do
    assert {%{"_" => _}, _} = for_tool("session-a", "search")
    assert {%{"_" => _}, _} = for_tool("session-b", "search")
    assert {%{"_t" => _}, _} = for_tool("session-a", "search")
    assert {%{"_t" => _}, _} = for_tool("session-b", "search")
  end

  test "the instant it returns is the one it decided the envelope at" do
    {%{"_t" => _}, now} = for_tool("session-2", "current")

    assert %DateTime{} = now
    assert {%{"_t" => time}, later} = for_tool("session-2", "current")
    assert time == Calendar.strftime(later, "%H:%M")
    assert DateTime.compare(later, now) != :lt
  end

  # The snapshot is fetched here, not handed in: an event that becomes active
  # between two responses of the same session is one this module has to
  # notice on its own — including the note's title, which only the vault
  # knows.
  test "it decides against the vault's events as they are at that moment" do
    assert {%{"_" => _}, now} = for_tool("session-3", "search")

    create_event!(
      "bike/phasentest.md",
      "Phasentest",
      DateTime.add(now, -3600),
      DateTime.add(now, 3600)
    )

    assert {%{"_!" => "Phasentest now active"}, _} = for_tool("session-3", "search")
    assert {%{"_t" => _}, _} = for_tool("session-3", "search")
  end

  # An empty snapshot is not an answer, it is a different vault: whatever the
  # envelope decides against is recorded as the session's state, so answering
  # "no events" while the writer is down would be read as every active event
  # having finished, and the next response would report a phase change that
  # never happened.
  test "with the writer down a response fails rather than recording an empty vault", %{
    vault: vault
  } do
    {_envelope, now} = for_tool("session-4", "search")

    create_event!(
      "bike/laufend.md",
      "Laufend",
      DateTime.add(now, -3600),
      DateTime.add(now, 3600)
    )

    assert {%{"_!" => "Laufend now active"}, _} = for_tool("session-4", "search")

    stop_supervised!(Store)
    assert_raise ArgumentError, fn -> for_tool("session-4", "search") end

    start_store(vault)

    assert {%{"_t" => _}, _} = for_tool("session-4", "search")
  end

  test "the table is public, so no response pays a call into the owning process" do
    assert :ets.info(@sessions, :protection) == :public
    assert :ets.info(@sessions, :owner) == Process.whereis(@sessions)
  end

  # The other half of the same claim: the snapshot the envelope is decided
  # against is read out of a public table too, so a response costs one call
  # into the writer — the tool's own — and not a second one behind it.
  # The table carries the writer's own name, so a Store started under one of
  # its own publishes through a table of its own.
  test "the events the snapshot is built from are published, not asked for" do
    assert :ets.info(@store, :protection) == :public
    assert :ets.info(@store, :owner) == Process.whereis(@store)
  end
end
