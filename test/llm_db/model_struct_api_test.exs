defmodule LLMDB.ModelStructAPITest do
  use ExUnit.Case, async: false

  alias LLMDB.Store

  setup do
    Store.clear!()

    model = %{
      id: "gpt-4o-mini",
      provider: :openai,
      name: "GPT-4o Mini",
      capabilities: %{
        chat: true,
        tools: %{enabled: true, streaming: true},
        json: %{native: true}
      },
      aliases: []
    }

    snapshot = %{
      providers_by_id: %{
        openai: %{id: :openai, name: "OpenAI"}
      },
      models_by_key: %{
        {:openai, "gpt-4o-mini"} => model
      },
      aliases_by_key: %{},
      providers: [%{id: :openai, name: "OpenAI"}],
      models: %{
        openai: [model]
      },
      filters: %{
        allow: :all,
        deny: %{}
      },
      prefer: [],
      meta: %{
        epoch: nil,
        generated_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }
    }

    Store.put!(snapshot, [])

    :ok
  end

  describe "allowed?/1 with Model struct" do
    test "returns true for allowed model struct" do
      {:ok, model} = LLMDB.model(:openai, "gpt-4o-mini")
      assert LLMDB.allowed?(model) == true
    end

    test "returns true for allowed model - tuple format" do
      assert LLMDB.allowed?({:openai, "gpt-4o-mini"}) == true
    end

    test "returns true for allowed model - string format" do
      assert LLMDB.allowed?("openai:gpt-4o-mini") == true
    end
  end

  describe "capabilities/1 with Model struct" do
    test "returns capabilities from model struct directly" do
      {:ok, model} = LLMDB.model(:openai, "gpt-4o-mini")
      caps = LLMDB.capabilities(model)

      assert caps.chat == true
      assert caps.tools.enabled == true
      assert caps.json.native == true
    end

    test "returns capabilities from tuple format" do
      caps = LLMDB.capabilities({:openai, "gpt-4o-mini"})

      assert caps.chat == true
      assert caps.tools.enabled == true
    end

    test "returns capabilities from string format" do
      caps = LLMDB.capabilities("openai:gpt-4o-mini")

      assert caps.chat == true
      assert caps.tools.enabled == true
    end
  end

  describe "LLMDB.Model.spec/2" do
    test "formats model as default spec string" do
      {:ok, model} = LLMDB.model(:openai, "gpt-4o-mini")
      assert LLMDB.Model.spec(model) == "openai:gpt-4o-mini"
    end

    test "formats model with explicit :provider_colon_model format" do
      {:ok, model} = LLMDB.model(:openai, "gpt-4o-mini")
      assert LLMDB.Model.spec(model, :provider_colon_model) == "openai:gpt-4o-mini"
    end

    test "formats model with :model_at_provider format" do
      {:ok, model} = LLMDB.model(:openai, "gpt-4o-mini")
      assert LLMDB.Model.spec(model, :model_at_provider) == "gpt-4o-mini@openai"
    end

    test "formats model with :filename_safe format" do
      {:ok, model} = LLMDB.model(:openai, "gpt-4o-mini")
      assert LLMDB.Model.spec(model, :filename_safe) == "gpt-4o-mini@openai"
    end
  end
end
