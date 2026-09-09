defmodule Vigil.Vault.Domains do
  @moduledoc """
  `_domains.yml`, as a value.

  The file describes the vault's domains for the assistant and optionally
  carries per-domain naming rules (`docs/design.md`, "`_domains.yml` is a
  description, not configuration"). Its *text* is handed to the MCP client
  verbatim and is never parsed for that purpose — `naming` is the only key
  this server interprets. Everything else in the file is documentation for
  whoever reads it.

  Pure: takes the file's text, returns a value and a list of warnings. It
  reads nothing, logs nothing, and cannot fail. A broken `_domains.yml`
  degrades the vault — a domain loses its naming rule — but never blocks a
  write, so there is no error case for a caller to handle.
  """

  defmodule Naming do
    @moduledoc """
    One domain's naming rule, as parsed from `_domains.yml`.

    Every field is consumed by `Vigil.Vault.Policy`; the struct exists so
    that contract is stated somewhere rather than inferred from a bare map.
    """

    defstruct [:pattern, :scope, :hint, :suggestion, :max_depth]

    @type t :: %__MODULE__{
            pattern: Regex.t(),
            scope: :filename | :relpath,
            hint: String.t(),
            suggestion: :date | :slug,
            max_depth: pos_integer() | nil
          }
  end

  @typedoc "A domain that carries no naming rule maps to nil; the key still counts as declared."
  @type t :: %{optional(String.t()) => Naming.t() | nil}

  @type warning ::
          {:unparsable, term()}
          | {:invalid_pattern, String.t(), term()}
          | {:key_without_directory, String.t()}
          | {:directory_without_key, String.t()}

  @doc """
  Parses the contents of `_domains.yml`.

  Returns every declared domain — mapped to its `Naming.t()` or to nil — and
  the warnings collected on the way. Total by construction: anything the
  file gets wrong costs at most one entry's naming rule.
  """
  @spec parse(binary()) :: {t(), [warning()]}
  def parse(yaml_text) when is_binary(yaml_text) do
    case YamlElixir.read_from_string(yaml_text) do
      {:ok, map} when is_map(map) ->
        map
        |> Enum.sort_by(fn {domain, _value} -> domain end)
        |> Enum.reduce({%{}, []}, fn {domain, value}, {domains, warnings} ->
          {naming, entry_warnings} = parse_entry(domain, value)
          {Map.put(domains, domain, naming), warnings ++ entry_warnings}
        end)

      # An empty file parses to nil, which is not a mapping of domains but is
      # also not a mistake worth warning about — it is a vault that has not
      # described itself yet.
      {:ok, nil} ->
        {%{}, []}

      {:ok, other} ->
        {%{}, [{:unparsable, {:not_a_mapping, other}}]}

      {:error, reason} ->
        {%{}, [{:unparsable, reason}]}
    end
  end

  @doc """
  Warns about drift between the file and the vault, in both directions.

  A key without a directory is ignored; a directory without a key is still a
  domain. The file is a description, not a whitelist — neither case changes
  behaviour, both are worth saying out loud.
  """
  @spec mismatches(t(), [String.t()]) :: [warning()]
  def mismatches(domains, domain_dirs) do
    keys = domains |> Map.keys() |> Enum.sort()

    for(key <- keys, key not in domain_dirs, do: {:key_without_directory, key}) ++
      for(dir <- domain_dirs, not Map.has_key?(domains, dir), do: {:directory_without_key, dir})
  end

  @doc "The naming rules alone, in the shape `Vigil.Vault.Facts` expects."
  @spec naming_rules(t()) :: %{optional(String.t()) => Naming.t()}
  def naming_rules(domains) do
    for {domain, %Naming{} = naming} <- domains, into: %{}, do: {domain, naming}
  end

  @doc "Renders a warning for the log. The caller decides whether to log it."
  @spec format(warning()) :: String.t()
  def format({:unparsable, reason}),
    do: "_domains.yml is not parsable: #{inspect(reason)}"

  def format({:invalid_pattern, domain, reason}),
    do:
      "_domains.yml: naming.pattern for '#{domain}' is not a valid regex " <>
        "(#{inspect(reason)}), ignoring it"

  def format({:key_without_directory, key}),
    do: "_domains.yml: key '#{key}' has no matching directory"

  def format({:directory_without_key, dir}),
    do: "domain '#{dir}' has no entry in _domains.yml"

  # A domain entry is either a plain description string (the common case) or
  # a map. Only `naming` is read out of either; the descriptive text reaches
  # the assistant through the file itself.
  defp parse_entry(domain, value) when is_map(value),
    do: parse_naming(domain, Map.get(value, "naming"))

  defp parse_entry(_domain, _value), do: {nil, []}

  defp parse_naming(domain, naming) when is_map(naming) do
    case compile_pattern(domain, Map.get(naming, "pattern")) do
      {:ok, nil} ->
        {nil, []}

      {:ok, pattern} ->
        {%Naming{
           pattern: pattern,
           scope: parse_scope(Map.get(naming, "scope")),
           hint: Map.get(naming, "hint", Map.get(naming, "hinweis", "")),
           suggestion:
             parse_suggestion(Map.get(naming, "suggestion", Map.get(naming, "vorschlag"))),
           max_depth: Map.get(naming, "max_depth")
         }, []}

      {:error, warning} ->
        {nil, [warning]}
    end
  end

  defp parse_naming(_domain, _naming), do: {nil, []}

  # A naming block without a pattern constrains nothing, so it is not a rule.
  defp compile_pattern(_domain, nil), do: {:ok, nil}

  defp compile_pattern(domain, raw) when is_binary(raw) do
    case Regex.compile(raw, "u") do
      {:ok, regex} -> {:ok, regex}
      {:error, reason} -> {:error, {:invalid_pattern, domain, reason}}
    end
  end

  defp compile_pattern(domain, raw),
    do: {:error, {:invalid_pattern, domain, {:not_a_string, raw}}}

  defp parse_scope("relpath"), do: :relpath
  defp parse_scope(_), do: :filename

  defp parse_suggestion("date"), do: :date
  defp parse_suggestion(_), do: :slug
end
