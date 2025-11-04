defmodule Mix.Tasks.LlmModels.ActivateTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.LlmModels.Activate

  @moduletag :tmp_dir

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    :ok
  end

  describe "argument parsing" do
    @tag :tmp_dir
    test "uses default input path when no args given", %{tmp_dir: tmp_dir} do
      default_from = Path.join(tmp_dir, "priv/llm_models/upstream.json")
      snapshot_out = Path.join(tmp_dir, "priv/llm_models/snapshot.json")

      create_upstream_file(default_from, sample_upstream_data())

      in_tmp_dir(tmp_dir, fn ->
        Activate.run([])

        assert File.exists?(snapshot_out)
      end)
    end

    @tag :tmp_dir
    test "uses custom input path when --from provided", %{tmp_dir: tmp_dir} do
      custom_from = Path.join(tmp_dir, "custom/upstream.json")
      snapshot_out = Path.join(tmp_dir, "priv/llm_models/snapshot.json")

      create_upstream_file(custom_from, sample_upstream_data())

      in_tmp_dir(tmp_dir, fn ->
        Activate.run(["--from", custom_from])

        assert File.exists?(snapshot_out)
      end)
    end
  end

  describe "file operations" do
    @tag :tmp_dir
    test "creates snapshot directory if it doesn't exist", %{tmp_dir: tmp_dir} do
      from_path = Path.join(tmp_dir, "upstream.json")
      snapshot_out = Path.join(tmp_dir, "priv/llm_models/snapshot.json")

      create_upstream_file(from_path, sample_upstream_data())

      in_tmp_dir(tmp_dir, fn ->
        Activate.run(["--from", from_path])

        assert File.exists?(snapshot_out)
        assert File.dir?(Path.join(tmp_dir, "priv/llm_models"))
      end)
    end

    @tag :tmp_dir
    test "writes valid JSON snapshot with providers and models", %{tmp_dir: tmp_dir} do
      from_path = Path.join(tmp_dir, "upstream.json")
      snapshot_out = Path.join(tmp_dir, "priv/llm_models/snapshot.json")

      upstream_data = %{
        "providers" => [
          %{"id" => "openai", "name" => "OpenAI", "api_url" => "https://api.openai.com/v1"}
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

        {:ok, content} = File.read(snapshot_out)
        {:ok, snapshot} = Jason.decode(content)

        assert Map.has_key?(snapshot, "providers")
        assert Map.has_key?(snapshot, "models")
        assert is_list(snapshot["providers"])
        assert is_list(snapshot["models"])
      end)
    end

    @tag :tmp_dir
    test "formats JSON with pretty printing", %{tmp_dir: tmp_dir} do
      from_path = Path.join(tmp_dir, "upstream.json")
      snapshot_out = Path.join(tmp_dir, "priv/llm_models/snapshot.json")

      create_upstream_file(from_path, sample_upstream_data())

      in_tmp_dir(tmp_dir, fn ->
        Activate.run(["--from", from_path])

        {:ok, content} = File.read(snapshot_out)

        assert content =~ "\n"
        assert content =~ "  "
      end)
    end
  end

  describe "data processing" do
    @tag :tmp_dir
    test "processes providers correctly", %{tmp_dir: tmp_dir} do
      from_path = Path.join(tmp_dir, "upstream.json")
      snapshot_out = Path.join(tmp_dir, "priv/llm_models/snapshot.json")

      upstream_data = %{
        "providers" => [
          %{"id" => "openai", "name" => "OpenAI"},
          %{"id" => "anthropic", "name" => "Anthropic"}
        ],
        "models" => [
          %{"id" => "gpt-4", "provider" => "openai"},
          %{"id" => "claude-3-opus", "provider" => "anthropic"}
        ]
      }

      create_upstream_file(from_path, upstream_data)

      in_tmp_dir(tmp_dir, fn ->
        Activate.run(["--from", from_path])

        {:ok, content} = File.read(snapshot_out)
        {:ok, snapshot} = Jason.decode(content)

        assert length(snapshot["providers"]) == 2
        provider_ids = Enum.map(snapshot["providers"], & &1["id"]) |> Enum.sort()
        assert provider_ids == ["anthropic", "openai"]
      end)
    end

    @tag :tmp_dir
    test "processes models correctly", %{tmp_dir: tmp_dir} do
      from_path = Path.join(tmp_dir, "upstream.json")
      snapshot_out = Path.join(tmp_dir, "priv/llm_models/snapshot.json")

      upstream_data = %{
        "providers" => [%{"id" => "openai", "name" => "OpenAI"}],
        "models" => [
          %{"provider" => "openai", "id" => "gpt-4", "name" => "GPT-4"},
          %{"provider" => "openai", "id" => "gpt-3.5-turbo", "name" => "GPT-3.5 Turbo"}
        ]
      }

      create_upstream_file(from_path, upstream_data)

      in_tmp_dir(tmp_dir, fn ->
        Activate.run(["--from", from_path])

        {:ok, content} = File.read(snapshot_out)
        {:ok, snapshot} = Jason.decode(content)

        assert length(snapshot["models"]) == 2
        model_ids = Enum.map(snapshot["models"], & &1["id"]) |> Enum.sort()
        assert model_ids == ["gpt-3.5-turbo", "gpt-4"]
      end)
    end

    @tag :tmp_dir
    test "validates and drops invalid records", %{tmp_dir: tmp_dir} do
      from_path = Path.join(tmp_dir, "upstream.json")
      snapshot_out = Path.join(tmp_dir, "priv/llm_models/snapshot.json")

      upstream_data = %{
        "providers" => [
          %{"id" => "openai", "name" => "OpenAI"},
          %{"name" => "Invalid Provider"}
        ],
        "models" => [
          %{"provider" => "openai", "id" => "gpt-4", "name" => "GPT-4"},
          %{"provider" => "openai", "name" => "Invalid Model"}
        ]
      }

      create_upstream_file(from_path, upstream_data)

      in_tmp_dir(tmp_dir, fn ->
        Activate.run(["--from", from_path])

        {:ok, content} = File.read(snapshot_out)
        {:ok, snapshot} = Jason.decode(content)

        assert length(snapshot["providers"]) == 1
        assert length(snapshot["models"]) == 1
      end)
    end
  end

  describe "error handling" do
    @tag :tmp_dir
    test "raises when upstream file doesn't exist", %{tmp_dir: tmp_dir} do
      nonexistent_path = Path.join(tmp_dir, "nonexistent.json")

      in_tmp_dir(tmp_dir, fn ->
        assert_raise Mix.Error, ~r/Upstream file not found/, fn ->
          Activate.run(["--from", nonexistent_path])
        end
      end)
    end

    @tag :tmp_dir
    test "raises when upstream file contains invalid JSON", %{tmp_dir: tmp_dir} do
      from_path = Path.join(tmp_dir, "upstream.json")

      File.mkdir_p!(Path.dirname(from_path))
      File.write!(from_path, "invalid json {")

      in_tmp_dir(tmp_dir, fn ->
        assert_raise Mix.Error, ~r/Failed to parse JSON/, fn ->
          Activate.run(["--from", from_path])
        end
      end)
    end

    @tag :tmp_dir
    test "raises when catalog is empty after processing", %{tmp_dir: tmp_dir} do
      from_path = Path.join(tmp_dir, "upstream.json")

      create_upstream_file(from_path, %{"providers" => [], "models" => []})

      in_tmp_dir(tmp_dir, fn ->
        assert_raise Mix.Error, ~r/empty catalog/, fn ->
          Activate.run(["--from", from_path])
        end
      end)
    end
  end

  describe "output messages" do
    @tag :tmp_dir
    test "prints success message with path", %{tmp_dir: tmp_dir} do
      from_path = Path.join(tmp_dir, "upstream.json")

      create_upstream_file(from_path, sample_upstream_data())

      in_tmp_dir(tmp_dir, fn ->
        capture_io(fn ->
          Activate.run(["--from", from_path])
        end)

        assert_received {:mix_shell, :info, [message]}
        assert message =~ "Snapshot written to"
      end)
    end

    @tag :tmp_dir
    test "prints summary with provider and model counts", %{tmp_dir: tmp_dir} do
      from_path = Path.join(tmp_dir, "upstream.json")

      upstream_data = %{
        "providers" => [
          %{"id" => "openai", "name" => "OpenAI"},
          %{"id" => "anthropic", "name" => "Anthropic"}
        ],
        "models" => [
          %{"provider" => "openai", "id" => "gpt-4", "name" => "GPT-4"},
          %{"provider" => "anthropic", "id" => "claude-3", "name" => "Claude 3"}
        ]
      }

      create_upstream_file(from_path, upstream_data)

      in_tmp_dir(tmp_dir, fn ->
        capture_io(fn ->
          Activate.run(["--from", from_path])
        end)

        messages = collect_all_info_messages()

        assert Enum.any?(messages, &(&1 =~ "Providers: 2"))
        assert Enum.any?(messages, &(&1 =~ "Models: 2"))
      end)
    end

    @tag :tmp_dir
    test "prints advice about next steps", %{tmp_dir: tmp_dir} do
      from_path = Path.join(tmp_dir, "upstream.json")

      create_upstream_file(from_path, sample_upstream_data())

      in_tmp_dir(tmp_dir, fn ->
        capture_io(fn ->
          Activate.run(["--from", from_path])
        end)

        messages = collect_all_info_messages()

        assert Enum.any?(messages, &(&1 =~ "Next steps"))
        assert Enum.any?(messages, &(&1 =~ "reload"))
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

  defp sample_upstream_data do
    %{
      "providers" => [
        %{"id" => "openai", "name" => "OpenAI", "api_url" => "https://api.openai.com/v1"}
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
  end

  defp collect_all_info_messages do
    collect_all_info_messages([])
  end

  defp collect_all_info_messages(acc) do
    receive do
      {:mix_shell, :info, [message]} ->
        collect_all_info_messages([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
