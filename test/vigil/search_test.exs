defmodule Vigil.SearchTest do
  use ExUnit.Case, async: true

  alias Vigil.Search

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

    [first, second] = Search.run(items, "terra speed")
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

    [first, _second] = Search.run(items, "wort", %{prefer: :decision})
    assert first.id == "x/dec.md"
  end

  test "no match returns empty list, not an error" do
    items = [item(%{body_downcased: "irrelevant"})]
    assert Search.run(items, "doesnotexist") == []
  end

  test "preview is capped at 120 characters" do
    long_body = String.duplicate("word ", 40)
    items = [item(%{file_title: "Treffer", body: long_body, body_downcased: long_body})]
    [result] = Search.run(items, "treffer")
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

    results = Search.run(items, "terra speed")
    ids = Enum.map(results, & &1.id)
    assert ids == ["x/together.md"]
  end
end
