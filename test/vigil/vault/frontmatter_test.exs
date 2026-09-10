defmodule Vigil.Vault.FrontmatterTest do
  use ExUnit.Case, async: true

  alias Vigil.Vault.Frontmatter

  @morning "2026-06-01T10:00:00+01:00"
  @noon "2026-06-01T12:00:00+01:00"

  # The whole rule as one table: what a note may declare, and what each
  # declaration is worth. Every caller of the owner renders one of these
  # verdicts — the write gate as a refusal, the parser as a downgrade, the
  # doctor as a finding — so the rule is asserted here rather than through
  # any one of them.
  @table [
    {"a reference declares no times", "reference", nil, nil, {:ok, :reference, nil, nil}},
    {"a decision declares no times", "decision", nil, nil, {:ok, :decision, nil, nil}},
    {"an event declares both times", "event", @morning, @noon, {:ok, :event, @morning, @noon}},
    {"an event may start and end at the same instant", "event", @noon, @noon,
     {:ok, :event, @noon, @noon}},
    {"the three types are also accepted as atoms", :event, @morning, @noon,
     {:ok, :event, @morning, @noon}},
    {"no type at all", nil, nil, nil, {:error, :type_missing}},
    {"a type outside the three", "note", nil, nil, {:error, {:unknown_type, "note"}}},
    {"an atom outside the three", :note, nil, nil, {:error, {:unknown_type, :note}}},
    {"an event without ends", "event", @morning, nil, {:error, :times_missing}},
    {"an event without starts", "event", nil, @noon, {:error, :times_missing}},
    {"an event without either", "event", nil, nil, {:error, :times_missing}},
    {"a reference carrying starts", "reference", @morning, nil, {:error, :times_not_allowed}},
    {"a decision carrying ends", "decision", nil, @noon, {:error, :times_not_allowed}},
    {"a timestamp without an offset", "event", "2026-06-01T10:00:00", @noon,
     {:error, :times_unparsable}},
    {"a timestamp that is not a timestamp", "event", "yesterday", "tomorrow",
     {:error, :times_unparsable}},
    {"a date without a time", "event", "2026-06-01", @noon, {:error, :times_unparsable}},
    {"ends before starts", "event", @noon, @morning, {:error, :ends_before_starts}}
  ]

  describe "check/3" do
    for {name, type, starts, ends, expected} <- @table do
      test name do
        assert_verdict(unquote(Macro.escape(type)), unquote(starts), unquote(ends),
          expected: unquote(Macro.escape(expected))
        )
      end
    end

    # The parser reads its values out of YAML, which hands back a DateTime for
    # a timestamp it recognised itself. Same verdict, same parsed values.
    test "timestamps already parsed by the YAML reader are accepted" do
      {:ok, starts, _} = DateTime.from_iso8601(@morning)
      {:ok, ends, _} = DateTime.from_iso8601(@noon)

      assert {:ok, %Frontmatter{type: :event, starts: ^starts, ends: ^ends}} =
               Frontmatter.check("event", starts, ends)
    end

    test "a timestamp of the wrong shape entirely does not parse" do
      assert {:error, :times_unparsable} = Frontmatter.check("event", 20_260_601, @noon)
    end
  end

  defp assert_verdict(type, starts, ends, expected: {:ok, expected_type, nil, nil}) do
    assert {:ok, %Frontmatter{type: ^expected_type, starts: nil, ends: nil}} =
             Frontmatter.check(type, starts, ends)
  end

  defp assert_verdict(type, starts, ends, expected: {:ok, expected_type, raw_starts, raw_ends}) do
    {:ok, expected_starts, _} = DateTime.from_iso8601(raw_starts)
    {:ok, expected_ends, _} = DateTime.from_iso8601(raw_ends)

    assert {:ok,
            %Frontmatter{type: ^expected_type, starts: ^expected_starts, ends: ^expected_ends}} =
             Frontmatter.check(type, starts, ends)
  end

  defp assert_verdict(type, starts, ends, expected: {:error, problem}) do
    assert Frontmatter.check(type, starts, ends) == {:error, problem}
  end
end
