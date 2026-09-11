defmodule Vigil.OAuth.Persistence do
  @moduledoc """
  What the authorization server remembers, as a value its callers hold rather
  than a module they name (`docs/design.md`, "OAuth persistence is reached
  through a value").

  This is the **contract**: fourteen questions, which is the whole of what the
  OAuth modules ask of storage. A registered client written and read, an
  authorization code written and taken, a token written, read, deleted and
  revoked by family, the consent password attempts counted per address, the
  CIMD cache read and written — and the janitor's sweep, which is part of this
  surface rather than a concern of its own: it asks persistence to drop what
  has expired, and every expiry it drops belongs to one of the tables above.

  The **production adapter** is `Vigil.OAuth.Store.over_tables/0`, a function
  beside the `:dets`/`:ets` implementation it wires, rather than closures
  assembled by a caller — six modules ask these questions, and an adapter
  built at the call site would exist six times. The **second adapter** is
  `Vigil.OAuth.Persistence.Memory`, which the suite runs on;
  `test/vigil/oauth/persistence_test.exs` holds both to every claim below and
  is the only test that opens a `:dets` file.

  No field has a default, and the struct is built by `struct!/2` — the same
  shape and the same rule as `Vigil.Git` and `Vigil.Vault.Facts`: a question
  added here and left unwired fails at construction rather than answering.
  Answering is what it must not do: a `get_token` that answers `:error` turns
  every token into an unknown one, and a `rate_limited?` that answers `false`
  turns the consent lockout off — every plausible answer to a question nobody
  wired sits on the wrong side of a gate.
  """

  @enforce_keys [
    ## Clients
    # Write a registered client's record. :ok.
    :put_client,
    # {:ok, attrs} | :error.
    :get_client,

    ## Authorization codes
    # Write a minted code's record. :ok.
    :put_code,
    # Look one up and delete it in the same breath — a code is one-time use.
    # {:ok, attrs} | :error.
    :take_code,

    ## Tokens (access and refresh alike)
    # Write a token record, and rewrite one: rotation marks a refresh token
    # spent by putting it back. :ok.
    :put_token,
    # {:ok, attrs} | :error.
    :get_token,
    # :ok. Expiry deletes; rotation deliberately does not
    # (Vigil.OAuth.Token.spend_refresh/3).
    :delete_token,
    # Delete every token descended from one authorization grant — the replay
    # defence of RFC 9700 §4.14.2. A nil grant revokes nothing. :ok.
    :revoke_grant,

    ## Consent password attempts, per address
    # Whether this address is locked out at `now`. boolean.
    :rate_limited?,
    # Count one wrong password against it. :ok.
    :record_failure,
    # Forget an address's attempts — the right password did. :ok.
    :reset_rate_limit,

    ## The CIMD cache
    # {:ok, doc} | :error. Answers :error for an entry whose hour is up.
    :cimd_cache_get,
    # :ok.
    :cimd_cache_put,

    ## The janitor's sweep
    # Drop every record above whose expiry has passed at `now`. :ok.
    :sweep_expired
  ]

  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  # What the answers above are measured against: two numbers for the consent
  # lockout, one for the cache's hour. They live with the contract rather than
  # with either adapter because both have to agree on them — "the lockout
  # expires with its window" is a claim the suite runs against both, and a
  # window each adapter picked for itself would make that claim mean two
  # different things.
  #
  # The *rules* applied under them are deliberately not shared: each adapter
  # decides for itself what a window is made of and when it rolls over, which
  # is what leaves the contract suite something to catch.
  @rate_limit_window 900
  @rate_limit_max_attempts 5
  @cimd_ttl 3600

  @doc "How long an address's failed-password window lasts, in seconds."
  @spec rate_limit_window() :: pos_integer()
  def rate_limit_window, do: @rate_limit_window

  @doc "How many wrong passwords an address may spend inside one window."
  @spec rate_limit_max_attempts() :: pos_integer()
  def rate_limit_max_attempts, do: @rate_limit_max_attempts

  @doc "How long a cached CIMD document stays good for, in seconds."
  @spec cimd_ttl() :: pos_integer()
  def cimd_ttl, do: @cimd_ttl

  @doc """
  Builds a persistence adapter from an answer to every one of the fourteen
  questions.

  Raises `ArgumentError` when a field is missing or unknown, which is the
  point: an unwired question must fail where the adapter is built, not answer
  something plausible at the moment a token is verified against it.
  """
  @spec new(Enumerable.t()) :: t
  def new(fields), do: struct!(__MODULE__, fields)
end
