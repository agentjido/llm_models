defmodule Mix.Tasks.LlmModels.PullTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.LlmModels.Pull

  @moduletag :tmp_dir

  setup do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    _ = Code.ensure_loaded(:httpc)

    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(Mix.Shell.IO)

      try do
        :meck.unload(:httpc)
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  describe "argument parsing" do
    @tag :tmp_dir
    test "uses default URL and output path when no args given", %{tmp_dir: tmp_dir} do
      default_out = Path.join(tmp_dir, "priv/llm_models/upstream.json")

      mock_http_success(%{providers: [], models: []})

      in_tmp_dir(tmp_dir, fn ->
        Pull.run([])

        assert File.exists?(default_out)
        assert File.exists?(Path.join(tmp_dir, "priv/llm_models/upstream.manifest.json"))
      end)
    end

    @tag :tmp_dir
    test "uses custom output path when --out provided", %{tmp_dir: tmp_dir} do
      custom_out = Path.join(tmp_dir, "custom/location/data.json")

      mock_http_success(%{providers: [], models: []})

      in_tmp_dir(tmp_dir, fn ->
        Pull.run(["--out", custom_out])

        assert File.exists?(custom_out)
        assert File.exists?(Path.join(tmp_dir, "custom/location/data.manifest.json"))
      end)
    end

    @tag :tmp_dir
    test "accepts custom URL via --url flag", %{tmp_dir: tmp_dir} do
      custom_url = "https://custom-source.example.com/models.json"
      out_path = Path.join(tmp_dir, "upstream.json")

      mock_http_success(%{providers: [], models: []})

      in_tmp_dir(tmp_dir, fn ->
        capture_io(fn ->
          Pull.run(["--url", custom_url, "--out", out_path])
        end)

        assert_received {:mix_shell, :info, [message]}
        assert message =~ custom_url
      end)
    end
  end

  describe "file operations" do
    @tag :tmp_dir
    test "creates output directory if it doesn't exist", %{tmp_dir: tmp_dir} do
      out_path = Path.join(tmp_dir, "deeply/nested/path/upstream.json")

      mock_http_success(%{providers: [], models: []})

      in_tmp_dir(tmp_dir, fn ->
        Pull.run(["--out", out_path])

        assert File.exists?(out_path)
        assert File.dir?(Path.join(tmp_dir, "deeply/nested/path"))
      end)
    end

    @tag :tmp_dir
    test "writes valid JSON to output file", %{tmp_dir: tmp_dir} do
      out_path = Path.join(tmp_dir, "upstream.json")

      sample_data = %{
        providers: [%{id: "openai", name: "OpenAI"}],
        models: [%{provider: "openai", id: "gpt-4", name: "GPT-4"}]
      }

      mock_http_success(sample_data)

      in_tmp_dir(tmp_dir, fn ->
        Pull.run(["--out", out_path])

        {:ok, content} = File.read(out_path)
        {:ok, parsed} = Jason.decode(content)

        assert parsed == sample_data |> stringify_keys()
      end)
    end

    @tag :tmp_dir
    test "creates manifest file with metadata", %{tmp_dir: tmp_dir} do
      out_path = Path.join(tmp_dir, "upstream.json")
      manifest_path = Path.join(tmp_dir, "upstream.manifest.json")

      sample_data = %{providers: [], models: []}

      mock_http_success(sample_data)

      in_tmp_dir(tmp_dir, fn ->
        Pull.run(["--out", out_path])

        assert File.exists?(manifest_path)

        {:ok, manifest_content} = File.read(manifest_path)
        {:ok, manifest} = Jason.decode(manifest_content)

        assert Map.has_key?(manifest, "source_url")
        assert Map.has_key?(manifest, "downloaded_at")
        assert Map.has_key?(manifest, "sha256")
        assert Map.has_key?(manifest, "size_bytes")
        assert is_binary(manifest["sha256"])
        assert String.length(manifest["sha256"]) == 64
      end)
    end

    @tag :tmp_dir
    test "computes correct SHA256 hash", %{tmp_dir: tmp_dir} do
      out_path = Path.join(tmp_dir, "upstream.json")
      manifest_path = Path.join(tmp_dir, "upstream.manifest.json")

      sample_data = %{test: "data"}

      mock_http_success(sample_data)

      in_tmp_dir(tmp_dir, fn ->
        Pull.run(["--out", out_path])

        {:ok, content} = File.read(out_path)
        expected_sha = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

        {:ok, manifest_content} = File.read(manifest_path)
        {:ok, manifest} = Jason.decode(manifest_content)

        assert manifest["sha256"] == expected_sha
      end)
    end
  end

  describe "error handling" do
    @tag :tmp_dir
    test "raises on HTTP error", %{tmp_dir: tmp_dir} do
      mock_http_error(404)

      in_tmp_dir(tmp_dir, fn ->
        assert_raise Mix.Error, ~r/Failed to download/, fn ->
          Pull.run([])
        end
      end)
    end

    @tag :tmp_dir
    test "raises on network error", %{tmp_dir: tmp_dir} do
      mock_http_network_error()

      in_tmp_dir(tmp_dir, fn ->
        assert_raise Mix.Error, ~r/Failed to download/, fn ->
          Pull.run([])
        end
      end)
    end
  end

  describe "output messages" do
    @tag :tmp_dir
    test "prints success message with path", %{tmp_dir: tmp_dir} do
      out_path = Path.join(tmp_dir, "upstream.json")

      mock_http_success(%{providers: [], models: []})

      in_tmp_dir(tmp_dir, fn ->
        capture_io(fn ->
          Pull.run(["--out", out_path])
        end)

        assert_received {:mix_shell, :info, [message]}
        assert message =~ "Successfully pulled"
        assert message =~ out_path
      end)
    end

    @tag :tmp_dir
    test "prints download metadata", %{tmp_dir: tmp_dir} do
      out_path = Path.join(tmp_dir, "upstream.json")

      mock_http_success(%{providers: [], models: []})

      in_tmp_dir(tmp_dir, fn ->
        capture_io(fn ->
          Pull.run(["--out", out_path])
        end)

        assert_received {:mix_shell, :info, [message1]}
        assert_received {:mix_shell, :info, [message2]}
        assert_received {:mix_shell, :info, [message3]}
        assert_received {:mix_shell, :info, [message4]}

        messages = [message1, message2, message3, message4]
        assert Enum.any?(messages, &(&1 =~ "bytes"))
        assert Enum.any?(messages, &(&1 =~ "SHA256"))
        assert Enum.any?(messages, &(&1 =~ "Manifest"))
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

  defp prepare_httpc_mock do
    try do
      :meck.unload(:httpc)
    rescue
      _ -> :ok
    end

    :meck.new(:httpc, [:unstick, :non_strict])
  end

  defp mock_http_success(data) do
    json = Jason.encode!(data)
    prepare_httpc_mock()

    :meck.expect(:httpc, :request, fn :get, {_url, []}, _http_opts, _opts ->
      {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], json}}
    end)
  end

  defp mock_http_error(status_code) do
    prepare_httpc_mock()

    :meck.expect(:httpc, :request, fn :get, {_url, []}, _http_opts, _opts ->
      {:ok, {{~c"HTTP/1.1", status_code, ~c"Not Found"}, [], ""}}
    end)
  end

  defp mock_http_network_error do
    prepare_httpc_mock()

    :meck.expect(:httpc, :request, fn :get, {_url, []}, _http_opts, _opts ->
      {:error, :timeout}
    end)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_keys(v)} end)
  end

  defp stringify_keys(list) when is_list(list) do
    Enum.map(list, &stringify_keys/1)
  end

  defp stringify_keys(value), do: value
end
