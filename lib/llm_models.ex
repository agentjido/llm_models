defmodule LlmModels do
  @moduledoc """
  Fast, persistent_term-backed LLM model metadata catalog with explicit refresh controls.

  Provides a simple, capability-aware API for querying LLM model metadata.
  All queries are backed by `:persistent_term` for O(1), lock-free access.

  ## Lifecycle

  - `load/1` - Build catalog from sources and publish to persistent_term
  - `reload/0` - Re-run load with last-known options
  - `snapshot/0` - Get current snapshot
  - `epoch/0` - Get current epoch (monotonic version)

  ## Lookup and Listing

  - `list_providers/0` - List all provider atoms
  - `get_provider/1` - Get provider metadata
  - `list_models/2` - List models for a provider with optional filters
  - `get_model/2` - Get a specific model
  - `capabilities/1` - Get capabilities for a model spec
  - `allowed?/1` - Check if a model passes allow/deny filters

  ## Selection

  - `select/1` - Select a model matching capability requirements

  ## Spec Parsing

  - `parse_provider/1` - Parse and validate a provider identifier
  - `parse_spec/1` - Parse "provider:model" specification
  - `resolve/2` - Resolve a spec to a model record

  ## Examples

      # Boot the catalog
      {:ok, _} = LlmModels.load()

      # List providers
      [:openai, :anthropic, :google_vertex] = LlmModels.list_providers()

      # List models with capability filters
      models = LlmModels.list_models(:openai,
        require: [tools: true],
        forbid: [streaming_tool_calls: true]
      )

      # Get a specific model
      {:ok, model} = LlmModels.get_model(:openai, "gpt-4o-mini")

      # Select a model matching requirements
      {:ok, {:openai, "gpt-4o-mini"}} = LlmModels.select(
        require: [chat: true, tools: true, json_native: true],
        prefer: [:openai, :anthropic]
      )

      # Parse and resolve specs
      {:ok, {:openai, "gpt-4o-mini"}} = LlmModels.parse_spec("openai:gpt-4o-mini")
      {:ok, {provider, id, model}} = LlmModels.resolve("openai:gpt-4o-mini")
  """

  alias LlmModels.{Engine, Store, Spec}

  @type provider :: atom()
  @type model_id :: String.t()
  @type model_spec :: {provider(), model_id()} | String.t()

  # Lifecycle functions

  @doc """
  Loads the model catalog from all sources and publishes to persistent_term.

  Runs the ETL pipeline to ingest, normalize, validate, merge, enrich, filter,
  and index model metadata from packaged snapshot, config overrides, and
  behaviour overrides.

  ## Options

  - `:config` - Config map override (optional)

  ## Returns

  - `{:ok, snapshot}` - Success with the generated snapshot
  - `{:error, term}` - Error from engine or validation

  ## Examples

      {:ok, snapshot} = LlmModels.load()
      {:ok, snapshot} = LlmModels.load(config: custom_config)
  """
  @spec load(keyword()) :: {:ok, map()} | {:error, term()}
  def load(opts \\ []) do
    with {:ok, snapshot} <- Engine.run(opts) do
      Store.put!(snapshot, opts)
      {:ok, snapshot}
    end
  end

  @doc """
  Reloads the catalog using the last-known options.

  Retrieves the options from the last successful `load/1` call and
  re-runs the ETL pipeline with those options.

  ## Returns

  - `:ok` - Success
  - `{:error, term}` - Error from engine or validation

  ## Examples

      :ok = LlmModels.reload()
  """
  @spec reload() :: :ok | {:error, term()}
  def reload do
    last_opts = Store.last_opts()

    case load(last_opts) do
      {:ok, _snapshot} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the current snapshot from persistent_term.

  ## Returns

  The snapshot map or `nil` if not loaded.

  ## Examples

      snapshot = LlmModels.snapshot()
  """
  @spec snapshot() :: map() | nil
  def snapshot do
    Store.snapshot()
  end

  @doc """
  Returns the current epoch from persistent_term.

  The epoch is a monotonic integer that increments with each successful load.

  ## Returns

  Non-negative integer representing the current epoch, or `0` if not loaded.

  ## Examples

      epoch = LlmModels.epoch()
  """
  @spec epoch() :: non_neg_integer()
  def epoch do
    Store.epoch()
  end

  # Lookup and listing functions

  @doc """
  Lists all provider atoms in the catalog.

  ## Returns

  List of provider atoms, sorted alphabetically.

  ## Examples

      [:anthropic, :openai, :google_vertex] = LlmModels.list_providers()
  """
  @spec list_providers() :: [provider()]
  def list_providers do
    case snapshot() do
      nil -> []
      %{providers_by_id: providers} -> providers |> Map.keys() |> Enum.sort()
      _ -> []
    end
  end

  @doc """
  Gets provider metadata by provider atom.

  ## Parameters

  - `provider` - Provider atom (e.g., `:openai`, `:anthropic`)

  ## Returns

  - `{:ok, provider_map}` - Provider metadata
  - `:error` - Provider not found

  ## Examples

      {:ok, provider} = LlmModels.get_provider(:openai)
      provider.name
      #=> "OpenAI"
  """
  @spec get_provider(provider()) :: {:ok, map()} | :error
  def get_provider(provider) when is_atom(provider) do
    case snapshot() do
      nil -> :error
      %{providers_by_id: providers} -> Map.fetch(providers, provider)
      _ -> :error
    end
  end

  @doc """
  Lists models for a provider with optional capability filters.

  ## Parameters

  - `provider` - Provider atom
  - `opts` - Keyword list of options:
    - `:require` - Keyword list of required capabilities (e.g., `[tools: true]`)
    - `:forbid` - Keyword list of forbidden capabilities (e.g., `[streaming_tool_calls: true]`)

  ## Returns

  List of model maps matching the filters.

  ## Examples

      # All models for a provider
      models = LlmModels.list_models(:openai)

      # Models with specific capabilities
      models = LlmModels.list_models(:openai,
        require: [tools: true, json_native: true],
        forbid: [streaming_tool_calls: true]
      )
  """
  @spec list_models(provider(), keyword()) :: [map()]
  def list_models(provider, opts \\ []) when is_atom(provider) do
    require_kw = Keyword.get(opts, :require, [])
    forbid_kw = Keyword.get(opts, :forbid, [])

    case snapshot() do
      nil ->
        []

      %{models: models_by_provider} ->
        models = Map.get(models_by_provider, provider, [])

        models
        |> Enum.filter(&matches_require?(&1, require_kw))
        |> Enum.reject(&matches_forbid?(&1, forbid_kw))

      _ ->
        []
    end
  end

  @doc """
  Gets a specific model by provider and model ID.

  Handles alias resolution automatically.

  ## Parameters

  - `provider` - Provider atom
  - `model_id` - Model identifier string

  ## Returns

  - `{:ok, model}` - Model metadata
  - `:error` - Model not found

  ## Examples

      {:ok, model} = LlmModels.get_model(:openai, "gpt-4o-mini")
      {:ok, model} = LlmModels.get_model(:openai, "gpt-4-mini")  # alias
  """
  @spec get_model(provider(), model_id()) :: {:ok, map()} | :error
  def get_model(provider, model_id) when is_atom(provider) and is_binary(model_id) do
    case snapshot() do
      nil ->
        :error

      snapshot when is_map(snapshot) ->
        key = {provider, model_id}

        canonical_id = Map.get(snapshot.aliases_by_key, key, model_id)
        canonical_key = {provider, canonical_id}

        Map.fetch(snapshot.models_by_key, canonical_key)
    end
  end

  @doc """
  Gets capabilities for a model specification.

  ## Parameters

  - `spec` - Either `{provider, model_id}` tuple or `"provider:model"` string

  ## Returns

  Capabilities map or `nil` if not found.

  ## Examples

      caps = LlmModels.capabilities({:openai, "gpt-4o-mini"})
      caps.tools.enabled
      #=> true

      caps = LlmModels.capabilities("openai:gpt-4o-mini")
      caps.json.native
      #=> true
  """
  @spec capabilities(model_spec()) :: map() | nil
  def capabilities(spec)

  def capabilities({provider, model_id}) when is_atom(provider) and is_binary(model_id) do
    case get_model(provider, model_id) do
      {:ok, model} -> Map.get(model, :capabilities)
      :error -> nil
    end
  end

  def capabilities(spec) when is_binary(spec) do
    case Spec.parse_spec(spec) do
      {:ok, {provider, model_id}} -> capabilities({provider, model_id})
      _ -> nil
    end
  end

  @doc """
  Checks if a model specification passes allow/deny filters.

  Deny patterns always win over allow patterns.

  ## Parameters

  - `spec` - Either `{provider, model_id}` tuple or `"provider:model"` string

  ## Returns

  Boolean indicating if the model is allowed.

  ## Examples

      true = LlmModels.allowed?({:openai, "gpt-4o-mini"})
      false = LlmModels.allowed?({:openai, "gpt-5-pro"})  # if denied
  """
  @spec allowed?(model_spec()) :: boolean()
  def allowed?(spec)

  def allowed?({provider, model_id}) when is_atom(provider) and is_binary(model_id) do
    case snapshot() do
      nil ->
        false

      %{filters: %{allow: allow, deny: deny}} ->
        deny_patterns = Map.get(deny, provider, [])
        denied? = matches_patterns?(model_id, deny_patterns)

        if denied? do
          false
        else
          case allow do
            :all ->
              true

            allow_map when is_map(allow_map) ->
              allow_patterns = Map.get(allow_map, provider, [])

              if map_size(allow_map) > 0 and allow_patterns == [] do
                false
              else
                allow_patterns == [] or matches_patterns?(model_id, allow_patterns)
              end
          end
        end

      _ ->
        false
    end
  end

  def allowed?(spec) when is_binary(spec) do
    case Spec.parse_spec(spec) do
      {:ok, {provider, model_id}} -> allowed?({provider, model_id})
      _ -> false
    end
  end

  # Selection

  @doc """
  Selects the first allowed model matching capability requirements.

  Iterates through providers in preference order (or all providers) and
  returns the first model matching the capability filters.

  ## Options

  - `:require` - Keyword list of required capabilities (e.g., `[tools: true, json_native: true]`)
  - `:forbid` - Keyword list of forbidden capabilities
  - `:prefer` - List of provider atoms in preference order (e.g., `[:openai, :anthropic]`)
  - `:scope` - Either `:all` (default) or a specific provider atom

  ## Returns

  - `{:ok, {provider, model_id}}` - First matching model
  - `{:error, :no_match}` - No model matches the criteria

  ## Examples

      {:ok, {provider, model_id}} = LlmModels.select(
        require: [chat: true, tools: true],
        prefer: [:openai, :anthropic]
      )

      {:ok, {provider, model_id}} = LlmModels.select(
        require: [json_native: true],
        forbid: [streaming_tool_calls: true],
        scope: :openai
      )
  """
  @spec select(keyword()) :: {:ok, {provider(), model_id()}} | {:error, :no_match}
  def select(opts \\ []) do
    require_kw = Keyword.get(opts, :require, [])
    forbid_kw = Keyword.get(opts, :forbid, [])
    prefer = Keyword.get(opts, :prefer, [])
    scope = Keyword.get(opts, :scope, :all)

    providers =
      case scope do
        :all ->
          if prefer != [] do
            all_providers = list_providers()
            prefer ++ (all_providers -- prefer)
          else
            list_providers()
          end

        provider when is_atom(provider) ->
          [provider]
      end

    find_first_match(providers, require_kw, forbid_kw)
  end

  # Spec parsing (delegated to Spec module)

  @doc """
  Parses and validates a provider identifier.

  Delegates to `LlmModels.Spec.parse_provider/1`.

  ## Parameters

  - `input` - Provider identifier as atom or binary

  ## Returns

  - `{:ok, atom}` - Normalized provider atom
  - `{:error, :unknown_provider}` - Provider not found
  - `{:error, :bad_provider}` - Invalid format

  ## Examples

      {:ok, :openai} = LlmModels.parse_provider(:openai)
      {:ok, :google_vertex} = LlmModels.parse_provider("google-vertex")
  """
  @spec parse_provider(atom() | binary()) ::
          {:ok, provider()} | {:error, :unknown_provider | :bad_provider}
  defdelegate parse_provider(input), to: Spec

  @doc """
  Parses a "provider:model" specification string.

  Delegates to `LlmModels.Spec.parse_spec/1`.

  ## Parameters

  - `spec` - String in "provider:model" format

  ## Returns

  - `{:ok, {provider, model_id}}` - Parsed spec
  - `{:error, :invalid_format}` - No ":" found
  - `{:error, :unknown_provider}` - Provider not found

  ## Examples

      {:ok, {:openai, "gpt-4"}} = LlmModels.parse_spec("openai:gpt-4")
  """
  @spec parse_spec(String.t()) ::
          {:ok, {provider(), model_id()}}
          | {:error, :invalid_format | :unknown_provider | :bad_provider}
  defdelegate parse_spec(spec), to: Spec

  @doc """
  Resolves a model specification to a canonical model record.

  Delegates to `LlmModels.Spec.resolve/2`.

  Accepts:
  - "provider:model" string
  - {provider, model_id} tuple
  - Bare "model" string with opts[:scope] = provider_atom

  ## Parameters

  - `input` - Model specification
  - `opts` - Keyword list with optional `:scope`

  ## Returns

  - `{:ok, {provider, canonical_id, model}}` - Resolved model
  - `{:error, :not_found}` - Model not found
  - `{:error, :ambiguous}` - Bare model ID matches multiple providers
  - `{:error, term}` - Other errors

  ## Examples

      {:ok, {provider, id, model}} = LlmModels.resolve("openai:gpt-4")
      {:ok, {provider, id, model}} = LlmModels.resolve({:openai, "gpt-4"})
      {:ok, {provider, id, model}} = LlmModels.resolve("gpt-4", scope: :openai)
  """
  @spec resolve(model_spec(), keyword()) ::
          {:ok, {provider(), model_id(), map()}} | {:error, term()}
  defdelegate resolve(input, opts \\ []), to: Spec

  # Private helpers

  defp matches_require?(_model, []), do: true

  defp matches_require?(model, require_kw) do
    caps = Map.get(model, :capabilities, %{})

    Enum.all?(require_kw, fn {key, value} ->
      check_capability(caps, key, value)
    end)
  end

  defp matches_forbid?(_model, []), do: false

  defp matches_forbid?(model, forbid_kw) do
    caps = Map.get(model, :capabilities, %{})

    Enum.any?(forbid_kw, fn {key, value} ->
      check_capability(caps, key, value)
    end)
  end

  defp check_capability(caps, key, expected_value) do
    case key do
      :chat -> Map.get(caps, :chat) == expected_value
      :embeddings -> Map.get(caps, :embeddings) == expected_value
      :reasoning -> get_in(caps, [:reasoning, :enabled]) == expected_value
      :tools -> get_in(caps, [:tools, :enabled]) == expected_value
      :tools_streaming -> get_in(caps, [:tools, :streaming]) == expected_value
      :tools_strict -> get_in(caps, [:tools, :strict]) == expected_value
      :tools_parallel -> get_in(caps, [:tools, :parallel]) == expected_value
      :json_native -> get_in(caps, [:json, :native]) == expected_value
      :json_schema -> get_in(caps, [:json, :schema]) == expected_value
      :json_strict -> get_in(caps, [:json, :strict]) == expected_value
      :streaming_text -> get_in(caps, [:streaming, :text]) == expected_value
      :streaming_tool_calls -> get_in(caps, [:streaming, :tool_calls]) == expected_value
      _ -> false
    end
  end

  defp matches_patterns?(_model_id, []), do: false

  defp matches_patterns?(model_id, patterns) when is_binary(model_id) do
    Enum.any?(patterns, fn
      %Regex{} = pattern -> Regex.match?(pattern, model_id)
      pattern when is_binary(pattern) -> model_id == pattern
    end)
  end

  defp find_first_match([], _require_kw, _forbid_kw), do: {:error, :no_match}

  defp find_first_match([provider | rest], require_kw, forbid_kw) do
    models =
      list_models(provider, require: require_kw, forbid: forbid_kw)
      |> Enum.filter(&allowed?({provider, &1.id}))

    case models do
      [] -> find_first_match(rest, require_kw, forbid_kw)
      [model | _] -> {:ok, {provider, model.id}}
    end
  end
end
