defmodule Vigil.MCP.SessionTest do
  # The session table carries the name this file supplies, so nothing here
  # touches the one production's envelope owns.
  use ExUnit.Case, async: true

  alias Vigil.MCP.{Envelope, Session}

  @sessions __MODULE__.Sessions
  @now 1_700_000_000

  setup do
    start_supervised!({Envelope, name: @sessions})
    :ok
  end

  defp lifetime, do: Session.lifetime_seconds()

  test "a session issued for a token is resumed with that token" do
    id = Session.issue(@sessions, "digest-a", @now)

    assert is_binary(id) and id != ""
    assert Session.resume(@sessions, id, "digest-a", @now + 1) == :ok
  end

  test "every session is issued an id of its own" do
    ids = for _ <- 1..20, do: Session.issue(@sessions, "digest-a", @now)
    assert length(Enum.uniq(ids)) == 20
  end

  test "an id nobody issued is not a session, and is not recorded" do
    assert Session.resume(@sessions, "made-up", "digest-a", @now) == :error
    assert :ets.info(@sessions, :size) == 0
  end

  # Bound to the token that initialized it: another token presenting the id
  # is told the session does not exist, not that it belongs to someone else.
  test "a session is not resumed with another token" do
    id = Session.issue(@sessions, "digest-a", @now)

    assert Session.resume(@sessions, id, "digest-b", @now) == :error
    assert Session.resume(@sessions, id, "digest-a", @now) == :ok
  end

  test "the session table keeps what it was handed for the token, nothing more" do
    id = Session.issue(@sessions, "digest-a", @now)
    assert [{^id, "digest-a", @now, nil}] = :ets.lookup(@sessions, id)
  end

  describe "the lifetime" do
    test "a session expires after its lifetime without a request" do
      id = Session.issue(@sessions, "digest-a", @now)

      assert Session.resume(@sessions, id, "digest-a", @now + lifetime() - 1) == :ok
      assert Session.resume(@sessions, id, "digest-a", @now + 2 * lifetime()) == :error
    end

    test "every request starts the lifetime over" do
      id = Session.issue(@sessions, "digest-a", @now)

      for n <- 1..3 do
        assert Session.resume(@sessions, id, "digest-a", @now + n * (lifetime() - 1)) == :ok
      end
    end

    test "an expired session stays expired, even before the sweep comes by" do
      id = Session.issue(@sessions, "digest-a", @now)

      assert Session.resume(@sessions, id, "digest-a", @now + lifetime()) == :error
      assert Session.resume(@sessions, id, "digest-a", @now) == :error
    end

    test "the sweep removes exactly the expired sessions and says how many" do
      old = Session.issue(@sessions, "digest-a", @now)
      fresh = Session.issue(@sessions, "digest-a", @now + 10)

      assert Session.sweep_expired(@sessions, @now + lifetime()) == 1
      assert :ets.lookup(@sessions, old) == []
      assert Session.resume(@sessions, fresh, "digest-a", @now + lifetime()) == :ok
    end

    # The table belongs to the envelope's process and is gone while that
    # process restarts; the janitor that asked must not go down over it.
    test "a sweep with no table reclaims nothing" do
      assert Session.sweep_expired(__MODULE__.NoSuchTable, @now) == 0
    end
  end

  describe "ending a session" do
    test "an ended session is gone" do
      id = Session.issue(@sessions, "digest-a", @now)

      assert Session.finish(@sessions, id, "digest-a", @now) == :ok
      assert Session.resume(@sessions, id, "digest-a", @now) == :error
      assert :ets.lookup(@sessions, id) == []
    end

    test "only the token that holds a session can end it" do
      id = Session.issue(@sessions, "digest-a", @now)

      assert Session.finish(@sessions, id, "digest-b", @now) == :error
      assert Session.resume(@sessions, id, "digest-a", @now) == :ok
    end

    test "an unknown or expired session cannot be ended" do
      id = Session.issue(@sessions, "digest-a", @now)

      assert Session.finish(@sessions, "made-up", "digest-a", @now) == :error
      assert Session.finish(@sessions, id, "digest-a", @now + lifetime()) == :error
    end
  end

  describe "the envelope's state" do
    test "is nil until the envelope records one, and ends with the session" do
      id = Session.issue(@sessions, "digest-a", @now)

      assert Session.envelope_state(@sessions, id) == nil
      Session.put_envelope_state(@sessions, id, %{some: :state})
      assert Session.envelope_state(@sessions, id) == %{some: :state}

      Session.finish(@sessions, id, "digest-a", @now)
      assert Session.envelope_state(@sessions, id) == nil
    end

    # A session ended between its check and its envelope must not come back
    # as a row with no token behind it.
    test "recording it for a session that is gone does not bring the session back" do
      Session.put_envelope_state(@sessions, "gone", %{some: :state})
      assert :ets.lookup(@sessions, "gone") == []
    end
  end
end
