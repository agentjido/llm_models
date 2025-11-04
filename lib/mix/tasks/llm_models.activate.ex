defmodule Mix.Tasks.LlmModels.Activate do
  use Mix.Task

  @shortdoc "Activate upstream model metadata as packaged snapshot"

  @moduledoc """
  Validates and normalizes upstream model metadata, merging with local overrides
  to create a packaged snapshot.

  ## Usage

      mix llm_models.activate [--from PATH]

  ## Options

    * `--from` - Source file (default: priv/llm_models/upstream.json)

  The output is always written to priv/llm_models/snapshot.json

  ## Examples

      mix llm_models.activate
      mix llm_models.activate --from priv/custom/models.json

  After activation:
  - If compile_embed: true, recompile to pick up changes
  - Otherwise, call LlmModels.reload/0 to update runtime catalog
  """

  @default_from "priv/llm_models/upstream.json"
  @snapshot_out "priv/llm_models/snapshot.json"

  @impl Mix.Task
  def run(args) do
    {opts, _remaining, _invalid} =
      OptionParser.parse(args,
        strict: [from: :string]
      )

    from_path = Keyword.get(opts, :from, @default_from)

    Mix.shell().info("Activating model metadata from #{from_path}...")

    upstream_data = read_upstream(from_path)

    write_temp_snapshot(upstream_data)

    config = build_config()

    case LlmModels.Engine.run(config) do
      {:ok, snapshot} ->
        save_final_snapshot(snapshot)
        print_summary(snapshot)
        print_advice()

      {:error, :empty_catalog} ->
        Mix.raise("Activation failed: resulting catalog is empty")

      {:error, reason} ->
        Mix.raise("Activation failed: #{inspect(reason)}")
    end
  end

  defp read_upstream(path) do
    unless File.exists?(path) do
      Mix.raise("Upstream file not found: #{path}")
    end

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} ->
            data

          {:error, reason} ->
            Mix.raise("Failed to parse JSON from #{path}: #{inspect(reason)}")
        end

      {:error, reason} ->
        Mix.raise("Failed to read #{path}: #{inspect(reason)}")
    end
  end

  defp write_temp_snapshot(upstream_data) do
    temp_path = LlmModels.Packaged.path()

    temp_path
    |> Path.dirname()
    |> File.mkdir_p!()

    providers = atomize_keys(Map.get(upstream_data, "providers", []))
    models = atomize_keys(Map.get(upstream_data, "models", []))

    temp_data = %{providers: providers, models: models}

    json = Jason.encode!(temp_data)
    File.write!(temp_path, json)

    temp_path
  end

  defp build_config do
    app_config = Application.get_all_env(:llm_models)

    overrides_from_app = Keyword.get(app_config, :overrides, %{})

    overrides = %{
      providers: normalize_overrides(Map.get(overrides_from_app, :providers, [])),
      models: normalize_overrides(Map.get(overrides_from_app, :models, [])),
      exclude: Map.get(overrides_from_app, :exclude, %{})
    }

    [
      config: %{
        compile_embed: false,
        overrides: overrides,
        overrides_module: nil,
        allow: Keyword.get(app_config, :allow, :all),
        deny: Keyword.get(app_config, :deny, %{}),
        prefer: Keyword.get(app_config, :prefer, [])
      }
    ]
  end

  defp normalize_overrides(list) when is_list(list), do: list
  defp normalize_overrides(_), do: []

  defp atomize_keys(list) when is_list(list) do
    Enum.map(list, &atomize_keys/1)
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = if is_binary(k), do: String.to_atom(k), else: k
      {key, atomize_keys(v)}
    end)
  end

  defp atomize_keys(value), do: value

  defp save_final_snapshot(snapshot) do
    @snapshot_out
    |> Path.dirname()
    |> File.mkdir_p!()

    output_data = %{
      providers: snapshot.providers,
      models: Map.values(snapshot.models) |> List.flatten()
    }

    json = Jason.encode!(output_data, pretty: true)
    File.write!(@snapshot_out, json)

    Mix.shell().info("✓ Snapshot written to #{@snapshot_out}")
  end

  defp print_summary(snapshot) do
    provider_count = length(snapshot.providers)
    model_count = Map.values(snapshot.models) |> Enum.map(&length/1) |> Enum.sum()

    Mix.shell().info("")
    Mix.shell().info("Summary:")
    Mix.shell().info("  Providers: #{provider_count}")
    Mix.shell().info("  Models: #{model_count}")
  end

  defp print_advice do
    compile_embed = Application.get_env(:llm_models, :compile_embed, false)

    Mix.shell().info("")

    if compile_embed do
      Mix.shell().info("Next steps:")
      Mix.shell().info("  Run `mix compile --force` to embed the new snapshot")
    else
      Mix.shell().info("Next steps:")
      Mix.shell().info("  Call `LlmModels.reload/0` to load the new snapshot at runtime")
    end
  end
end
