defmodule Vigil.SearchTest do
  use ExUnit.Case, async: true

  alias Vigil.Search

  # `limit` has no default here: Vigil.MCP.Tools declares it (1..25, default
  # 10) and refuses anything outside that, so run/3 trusts what it is handed.
  defp run(items, query, opts \\ %{}), do: Search.run(items, query, Map.put_new(opts, :limit, 10))

  defp item(overrides) do
    Map.merge(
      %{
        id: "x/a.md",
        file_title: "A",
        heading_path: [],
        type: :reference,
        body: "",
        body_downcased: "",
        updated_at: nil
      },
      overrides
    )
  end

  test "title hit outranks body hit" do
    items = [
      item(%{
        id: "x/a.md",
        file_title: "Terra Speed",
        body: "nothing",
        body_downcased: "nothing"
      }),
      item(%{
        id: "x/b.md",
        file_title: "Anderes",
        body: "mentions terra speed once",
        body_downcased: "mentions terra speed once"
      })
    ]

    [first, second] = run(items, "terra speed")
    assert first.id == "x/a.md"
    assert second.id == "x/b.md"
    assert first.score > second.score
  end

  test "prefer hint boosts matching type" do
    items = [
      item(%{
        id: "x/ref.md",
        type: :reference,
        body: "wort",
        body_downcased: "wort"
      }),
      item(%{
        id: "x/dec.md",
        type: :decision,
        body: "wort",
        body_downcased: "wort"
      })
    ]

    [first, _second] = run(items, "wort", %{prefer: :decision})
    assert first.id == "x/dec.md"
  end

  test "no match returns empty list, not an error" do
    items = [item(%{body_downcased: "irrelevant"})]
    assert run(items, "doesnotexist") == []
  end

  test "preview is capped at 120 characters" do
    long_body = String.duplicate("word ", 40)
    items = [item(%{file_title: "Treffer", body: long_body, body_downcased: long_body})]
    [result] = run(items, "treffer")
    assert String.length(result.preview) <= 121
  end

  test "phrase match requires contiguous substring" do
    items = [
      item(%{
        id: "x/together.md",
        body: "terra speed is good",
        body_downcased: "terra speed is good"
      }),
      item(%{
        id: "x/apart.md",
        body: "terra Reifen ... weit entfernt speed",
        body_downcased: "terra reifen ... weit entfernt speed"
      })
    ]

    results = run(items, "terra speed")
    ids = Enum.map(results, & &1.id)
    assert ids == ["x/together.md"]
  end

  test "limit is taken at its word — no clamp, no default of its own" do
    items = for n <- 1..30, do: item(%{id: "x/#{n}.md", file_title: "Treffer #{n}"})

    assert length(run(items, "treffer", %{limit: 25})) == 25
    assert length(run(items, "treffer", %{limit: 3})) == 3
  end

  test "a limit is required: run/3 does not invent one" do
    items = [item(%{file_title: "Treffer"})]

    assert_raise KeyError, fn -> Search.run(items, "treffer", %{}) end
  end

  # The scale a caller filters a score against. Vigil.Vault.Policy's duplicate
  # gate keeps hits at strength(:title) and above, so these are load-bearing
  # for a module outside this one: they are published rather than inferred.
  describe "strength/1" do
    test "each kind contributes what it is published as" do
      title = item(%{file_title: "Terra"})
      assert [%{score: score}] = run([title], "terra")
      assert score == Search.strength(:title)

      heading = item(%{heading_path: ["Terra"]})
      assert [%{score: score}] = run([heading], "terra")
      assert score == Search.strength(:heading)

      once = item(%{body: "terra", body_downcased: "terra"})
      assert [%{score: score}] = run([once], "terra")
      assert score == Search.strength(:body_occurrence)

      preferred = item(%{file_title: "Terra", type: :decision})
      assert [%{score: score}] = run([preferred], "terra", %{prefer: :decision})
      assert score == Search.strength(:title) + Search.strength(:preferred_type)
    end

    test "the body contributes at most its published maximum, however often it hits" do
      body = String.duplicate("terra ", 20)
      many = item(%{body: body, body_downcased: body})

      assert [%{score: score}] = run([many], "terra")
      assert score == Search.strength(:body_occurrences_max)
    end

    # Which is why strength(:title) is documented as "the query names this
    # note", not as "the title matched": a heading hit with the body at its
    # maximum reaches exactly the same score.
    test "a heading hit with the body at its maximum reaches a title hit's score" do
      body = String.duplicate("terra ", 20)
      i = item(%{heading_path: ["Terra"], body: body, body_downcased: body})

      assert [%{score: score}] = run([i], "terra")
      assert score == Search.strength(:heading) + Search.strength(:body_occurrences_max)
      assert score == Search.strength(:title)
    end
  end
end
