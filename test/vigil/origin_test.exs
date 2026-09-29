defmodule Vigil.OriginTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias Vigil.Origin

  @allowed Origin.allowed("https://vault.example.org", ["https://claude.ai"])

  defp from(origins),
    do: Enum.reduce(origins, conn(:post, "/mcp"), &prepend_req_headers(&2, [{"origin", &1}]))

  test "a request with no Origin is allowed" do
    assert Origin.allowed?(from([]), @allowed)
  end

  test "the issuer's origin is allowed, however it is spelled" do
    for origin <- [
          "https://vault.example.org",
          "https://Vault.Example.org",
          "https://vault.example.org:443"
        ] do
      assert Origin.allowed?(from([origin]), @allowed), origin
    end
  end

  test "a listed origin is allowed" do
    assert Origin.allowed?(from(["https://claude.ai"]), @allowed)
  end

  test "any other origin is refused" do
    for origin <- [
          "https://evil.example",
          "http://vault.example.org",
          "https://vault.example.org:8443",
          "https://vault.example.org.evil.example",
          "null",
          ""
        ] do
      refute Origin.allowed?(from([origin]), @allowed), origin
    end
  end

  test "two Origin headers are refused, even when one is allowed" do
    refute Origin.allowed?(from(["https://claude.ai", "https://evil.example"]), @allowed)
  end

  test "the issuer's path does not matter, only its origin" do
    allowed = Origin.allowed("http://localhost:4000/", [])
    assert Origin.allowed?(from(["http://localhost:4000"]), allowed)
    refute Origin.allowed?(from(["http://127.0.0.1:4000"]), allowed)
  end

  describe "of/1" do
    test "a URL's origin comes back serialized, whatever its path" do
      assert Origin.of("https://Vault.Example.org:443/mcp") == {:ok, "https://vault.example.org"}
      assert Origin.of("http://localhost:4000/mcp") == {:ok, "http://localhost:4000"}
    end

    test "a URL without an http scheme or a host has none" do
      assert Origin.of("vault.example.org") == :error
      assert Origin.of("ftp://vault.example.org") == :error
    end
  end

  describe "parse/1" do
    test "an origin comes back serialized" do
      assert Origin.parse("https://Claude.AI/") == {:ok, "https://claude.ai"}
      assert Origin.parse("http://localhost:4000") == {:ok, "http://localhost:4000"}
      assert Origin.parse("http://[::1]:4000") == {:ok, "http://[::1]:4000"}
    end

    test "anything that is more or less than an origin is refused" do
      for value <- [
            "claude.ai",
            "https://claude.ai/mcp",
            "https://claude.ai?x=1",
            "https://user@claude.ai",
            "ftp://claude.ai",
            "null",
            ""
          ] do
        assert Origin.parse(value) == :error, value
      end
    end
  end
end
