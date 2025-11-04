defmodule Mix.Tasks.LlmModels.Pull do
  use Mix.Task

  @shortdoc "Fetch model metadata from models.dev"

  @moduledoc """
  Fetches the latest model metadata from models.dev and saves it locally.

  ## Usage

      mix llm_models.pull [--url URL] [--out PATH]

  ## Options

    * `--url` - Source URL (default: https://models.dev/api.json)
    * `--out` - Output path (default: priv/llm_models/upstream.json)

  ## Examples

      mix llm_models.pull
      mix llm_models.pull --url https://custom-source.com/models.json
      mix llm_models.pull --out priv/custom/models.json
  """

  @default_url "https://models.dev/api.json"
  @default_out "priv/llm_models/upstream.json"

  @impl Mix.Task
  def run(args) do
    {opts, _remaining, _invalid} =
      OptionParser.parse(args,
        strict: [url: :string, out: :string]
      )

    url = Keyword.get(opts, :url, @default_url)
    out_path = Keyword.get(opts, :out, @default_out)

    Mix.shell().info("Fetching model metadata from #{url}...")

    ensure_apps_started()

    case download(url) do
      {:ok, body} ->
        save_file(out_path, body)
        save_manifest(out_path, url, body)
        Mix.shell().info("✓ Successfully pulled model metadata to #{out_path}")

      {:error, reason} ->
        Mix.raise("Failed to download from #{url}: #{inspect(reason)}")
    end
  end

  defp ensure_apps_started do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)
  end

  defp download(url) do
    url_charlist = String.to_charlist(url)

    http_opts = [
      ssl: [
        verify: :verify_none,
        versions: [:"tlsv1.2", :"tlsv1.3"]
      ],
      timeout: 30_000,
      connect_timeout: 10_000
    ]

    opts = [body_format: :binary]

    case :httpc.request(:get, {url_charlist, []}, http_opts, opts) do
      {:ok, {{_version, 200, _status_text}, _headers, body}} ->
        {:ok, body}

      {:ok, {{_version, status_code, _status_text}, _headers, _body}} ->
        {:error, "HTTP #{status_code}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp save_file(path, content) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(path, content)
  end

  defp save_manifest(json_path, url, content) do
    manifest_path = String.replace_suffix(json_path, ".json", ".manifest.json")

    sha256 = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    manifest = %{
      source_url: url,
      downloaded_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      sha256: sha256,
      size_bytes: byte_size(content)
    }

    manifest_json = Jason.encode!(manifest, pretty: true)
    File.write!(manifest_path, manifest_json)

    Mix.shell().info("  Downloaded #{byte_size(content)} bytes")
    Mix.shell().info("  SHA256: #{sha256}")
    Mix.shell().info("  Manifest: #{manifest_path}")
  end
end
