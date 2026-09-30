defmodule Vigil.ApplicationTest do
  @moduledoc """
  The deployment is resolved once (`docs/design.md`, "The deployment is
  resolved once"): the supervision tree is built from what
  `Vigil.Settings.Check` checked, and from nothing read a second time.

  Every value below differs from what `config/runtime.exs` pins for the
  suite, so a child option read from the application environment instead of
  from the checked values would show here.
  """
  use ExUnit.Case, async: true

  alias Vigil.Git.CommitLog
  alias Vigil.OAuth.Endpoint
  alias Vigil.Settings
  alias Vigil.Settings.Check

  @vault "/srv/elsewhere/vault"

  @config [
    vault_path: @vault,
    git_remote: "origin",
    git_branch: "notes",
    state_dir: "/srv/elsewhere/state",
    port: 4711,
    bind: "127.0.0.2",
    tz: "Pacific/Auckland",
    issuer: "https://notes.example.net",
    resource: "https://notes.example.net/mcp",
    auth_password: "a-different-consent-password",
    consent_failures_per_hour: 7,
    allowed_origins: ["https://claude.ai"],
    skillkey_secret: "itTnVnZk/sC37IrApqZhoUWOfli819Xl7zZx6DSYKPrXRrOsez+p930plUaYNzV6",
    skillkey_ttl_seconds: 120,
    rate_limit_rpm: 11,
    reload_rate_limit_rpm: 2,
    oauth_rate_limit_rpm: 13,
    oauth_register_rate_limit_rpm: 3,
    read_fetch_interval: 0,
    trusted_proxy_header: "CF-Connecting-IP",
    trusted_proxies: ["127.0.0.1/32"],
    exclude: ["private"],
    vault_owner: "Ada",
    vault_language: "Deutsch",
    https_required: true
  ]

  setup do
    clone = CommitLog.new(@vault, remote: "origin", branch: "notes")
    {:ok, checked} = Check.check(@config, clone)
    %{checked: checked, children: Vigil.Application.children(checked)}
  end

  defp opts_of(children, module) do
    Enum.find_value(children, fn
      {^module, opts} -> opts
      _ -> nil
    end)
  end

  test "the vault's writer is given the checked vault, boundary and remote", %{
    children: children,
    checked: checked
  } do
    opts = opts_of(children, Vigil.Store)

    assert opts[:vault_path] == @vault
    assert opts[:exclude] == ["private"]
    assert opts[:git_remote] == "origin"
    assert opts[:git_branch] == "notes"
    assert opts[:read_fetch_interval] == 0
    assert opts[:settings] == Settings.from_checked(checked)
  end

  test "the OAuth state lives in the checked state dir", %{children: children} do
    assert opts_of(children, Vigil.OAuth.Store) == [state_dir: "/srv/elsewhere/state"]
  end

  test "the router is given every budget, the proxies and the settings as checked", %{
    children: children,
    checked: checked
  } do
    bandit = opts_of(children, Bandit)
    {Vigil.MCP.Server, server} = bandit[:plug]

    assert bandit[:ip] == {127, 0, 0, 2}
    assert bandit[:port] == 4711
    assert server[:settings] == Settings.from_checked(checked)
    assert server[:rate_limit_budget] == 11
    assert server[:reload_rate_limit_budget] == 2
    assert server[:limits] == Endpoint.limits(13, 3)
    assert server[:client_addr] == [header: "cf-connecting-ip", trusted: [{{127, 0, 0, 1}, 32}]]
    assert MapSet.member?(server[:origins], "https://claude.ai")
    assert MapSet.member?(server[:origins], "https://notes.example.net")
  end

  test "the settings value is the checked one, field by field", %{checked: checked} do
    assert %Settings{
             tz: "Pacific/Auckland",
             issuer: "https://notes.example.net",
             resource: "https://notes.example.net/mcp",
             auth_password: "a-different-consent-password",
             consent_failures_per_hour: 7,
             skillkey_ttl_seconds: 120,
             vault_owner: "Ada",
             vault_language: "Deutsch"
           } = Settings.from_checked(checked)
  end

  # What the router hands the authorization server it forwards to: the
  # proxies and the budgets it was given, not the environment's.
  test "the authorization server is initialized with the router's proxies and budgets", %{
    children: children
  } do
    {Vigil.MCP.Server, server} = opts_of(children, Bandit)[:plug]
    oauth = Vigil.MCP.Server.init(server)[:oauth]

    assert oauth[:client_addr] == [header: "cf-connecting-ip", trusted: [{{127, 0, 0, 1}, 32}]]
    assert oauth[:limits] == Endpoint.limits(13, 3)
  end
end
