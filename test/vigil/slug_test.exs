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

  describe "safe_path/1" do
    test "accepts any vault-relative path, whatever the write rules say about it" do
      assert Slug.safe_path("bike/x.md") == :ok
      assert Slug.safe_path("work/secret.md") == :ok
      assert Slug.safe_path("skills/tdd.md") == :ok
    end

    test "rejects traversal, absolute paths, backslashes and null bytes" do
      assert Slug.safe_path("../../etc/passwd") == {:error, "Invalid path"}
      assert Slug.safe_path("bike/../../etc/passwd") == {:error, "Invalid path"}
      assert Slug.safe_path("/etc/passwd") == {:error, "Invalid path"}
      assert Slug.safe_path("bike\\x.md") == {:error, "Invalid path"}
      assert Slug.safe_path("bike/x" <> <<0>> <> ".md") == {:error, "Invalid path"}
    end

    test "rejects a hidden or reserved segment anywhere in the path" do
      assert Slug.safe_path(".hidden/x.md") == {:error, "Invalid path"}
      assert Slug.safe_path("bike/.git/x.md") == {:error, "Invalid path"}
      assert Slug.safe_path("_domains.yml") == {:error, "Invalid path"}
      assert Slug.safe_path("bike/_draft.md") == {:error, "Invalid path"}
    end

    test "reserved_segment?/1 is the same rule for a single segment" do
      assert Slug.reserved_segment?(".git")
      assert Slug.reserved_segment?("_domains.yml")
      refute Slug.reserved_segment?("bike")
    end
  end

  describe "canonical/1 and canonical_path/1" do
    test "safety is checked before normalization" do
      # Normalization slugifies every segment, so `_domains.yml` becomes
      # `domains.yml` and `/abs/x.md` becomes `abs/x.md`. A path checked only
      # after that is a path whose check the normalization has laundered.
      assert Slug.canonical_path("_domains.yml") == {:error, "Invalid path"}
      assert Slug.canonical_path("/etc/passwd") == {:error, "Invalid path"}
      assert Slug.canonical_path("bike/../../etc/passwd") == {:error, "Invalid path"}

      assert Slug.canonical("_domains.yml") == {:error, "Invalid path"}
    end

    # And after it, which is the half no caller has to remember. Nothing
    # `normalize_path/1` produces today can fail it — every segment it emits
    # starts with a letter or a digit — and that is the reason the check
    # belongs to the resolution rather than to each caller: what keeps it true
    # is one function away from the rule, not eight.
    test "a safe path is canonicalised to what the vault would store it under" do
      assert Slug.canonical_path("Bike/Terra Speed.MD") == {:ok, "bike/terra-speed.md"}
      assert Slug.canonical_path("bike/terra-speed.md") == {:ok, "bike/terra-speed.md"}
    end

    test "canonical/1 says whether normalization changed the path" do
      assert Slug.canonical("Bike/Terra Speed.MD") == {:ok, "bike/terra-speed.md", true}
      assert Slug.canonical("bike/terra-speed.md") == {:ok, "bike/terra-speed.md", false}
    end

    # The two callers differ on this one answer, which is why there are two
    # functions: a read answers it the way it answers a miss, and the write
    # gate has a sentence to say about it.
    test "a path no filename can be derived from" do
      assert Slug.canonical_path("bike/---.md") == {:ok, "bike/---.md"}
      assert Slug.canonical("bike/---.md") == {:error, :empty}
    end
  end

  describe "legacy_slugify/1 (migration comparison only)" do
    test "deletes untransliterated diacritics instead of transliterating them" do
      assert Slug.legacy_slugify("café") == "caf"
      assert Slug.slugify("café") == {:ok, "cafe"}
    end
  end
end
