defmodule LlmModels.PackagedTest do
  use ExUnit.Case, async: true

  alias LlmModels.Packaged

  describe "path/0" do
    test "returns absolute path to snapshot.json" do
      path = Packaged.path()

      assert is_binary(path)
      assert String.ends_with?(path, "priv/llm_models/snapshot.json")
    end

    test "path includes app_dir" do
      path = Packaged.path()
      app_dir = Application.app_dir(:llm_models)

      assert String.starts_with?(path, app_dir)
    end
  end

  describe "snapshot/0" do
    test "returns nil when file doesn't exist" do
      snapshot = Packaged.snapshot()

      assert snapshot == nil
    end
  end

  describe "snapshot/0 with fixture" do
    setup do
      fixture_path = Path.join([__DIR__, "..", "fixtures", "snapshot.json"])
      app_snapshot_dir = Path.dirname(Packaged.path())
      app_snapshot_path = Packaged.path()

      File.mkdir_p!(app_snapshot_dir)
      File.cp!(fixture_path, app_snapshot_path)

      on_exit(fn ->
        File.rm(app_snapshot_path)
      end)

      :ok
    end

    test "returns parsed snapshot with atom keys" do
      snapshot = Packaged.snapshot()

      assert is_map(snapshot)
      assert Map.has_key?(snapshot, :providers)
      assert Map.has_key?(snapshot, :models)
    end

    test "providers are parsed correctly" do
      snapshot = Packaged.snapshot()

      assert is_list(snapshot.providers)
      assert length(snapshot.providers) == 2

      openai = Enum.find(snapshot.providers, &(&1.id == "openai"))
      assert openai.name == "OpenAI"
      assert openai.base_url == "https://api.openai.com/v1"

      anthropic = Enum.find(snapshot.providers, &(&1.id == "anthropic"))
      assert anthropic.name == "Anthropic"
      assert anthropic.base_url == "https://api.anthropic.com/v1"
    end

    test "models are parsed correctly" do
      snapshot = Packaged.snapshot()

      assert is_list(snapshot.models)
      assert length(snapshot.models) == 2

      gpt4 = Enum.find(snapshot.models, &(&1.id == "gpt-4"))
      assert gpt4.provider == "openai"
      assert gpt4.context_window == 8192
      assert gpt4.max_output == 4096

      claude = Enum.find(snapshot.models, &(&1.id == "claude-3-opus"))
      assert claude.provider == "anthropic"
      assert claude.context_window == 200_000
      assert claude.max_output == 4096
    end

    test "returns same snapshot on repeated calls" do
      snapshot1 = Packaged.snapshot()
      snapshot2 = Packaged.snapshot()

      assert snapshot1 == snapshot2
    end
  end

  describe "snapshot/0 with malformed JSON" do
    setup do
      app_snapshot_dir = Path.dirname(Packaged.path())
      app_snapshot_path = Packaged.path()

      File.mkdir_p!(app_snapshot_dir)
      File.write!(app_snapshot_path, "{invalid json")

      on_exit(fn ->
        File.rm(app_snapshot_path)
      end)

      :ok
    end

    test "raises Jason.DecodeError for malformed JSON" do
      assert_raise Jason.DecodeError, fn ->
        Packaged.snapshot()
      end
    end
  end

  describe "snapshot/0 with empty file" do
    setup do
      app_snapshot_dir = Path.dirname(Packaged.path())
      app_snapshot_path = Packaged.path()

      File.mkdir_p!(app_snapshot_dir)
      File.write!(app_snapshot_path, "")

      on_exit(fn ->
        File.rm(app_snapshot_path)
      end)

      :ok
    end

    test "raises error for empty file" do
      assert_raise Jason.DecodeError, fn ->
        Packaged.snapshot()
      end
    end
  end
end
