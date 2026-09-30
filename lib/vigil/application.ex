defmodule Vigil.Application do
  @moduledoc false
  use Application

  alias Vigil.OAuth.Endpoint

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:vigil, :autostart, true) do
        # Every setting, checked before anything starts: a bad one stops boot
        # here, named, rather than as a crash in whichever child reads it.
        children(Vigil.Settings.Check.check!())
      else
        []
      end

    opts = [strategy: :one_for_one, name: Vigil.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc false
  # The tree, built from the checked settings and nothing else: this is the
  # only place the deployment is resolved, and every child takes what it
  # needs of it as an option. Nothing here reads the application environment
  # a second time, so what was checked is what runs.
  def children(checked) do
    settings = Vigil.Settings.from_checked(checked)

    [
      {Vigil.Store,
       vault_path: checked.vault_path,
       exclude: checked.exclude,
       git_remote: checked.git_remote,
       git_branch: checked.git_branch,
       read_fetch_interval: checked.read_fetch_interval,
       settings: settings},
      Vigil.MCP.Envelope,
      Vigil.RateLimit,
      {Vigil.OAuth.Store, state_dir: checked.state_dir},
      Vigil.OAuth.Janitor,
      {Bandit,
       plug:
         {Vigil.MCP.Server,
          settings: settings,
          origins: Vigil.Origin.allowed(settings.issuer, checked.allowed_origins),
          rate_limit_budget: checked.rate_limit_rpm,
          reload_rate_limit_budget: checked.reload_rate_limit_rpm,
          client_addr: [header: checked.trusted_proxy_header, trusted: checked.trusted_proxies],
          limits:
            Endpoint.limits(checked.oauth_rate_limit_rpm, checked.oauth_register_rate_limit_rpm)},
       ip: checked.bind,
       port: checked.port}
    ]
  end
end
