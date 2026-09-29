defmodule Vigil.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:vigil, :autostart, true) do
        # Every setting, checked before anything starts: a bad one stops boot
        # here, named, rather than as a crash in whichever child reads it.
        checked = Vigil.Settings.Check.check!()

        # What the deployment says about itself, read once here and handed to
        # the two children that need it. Everything below takes it as an
        # option, so this is the only place it is resolved and the only place
        # an environment read for one of those settings belongs.
        settings = Vigil.Settings.from_env()

        [
          {Vigil.Store,
           vault_path: Application.fetch_env!(:vigil, :vault_path),
           exclude: Application.fetch_env!(:vigil, :exclude),
           git_remote: checked.git_remote,
           git_branch: checked.git_branch,
           settings: settings},
          Vigil.MCP.Envelope,
          Vigil.RateLimit,
          {Vigil.OAuth.Store, state_dir: Application.fetch_env!(:vigil, :state_dir)},
          Vigil.OAuth.Janitor,
          {Bandit,
           plug:
             {Vigil.MCP.Server,
              settings: settings,
              origins: Vigil.Origin.allowed(settings.issuer, checked.allowed_origins)},
           ip: checked.bind,
           port: checked.port}
        ]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Vigil.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
