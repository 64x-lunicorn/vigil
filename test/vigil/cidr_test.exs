defmodule Vigil.CidrTest do
  @moduledoc """
  Addresses and the blocks they sit in, the one way both of vigil's readers of
  them ask: `Vigil.OAuth.ClientAddr`, which believes a forwarded header only
  from a trusted block, and `Vigil.OAuth.Cimd`, which fetches only from an
  address outside every special-purpose one.
  """
  use ExUnit.Case, async: true

  alias Vigil.Cidr

  describe "parse/1" do
    test "reads an IPv4 and an IPv6 block" do
      assert Cidr.parse("10.0.0.0/8") == {:ok, {{10, 0, 0, 0}, 8}}
      assert Cidr.parse("2001:db8::/32") == {:ok, {{0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 32}}
    end

    test "a bare address is its own single-host block" do
      assert Cidr.parse("198.51.100.9") == {:ok, {{198, 51, 100, 9}, 32}}
      assert Cidr.parse("::1") == {:ok, {{0, 0, 0, 0, 0, 0, 0, 1}, 128}}
    end

    test "an IPv6 address may be bracketed" do
      assert Cidr.parse("[::1]/128") == {:ok, {{0, 0, 0, 0, 0, 0, 0, 1}, 128}}
    end

    test "anything else is not a block" do
      for text <-
            ["", "not-a-cidr", "10.0.0.0/33", "10.0.0.0/-1", "10.0.0.0/", "10.0.0.0/8x"] ++
              ["2001:db8::/129", "1.2.3.4:80", "10.0.0.0/8/8"] do
        assert Cidr.parse(text) == :error, "#{inspect(text)} parsed"
      end
    end
  end

  describe "parse_address/1" do
    test "reads one address, bracketed or not, and nothing with a port" do
      assert Cidr.parse_address("192.0.2.5") == {:ok, {192, 0, 2, 5}}
      assert Cidr.parse_address("[2001:db8::1]") == {:ok, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}}
      assert Cidr.parse_address("192.0.2.5:443") == :error
      assert Cidr.parse_address("10.0.0.0/8") == :error
    end
  end

  describe "member?/2" do
    test "an address inside the block is a member, one outside is not" do
      {:ok, block} = Cidr.parse("10.0.0.0/8")

      assert Cidr.member?({10, 255, 0, 1}, block)
      refute Cidr.member?({11, 0, 0, 1}, block)
    end

    test "the prefix need not fall on a byte" do
      {:ok, block} = Cidr.parse("100.64.0.0/10")

      assert Cidr.member?({100, 127, 255, 255}, block)
      refute Cidr.member?({100, 128, 0, 0}, block)
    end

    test "an IPv6 block" do
      {:ok, block} = Cidr.parse("2000::/3")

      assert Cidr.member?({0x2A00, 0, 0, 0, 0, 0, 0, 1}, block)
      refute Cidr.member?({0x4000, 0, 0, 0, 0, 0, 0, 1}, block)
    end

    test "a zero prefix holds its whole family, and nothing of the other" do
      {:ok, v4} = Cidr.parse("0.0.0.0/0")
      {:ok, v6} = Cidr.parse("::/0")

      assert Cidr.member?({203, 0, 113, 7}, v4)
      refute Cidr.member?({0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x7107}, v4)
      assert Cidr.member?({0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}, v6)
      refute Cidr.member?({203, 0, 113, 7}, v6)
    end
  end

  describe "unmap_v4/1" do
    test "an IPv4-mapped IPv6 address is the IPv4 address it carries" do
      assert Cidr.unmap_v4({0, 0, 0, 0, 0, 0xFFFF, 0xC633, 0x6409}) == {198, 51, 100, 9}
    end

    test "every other address is itself" do
      for address <- [
            {198, 51, 100, 9},
            {0, 0, 0, 0, 0, 0, 0xC633, 0x6409},
            {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}
          ] do
        assert Cidr.unmap_v4(address) == address
      end
    end
  end
end
