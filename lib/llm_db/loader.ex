defmodule LLMDB.Loader do
  @moduledoc """
  Handles loading and merging of packaged snapshots with runtime customization.

  Phase 2 of LLMDB: Load the packaged snapshot, apply custom overlays,
  compile filters, and build indexes for runtime queries.

  This module encapsulates all snapshot loading logic, keeping the main
  LLMDB module focused on the query API.
  """

  alias LLMDB.{Engine, Merge, Model, Provider, Runtime}

  require Logger

  @doc """
  Loads the packaged snapshot and applies runtime configuration.

  This is the main entry point for Phase 2 (runtime) loading. It:
  1. Loads the packaged snapshot
  2. Normalizes providers/models from v1 or v2 format
  3. Merges custom providers/models overlay
  4. Compiles and applies filters
  5. Builds indexes for O(1) queries
  6. Returns snapshot ready for Store

  ## Parameters

  - `opts` - Keyword list passed to Runtime.compile/1

  ## Returns

  - `{:ok, snapshot}` - Successfully loaded and prepared snapshot
  - `{:error, :no_snapshot}` - No packaged snapshot available
  - `{:error, term}` - Other errors

  ## Examples

      {:ok, snapshot} = Loader.load()

      {:ok, snapshot} = Loader.load(
        allow: [:openai],
        custom: %{
          local: [
            models: %{"llama-3" => %{capabilities: %{chat: true}}}
          ]
        }
      )
  """
  @spec load(keyword()) :: {:ok, map()} | {:error, term()}
  def load(opts \\ []) do
    with {:ok, {providers, models, generated_at}} <- load_packaged(),
         runtime <- Runtime.compile(opts ++ [provider_ids: Enum.map(providers, & &1.id)]),
         :ok <- warn_unknown_providers(runtime.unknown, providers),
         {providers2, models2} <- merge_custom({providers, models}, runtime.custom),
         filtered_models <- Engine.apply_filters(models2, runtime.filters),
         :ok <- validate_not_empty(filtered_models, runtime),
         snapshot <- build_snapshot(providers2, filtered_models, models2, runtime, generated_at) do
      {:ok, snapshot}
    end
  end

  @doc """
  Builds an empty snapshot with no providers or models.

  Used as a fallback when no packaged snapshot is available.

  ## Examples

      {:ok, snapshot} = Loader.load_empty()
  """
  @spec load_empty(keyword()) :: {:ok, map()}
  def load_empty(opts \\ []) do
    runtime = Runtime.compile(opts)

    snapshot = %{
      providers_by_id: %{},
      models_by_key: %{},
      aliases_by_key: %{},
      providers: [],
      models: %{},
      base_models: [],
      filters: runtime.filters,
      prefer: runtime.prefer,
      meta: %{
        epoch: nil,
        source_generated_at: nil,
        loaded_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        digest: compute_digest([], [], runtime)
      }
    }

    {:ok, snapshot}
  end

  @doc """
  Computes a digest for a snapshot configuration.

  Used to detect if a reload would result in the same snapshot,
  enabling idempotent load operations.

  ## Parameters

  - `providers` - List of provider maps
  - `base_models` - List of all models before filtering
  - `runtime` - Runtime configuration map

  ## Returns

  Integer digest (phash2 hash)
  """
  @spec compute_digest(list(), list(), map()) :: integer()
  def compute_digest(providers, base_models, runtime) do
    # Stable hash of configuration that affects the final snapshot
    :erlang.phash2({
      # Provider IDs (order matters for determinism)
      Enum.map(providers, & &1.id),
      # Model keys (provider + id)
      Enum.map(base_models, fn m -> {m.provider, m.id} end),
      # Runtime config that affects filtering
      runtime.raw_allow,
      runtime.raw_deny,
      runtime.prefer,
      # Custom overlay
      custom_digest(runtime.custom)
    })
  end

  # Private helpers
  defp load_packaged do
    case apply(LLMDB.Packaged, :snapshot, []) do
      nil ->
        {:error, :no_snapshot}

      %{version: 2, providers: nested_providers, generated_at: generated_at} ->
        # V2 snapshot with nested providers
        {providers, models} = flatten_nested_providers(nested_providers)

        {:ok,
         {deserialize_json_atoms(providers, :provider), deserialize_json_atoms(models, :model),
          generated_at}}

      %{providers: providers, models: models, generated_at: generated_at}
      when is_list(providers) and is_list(models) ->
        # V1 snapshot with generated_at
        {:ok,
         {deserialize_json_atoms(providers, :provider), deserialize_json_atoms(models, :model),
          generated_at}}

      %{providers: providers, models: models}
      when is_list(providers) and is_list(models) ->
        # V1 snapshot without generated_at
        {:ok,
         {deserialize_json_atoms(providers, :provider), deserialize_json_atoms(models, :model),
          nil}}

      _ ->
        {:error, :invalid_snapshot_format}
    end
  end

  defp flatten_nested_providers(nested_providers) when is_map(nested_providers) do
    {providers, all_models} =
      Enum.reduce(nested_providers, {[], []}, fn {_provider_id, provider_data},
                                                 {acc_providers, acc_models} ->
        # Extract provider without models key
        provider = Map.delete(provider_data, :models)

        # Get provider ID as string for models
        provider_id_str =
          case provider_data[:id] do
            a when is_atom(a) -> Atom.to_string(a)
            s when is_binary(s) -> s
          end

        # Extract models and ensure they have provider field
        models =
          case Map.get(provider_data, :models) do
            models when is_map(models) ->
              Enum.map(models, fn {_model_id, model_data} ->
                Map.put_new(model_data, :provider, provider_id_str)
              end)

            _ ->
              []
          end

        {[provider | acc_providers], models ++ acc_models}
      end)

    {Enum.reverse(providers), Enum.reverse(all_models)}
  end

  defp deserialize_json_atoms(items, :provider) do
    Enum.map(items, fn provider ->
      # Convert provider ID from JSON string to existing atom
      normalized_id =
        case Map.get(provider, :id) do
          id when is_atom(id) -> id
          id when is_binary(id) -> String.to_existing_atom(id)
        end

      provider_map = %{provider | id: normalized_id}

      # Validate and create Provider struct
      case provider do
        %Provider{} -> %{provider | id: normalized_id}
        _ -> Provider.new!(provider_map)
      end
    end)
  end

  defp deserialize_json_atoms(items, :model) do
    Enum.map(items, fn model ->
      # Convert provider from JSON string to existing atom
      normalized_provider =
        case Map.get(model, :provider) do
          p when is_atom(p) -> p
          p when is_binary(p) -> String.to_existing_atom(p)
        end

      # Convert modality strings to existing atoms
      model_map =
        case Map.get(model, :modalities) do
          %{input: input, output: output} ->
            Map.put(model, :modalities, %{
              input: deserialize_modality_list(input),
              output: deserialize_modality_list(output)
            })

          _ ->
            model
        end

      model_map = Map.put(model_map, :provider, normalized_provider)

      # Validate and create Model struct
      case model do
        %Model{} -> model_map
        _ -> Model.new!(model_map)
      end
    end)
  end

  defp deserialize_modality_list(list) when is_list(list) do
    Enum.map(list, fn
      s when is_binary(s) -> String.to_existing_atom(s)
      a when is_atom(a) -> a
    end)
  end

  defp deserialize_modality_list(other), do: other

  defp merge_custom({providers, models}, %{providers: [], models: []}) do
    # No custom overlay
    {providers, models}
  end

  defp merge_custom({providers, models}, custom) do
    # Deserialize custom providers and models (convert JSON strings to atoms)
    custom_providers = deserialize_json_atoms(custom.providers, :provider)
    custom_models = deserialize_json_atoms(custom.models, :model)

    # Merge providers (last wins by ID)
    merged_providers = Merge.merge_providers(providers, custom_providers)

    # Merge models (last wins by provider + id)
    merged_models = merge_models(models, custom_models)

    {merged_providers, merged_models}
  end

  defp merge_models(base_models, custom_models) do
    # Build map by {provider, id} for efficient merging
    base_map = Map.new(base_models, fn m -> {{m.provider, m.id}, m} end)
    custom_map = Map.new(custom_models, fn m -> {{m.provider, m.id}, m} end)

    # Merge with custom winning
    Map.merge(base_map, custom_map)
    |> Map.values()
  end

  defp warn_unknown_providers([], _providers), do: :ok

  defp warn_unknown_providers(unknown_providers, providers) do
    provider_ids_set = MapSet.new(providers, & &1.id)

    Logger.warning(
      "llm_db: unknown provider(s) in filter: #{inspect(unknown_providers)}. " <>
        "Known providers: #{inspect(MapSet.to_list(provider_ids_set))}. " <>
        "Check spelling or remove unknown providers from configuration."
    )

    :ok
  end

  defp validate_not_empty(filtered_models, runtime) do
    if runtime.filters.allow != :all and filtered_models == [] do
      {:error,
       "llm_db: filters eliminated all models. Check :llm_db filter configuration. " <>
         "allow: #{summarize_filter(runtime.raw_allow)}, deny: #{summarize_filter(runtime.raw_deny)}. " <>
         "Use allow: :all to widen filters or remove deny patterns."}
    else
      :ok
    end
  end

  defp build_snapshot(providers, filtered_models, base_models, runtime, generated_at) do
    # Apply provider aliases AFTER all sources are loaded
    providers_with_aliases = apply_provider_aliases(providers)

    %{
      providers_by_id: index_providers(providers_with_aliases),
      models_by_key: index_models(filtered_models),
      aliases_by_key: index_aliases(filtered_models),
      providers: providers_with_aliases,
      models: Enum.group_by(filtered_models, & &1.provider),
      base_models: base_models,
      filters: runtime.filters,
      prefer: runtime.prefer,
      meta: %{
        epoch: nil,
        source_generated_at: generated_at,
        loaded_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        digest: compute_digest(providers, base_models, runtime)
      }
    }
  end

  # Apply provider aliases post-load (after all sources merged)
  # This handles cases where a single implementation (e.g., GoogleVertex)
  # should handle models from multiple LLMDB providers
  defp apply_provider_aliases(providers) do
    # Hardcoded provider alias mappings
    # Key: aliased provider ID, Value: primary provider ID
    alias_map = %{
      google_vertex_anthropic: :google_vertex
    }

    Enum.map(providers, fn provider ->
      case Map.get(alias_map, provider.id) do
        nil -> provider
        primary_id -> Map.put(provider, :alias_of, primary_id)
      end
    end)
  end

  defp index_providers(providers), do: Map.new(providers, &{&1.id, &1})

  defp index_models(models), do: Map.new(models, &{{&1.provider, &1.id}, &1})

  defp index_aliases(models) do
    models
    |> Enum.flat_map(fn model ->
      provider = model.provider
      canonical_id = model.id
      aliases = Map.get(model, :aliases, [])

      Enum.map(aliases, fn alias_name ->
        {{provider, alias_name}, canonical_id}
      end)
    end)
    |> Map.new()
  end

  defp custom_digest(%{providers: [], models: []}), do: nil

  defp custom_digest(%{providers: providers, models: models}) do
    :erlang.phash2({
      Enum.map(providers, & &1.id),
      Enum.map(models, fn m -> {m.provider, m.id} end)
    })
  end

  defp summarize_filter(:all), do: ":all"

  defp summarize_filter(filter) when is_map(filter) and map_size(filter) == 0 do
    "%{}"
  end

  defp summarize_filter(filter) when is_map(filter) do
    keys = Map.keys(filter) |> Enum.take(5)

    if map_size(filter) > 5 do
      "#{inspect(keys)} ... (#{map_size(filter)} providers total)"
    else
      inspect(filter)
    end
  end
end
