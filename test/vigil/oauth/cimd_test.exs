defmodule Vigil.OAuth.CimdTest do
  @moduledoc """
  The CIMD fetch is the only place vigil makes an outbound request to an
  address an untrusted party chooses. Every test here drives it through a
  fake `net`, so the suite exercises the guard rather than the internet.
  """

  use ExUnit.Case, async: false

  alias Vigil.OAuth.Cimd

  @url "https://client.example.org/metadata.json"
  @public {93, 184, 216, 34}
  @now 1_700_000_000

  setup do
    Vigil.OAuthCase.setup!()
    :ok
  end

  ## Fake net

  # Records every call on the test process, so a test can assert on what the
  # fetch did *not* do as easily as on what it did. Each queue repeats its
  # last entry, so a test only lists the answers it actually cares about.
  defp net(opts) do
    responses = Keyword.get(opts, :responses, [{:ok, Keyword.get(opts, :body, document(%{}))}])
    addresses = Keyword.get(opts, :addresses, [{:ok, @public}])
    test = self()

    {:ok, response_queue} = Agent.start_link(fn -> responses end)
    {:ok, address_queue} = Agent.start_link(fn -> addresses end)

    %{
      request: fn url ->
        send(test, {:request, url})
        Agent.get_and_update(response_queue, &next/1)
      end,
      resolve: fn host, family ->
        send(test, {:resolve, List.to_string(host), family})
        Agent.get_and_update(address_queue, &next/1)
      end
    }
  end

  defp next([last]), do: {last, [last]}
  defp next([head | tail]), do: {head, tail}

  defp document(overrides) do
    %{
      "client_id" => @url,
      "client_name" => "Example",
      "redirect_uris" => ["https://client.example.org/cb"]
    }
    |> Map.merge(Map.new(overrides))
    |> Jason.encode!()
  end

  ## The happy path

  test "a valid document becomes a client, and the fetch resolves before it requests" do
    assert {:ok, doc} = Cimd.fetch(@url, @now, net([]))

    assert doc == %{
             client_id: @url,
             name: "Example",
             redirect_uris: ["https://client.example.org/cb"]
           }

    assert_received {:resolve, "client.example.org", :inet}
    assert_received {:request, @url}
  end

  test "a document without client_name is refused rather than defaulted to the URL" do
    # `fetch` reads client_name with a default, but validation requires it, so
    # the default is unreachable. Pinned here so removing either is visible.
    assert :error = Cimd.fetch(@url, @now, net(body: document(%{"client_name" => nil})))
  end

  ## The URL

  test "a non-https client_id is refused without resolving or requesting" do
    assert :error = Cimd.fetch("http://client.example.org/metadata.json", @now, net([]))
    refute_received {:resolve, _, _}
    refute_received {:request, _}
  end

  test "an https URL without a host is refused" do
    assert :error = Cimd.fetch("https:///metadata.json", @now, net([]))
    refute_received {:request, _}
  end

  ## The SSRF guard

  test "a host resolving to a private address is refused without requesting" do
    assert :error = Cimd.fetch(@url, @now, net(addresses: [{:ok, {127, 0, 0, 1}}]))
    assert_received {:resolve, "client.example.org", :inet}
    refute_received {:request, _}
  end

  test "a host with no A record is retried as AAAA" do
    net = net(addresses: [{:error, :nxdomain}, {:ok, {0x2606, 0x2800, 0, 0, 0, 0, 0, 1}}])
    assert {:ok, _doc} = Cimd.fetch(@url, @now, net)

    assert_received {:resolve, "client.example.org", :inet}
    assert_received {:resolve, "client.example.org", :inet6}
  end

  test "a host that resolves to the IPv6 loopback is refused" do
    net = net(addresses: [{:error, :nxdomain}, {:ok, {0, 0, 0, 0, 0, 0, 0, 1}}])
    assert :error = Cimd.fetch(@url, @now, net)
    refute_received {:request, _}
  end

  test "a host that resolves in neither family is refused" do
    net = net(addresses: [{:error, :nxdomain}])
    assert :error = Cimd.fetch(@url, @now, net)
    refute_received {:request, _}
  end

  ## The response

  test "a non-200 response is refused" do
    assert :error = Cimd.fetch(@url, @now, net(responses: [:error]))
    assert_received {:request, @url}
  end

  test "a body over the size cap is refused" do
    oversized = document(%{"client_name" => String.duplicate("a", 65_537)})
    assert :error = Cimd.fetch(@url, @now, net(body: oversized))
  end

  test "a body that is not JSON is refused" do
    assert :error = Cimd.fetch(@url, @now, net(body: "not json"))
  end

  ## Document validation

  test "a document whose client_id is not the URL it came from is refused" do
    net = net(body: document(%{"client_id" => "https://other.example.org/metadata.json"}))
    assert :error = Cimd.fetch(@url, @now, net)
  end

  test "a document without a client_id is refused" do
    body = ~s({"client_name": "Example", "redirect_uris": ["https://client.example.org/cb"]})
    assert :error = Cimd.fetch(@url, @now, net(body: body))
  end

  test "a document whose client_name is not a string is refused" do
    assert :error = Cimd.fetch(@url, @now, net(body: document(%{"client_name" => 42})))
  end

  test "a document whose redirect_uris is not a list is refused" do
    net = net(body: document(%{"redirect_uris" => "https://client.example.org/cb"}))
    assert :error = Cimd.fetch(@url, @now, net)
  end

  test "a document whose redirect_uris is empty is refused" do
    assert :error = Cimd.fetch(@url, @now, net(body: document(%{"redirect_uris" => []})))
  end

  test "a document with a redirect_uri that registration would refuse is refused" do
    net = net(body: document(%{"redirect_uris" => ["http://evil.example.org/cb"]}))
    assert :error = Cimd.fetch(@url, @now, net)
  end

  test "a loopback redirect_uri is accepted, as it is at registration" do
    net = net(body: document(%{"redirect_uris" => ["http://127.0.0.1/cb"]}))
    assert {:ok, %{redirect_uris: ["http://127.0.0.1/cb"]}} = Cimd.fetch(@url, @now, net)
  end

  ## The cache

  test "a second fetch inside the hour is answered from the cache without requesting" do
    assert {:ok, doc} = Cimd.fetch(@url, @now, net([]))
    assert_received {:resolve, _, _}
    assert_received {:request, @url}

    assert {:ok, ^doc} = Cimd.fetch(@url, @now + 3599, net([]))
    refute_received {:request, _}
    refute_received {:resolve, _, _}
  end

  test "a fetch after the hour has elapsed requests again" do
    assert {:ok, _doc} = Cimd.fetch(@url, @now, net([]))
    assert_received {:request, @url}

    assert {:ok, _doc} = Cimd.fetch(@url, @now + 3601, net([]))
    assert_received {:request, @url}
  end

  test "a refused document is not cached" do
    assert :error = Cimd.fetch(@url, @now, net(responses: [:error]))
    assert {:ok, _doc} = Cimd.fetch(@url, @now, net([]))
    assert_received {:request, @url}
    assert_received {:request, @url}
  end

  ## The production seam

  test "net/0 hands out the production implementations" do
    net = Cimd.net()
    assert is_function(net.request, 1)
    assert net.resolve == (&:inet.getaddr/2)
  end
end
