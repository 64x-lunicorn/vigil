defmodule Vigil.MCP.EnvelopeTest do
  use ExUnit.Case, async: false

  alias Vigil.Store
  alias Vigil.MCP.Envelope

  setup do
    vault = Vigil.FixtureVault.build()
    on_exit(fn -> Vigil.FixtureVault.cleanup(vault) end)
    start_supervised!({Store, vault_path: vault, exclude: [], git_remote: "origin"})
    start_supervised!(Envelope)
    %{vault: vault}
  end

  test "first call gets '_', second unchanged call gets '_t'" do
    assert %{"_" => line} = Envelope.for_call("session-1")
    assert line =~ ~r/^(Mo|Di|Mi|Do|Fr|Sa|So) \d{2}\.\d{2}\. \d{2}:\d{2}/

    assert %{"_t" => time} = Envelope.for_call("session-1")
    assert time =~ ~r/^\d{2}:\d{2}$/
  end

  test "current always gets '_t' and still counts as the session's first call" do
    assert %{"_t" => _} = Envelope.for_current("session-2")
    assert %{"_t" => _} = Envelope.for_call("session-2")
  end

  test "a phase change during the session is reported as '_!'" do
    write_event(vault_from_store(), starts_offset: 3600, ends_offset: 7200)
    Store.reload()

    assert %{"_" => _} = Envelope.for_call("session-3")

    write_event(vault_from_store(), starts_offset: -60, ends_offset: 3600)
    Store.reload()

    assert %{"_!" => text} = Envelope.for_call("session-3")
    assert text =~ "now active"
  end

  test "two parallel sessions have independent envelope state" do
    assert %{"_" => _} = Envelope.for_call("session-a")
    assert %{"_" => _} = Envelope.for_call("session-b")
    assert %{"_t" => _} = Envelope.for_call("session-a")
    assert %{"_t" => _} = Envelope.for_call("session-b")
  end

  defp vault_from_store do
    :sys.get_state(Store).vault_path
  end

  defp write_event(vault, starts_offset: s_off, ends_offset: e_off) do
    now = DateTime.utc_now()
    starts = DateTime.add(now, s_off, :second) |> DateTime.to_iso8601()
    ends = DateTime.add(now, e_off, :second) |> DateTime.to_iso8601()

    content = """
    ---
    type: event
    starts: #{starts}
    ends: #{ends}
    ---
    # Phasentest
    text
    """

    File.write!(Path.join(vault, "bike/phasentest.md"), content)
  end
end
