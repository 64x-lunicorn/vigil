defmodule Vigil.SlugTest do
  use ExUnit.Case, async: true

  alias Vigil.Slug

  describe "slugify/1" do
    test "explicit transliteration table (input is deliberately non-ASCII)" do
      cases = %{
        "café" => "cafe",
        "Küche" => "kueche",
        "Rådhus" => "raadhus",
        "Øresund" => "oeresund",
        "Ærlig" => "aerlig",
        "Straße" => "strasse",
        "Hello   World!!" => "hello-world",
        "  Trim me  " => "trim-me"
      }

      for {input, expected} <- cases do
        assert Slug.slugify(input) == {:ok, expected}
      end
    end

    test "NFD and NFC input normalize to the same slug" do
      nfc = String.normalize("Küche", :nfc)
      nfd = String.normalize("Küche", :nfd)

      assert Slug.slugify(nfc) == Slug.slugify(nfd)
      assert Slug.slugify(nfd) == {:ok, "kueche"}
    end

    test "ü becomes ue, not u — transliteration runs before generic stripping" do
      assert Slug.slugify("ü") == {:ok, "ue"}
    end

    test "truncates at 80 characters on a hyphen boundary, no trailing hyphen" do
      long = String.duplicate("ab-", 40)
      assert {:ok, slug} = Slug.slugify(long)
      assert String.length(slug) <= 80
      refute String.ends_with?(slug, "-")
    end

    test "empty or underscore-only input is an error" do
      assert Slug.slugify("") == {:error, :empty}
      assert Slug.slugify("___") == {:error, :empty}
      assert Slug.slugify("   ") == {:error, :empty}
    end
  end

  describe "normalize_path/1" do
    test "slugifies every directory segment and the file basename, lowercases the extension" do
      assert Slug.normalize_path("Bike/Terra Speed.MD") == {:ok, "bike/terra-speed.md", true}
    end

    test "drops empty segments from doubled slashes" do
      assert Slug.normalize_path("projects//vigil/Pain Points.md") ==
               {:ok, "projects/vigil/pain-points.md", true}
    end

    test "an already-canonical path reports changed? = false" do
      assert Slug.normalize_path("bike/terra-speed.md") == {:ok, "bike/terra-speed.md", false}
    end

    test "a basename that slugifies to empty is an error" do
      assert Slug.normalize_path("bike/___.md") == {:error, :empty}
    end
  end

  describe "legacy_slugify/1 (migration comparison only)" do
    test "deletes untransliterated diacritics instead of transliterating them" do
      assert Slug.legacy_slugify("café") == "caf"
      assert Slug.slugify("café") == {:ok, "cafe"}
    end
  end
end
