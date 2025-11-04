defmodule Mix.Tasks.LlmModels.IntegrationTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.LlmModels.Activate

  @moduletag :tmp_dir

  setup do
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(Mix.Shell.IO)
    end)

    :ok
  end

  describe "activate task integration" do
    @tag :tmp_dir
    test "successfully processes valid upstream data", %{tmp_dir: tmp_dir} do
      from_path = Path.join(tmp_dir, "upstream.json")
      snapshot_path = Path.join(tmp_dir, "priv/llm_models/snapshot.json")

      upstream_data = %{
        "providers" => [
          %{
            "id" => "openai",
            "name" => "OpenAI",
            "api_url" => "https://api.openai.com/v1"
          }
        ],
        "models" => [
          %{
            "provider" => "openai",
            "id" => "gpt-4",
            "name" => "GPT-4",
            "context_window" => 8192,
            "max_completion_tokens" => 4096
          }
        ]
      }

      create_upstream_file(from_path, upstream_data)

      in_tmp_dir(tmp_dir, fn ->
        Activate.run(["--from", from_path])

        assert File.exists?(snapshot_path)

        {:ok, content} = File.read(snapshot_path)
        {:ok, snapshot} = Jason.decode(content)

        assert Map.has_key?(snapshot, "providers")
        assert Map.has_key?(snapshot, "models")
        assert length(snapshot["providers"]) == 1
        assert length(snapshot["models"]) == 1

        provider = hd(snapshot["providers"])
        assert provider["id"] == "openai"
        assert provider["name"] == "OpenAI"

        model = hd(snapshot["models"])
        assert model["provider"] == "openai"
        assert model["id"] == "gpt-4"
        assert model["name"] == "GPT-4"
      end)
    end
  end

  defp in_tmp_dir(tmp_dir, fun) do
    original_dir = File.cwd!()
    File.cd!(tmp_dir)

    try do
      fun.()
    after
      File.cd!(original_dir)
    end
  end

  defp create_upstream_file(path, data) do
    File.mkdir_p!(Path.dirname(path))
    json = Jason.encode!(data, pretty: true)
    File.write!(path, json)
  end
end
