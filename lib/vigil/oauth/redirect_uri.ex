defmodule Vigil.OAuth.RedirectUri do
  @moduledoc false

  @doc "Registration-time validity: https://, or http:// with host localhost/127.0.0.1."
  def valid_candidate?(uri_string) when is_binary(uri_string) do
    case URI.parse(uri_string) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> true
      %URI{scheme: "http", host: host} when host in ["localhost", "127.0.0.1"] -> true
      _ -> false
    end
  end

  # A registration or a CIMD document can say anything in `redirect_uris`;
  # what is not a string is not a candidate, rather than a crash.
  def valid_candidate?(_not_a_string), do: false

  @doc """
  Authorize-time match against the registered list (section 6):
  exact string match for https, port-agnostic scheme+host+path match for
  http+localhost/127.0.0.1.
  """
  def matches?(registered_uris, requested_uri) do
    Enum.any?(registered_uris, &uri_equal?(&1, requested_uri))
  end

  defp uri_equal?(registered, requested) do
    registered == requested or
      (loopback?(registered) and loopback?(requested) and
         same_ignoring_port?(registered, requested))
  end

  defp loopback?(uri_string) do
    case URI.parse(uri_string) do
      %URI{scheme: "http", host: host} -> host in ["localhost", "127.0.0.1"]
      _ -> false
    end
  end

  defp same_ignoring_port?(a, b) do
    ua = URI.parse(a)
    ub = URI.parse(b)

    ua.scheme == ub.scheme and ua.host == ub.host and
      normalize_path(ua.path) == normalize_path(ub.path)
  end

  defp normalize_path(nil), do: "/"
  defp normalize_path(""), do: "/"
  defp normalize_path(path), do: path
end
