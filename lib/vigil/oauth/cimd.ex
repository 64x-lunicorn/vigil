defmodule Vigil.OAuth.Cimd do
  @moduledoc """
  Client ID Metadata Document fetching (draft-ietf-oauth-client-id-metadata-document).
  `client_id` is an https:// URL pointing at a JSON document describing the client.
  """
  alias Vigil.OAuth.{Store, RedirectUri}

  @timeout 5_000
  @max_bytes 65_536

  @doc """
  The two facts the fetch reaches for outside itself: the outbound request and
  the name resolution the SSRF guard decides on.

  They travel bundled, the way `Vigil.SkillKey`'s secret and window do, because
  neither is useful alone: a test that fakes the request but not the resolution
  still asks a real resolver about a host, and one that fakes the resolution but
  not the request still opens a socket. Only both together take this module off
  the network.
  """
  def net, do: %{request: &http_get/1, resolve: &:inet.getaddr/2}

  @doc "Fetches and validates a CIMD document, cached for 1h. Returns {:ok, client_meta} | :error."
  def fetch(url, now \\ System.system_time(:second), net \\ net()) do
    case Store.cimd_cache_get(url, now) do
      {:ok, doc} ->
        {:ok, doc}

      :error ->
        with :ok <- validate_url(url),
             :ok <- ssrf_guard(url, net.resolve),
             {:ok, body} <- net.request.(url),
             true <- byte_size(body) <= @max_bytes,
             {:ok, json} <- Jason.decode(body),
             :ok <- validate_document(json, url) do
          doc = %{
            client_id: url,
            name: Map.get(json, "client_name", url),
            redirect_uris: Map.get(json, "redirect_uris", [])
          }

          Store.cimd_cache_put(url, doc, now)
          {:ok, doc}
        else
          _ -> :error
        end
    end
  end

  defp validate_url(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> :ok
      _ -> :error
    end
  end

  defp ssrf_guard(url, resolve) do
    %URI{host: host} = URI.parse(url)

    case resolve.(String.to_charlist(host), :inet) do
      {:ok, ip} ->
        if private_ip?(ip), do: :error, else: :ok

      {:error, _} ->
        case resolve.(String.to_charlist(host), :inet6) do
          {:ok, ip} -> if private_ip?(ip), do: :error, else: :ok
          {:error, _} -> :error
        end
    end
  end

  defp private_ip?({127, _, _, _}), do: true
  defp private_ip?({10, _, _, _}), do: true
  defp private_ip?({172, b, _, _}) when b >= 16 and b <= 31, do: true
  defp private_ip?({192, 168, _, _}), do: true
  defp private_ip?({169, 254, _, _}), do: true
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFC00 and a <= 0xFDFF, do: true
  defp private_ip?(_), do: false

  defp http_get(url) do
    :inets.start()
    :ssl.start()

    request = {String.to_charlist(url), []}

    ssl_opts = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 4,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    http_opts = [timeout: @timeout, connect_timeout: @timeout, autoredirect: false, ssl: ssl_opts]

    case :httpc.request(:get, request, http_opts, body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, body}} -> {:ok, body}
      _ -> :error
    end
  end

  defp validate_document(%{"client_id" => doc_client_id} = json, url) do
    cond do
      doc_client_id != url -> :error
      not is_binary(Map.get(json, "client_name")) -> :error
      not is_list(Map.get(json, "redirect_uris")) -> :error
      Map.get(json, "redirect_uris") == [] -> :error
      not Enum.all?(json["redirect_uris"], &RedirectUri.valid_candidate?/1) -> :error
      true -> :ok
    end
  end

  defp validate_document(_json, _url), do: :error
end
