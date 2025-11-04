defmodule LlmModels.EngineTest do
  use ExUnit.Case, async: true

  alias LlmModels.Engine

  describe "run/1" do
    test "full pipeline with packaged data only" do
      packaged_data = %{
        providers: [
          %{id: :openai, name: "OpenAI"},
          %{id: :anthropic, name: "Anthropic"}
        ],
        models: [
          %{id: "gpt-4o", provider: :openai},
          %{id: "claude-3-opus", provider: :anthropic}
        ]
      }

      config = %{
        compile_embed: false,
        overrides: %{providers: [], models: [], exclude: %{}},
        overrides_module: nil,
        allow: :all,
        deny: %{},
        prefer: []
      }

      with_packaged_snapshot(packaged_data, fn ->
        with_config(config, fn ->
          assert {:ok, snapshot} = Engine.run()

          assert map_size(snapshot.providers_by_id) == 2
          assert snapshot.providers_by_id[:openai].name == "OpenAI"
          assert snapshot.providers_by_id[:anthropic].name == "Anthropic"

          assert map_size(snapshot.models_by_key) == 2
          assert snapshot.models_by_key[{:openai, "gpt-4o"}].id == "gpt-4o"
          assert snapshot.models_by_key[{:anthropic, "claude-3-opus"}].id == "claude-3-opus"

          assert length(snapshot.providers) == 2
          assert map_size(snapshot.models) == 2

          assert snapshot.meta.epoch == nil
          assert is_binary(snapshot.meta.generated_at)
        end)
      end)
    end

    test "full pipeline with config overrides" do
      packaged_data = %{
        providers: [%{id: :openai, name: "OpenAI"}],
        models: [%{id: "gpt-4o", provider: :openai}]
      }

      config = %{
        compile_embed: false,
        overrides: %{
          providers: [%{id: :anthropic, name: "Anthropic"}],
          models: [%{id: "claude-3-opus", provider: :anthropic}],
          exclude: %{}
        },
        overrides_module: nil,
        allow: :all,
        deny: %{},
        prefer: []
      }

      with_packaged_snapshot(packaged_data, fn ->
        with_config(config, fn ->
          assert {:ok, snapshot} = Engine.run()

          assert map_size(snapshot.providers_by_id) == 2
          assert map_size(snapshot.models_by_key) == 2
          assert snapshot.models_by_key[{:anthropic, "claude-3-opus"}] != nil
        end)
      end)
    end

    test "full pipeline with behaviour overrides" do
      defmodule TestOverrides do
        @behaviour LlmModels.Overrides

        @impl true
        def providers, do: [%{id: :google, name: "Google"}]

        @impl true
        def models, do: [%{id: "gemini-pro", provider: :google}]

        @impl true
        def excludes, do: %{}
      end

      packaged_data = %{
        providers: [%{id: :openai, name: "OpenAI"}],
        models: [%{id: "gpt-4o", provider: :openai}]
      }

      config = %{
        compile_embed: false,
        overrides: %{providers: [], models: [], exclude: %{}},
        overrides_module: TestOverrides,
        allow: :all,
        deny: %{},
        prefer: []
      }

      with_packaged_snapshot(packaged_data, fn ->
        with_config(config, fn ->
          assert {:ok, snapshot} = Engine.run()

          assert map_size(snapshot.providers_by_id) == 2
          assert snapshot.providers_by_id[:google].name == "Google"
          assert map_size(snapshot.models_by_key) == 2
          assert snapshot.models_by_key[{:google, "gemini-pro"}] != nil
        end)
      end)
    end

    test "precedence: config overrides packaged" do
      packaged_data = %{
        providers: [%{id: :openai, name: "OpenAI Original"}],
        models: [%{id: "gpt-4o", provider: :openai}]
      }

      config = %{
        compile_embed: false,
        overrides: %{
          providers: [%{id: :openai, name: "OpenAI Updated"}],
          models: [],
          exclude: %{}
        },
        overrides_module: nil,
        allow: :all,
        deny: %{},
        prefer: []
      }

      with_packaged_snapshot(packaged_data, fn ->
        with_config(config, fn ->
          assert {:ok, snapshot} = Engine.run()

          assert snapshot.providers_by_id[:openai].name == "OpenAI Updated"
        end)
      end)
    end

    test "precedence: behaviour overrides config and packaged" do
      defmodule TestOverridesPrecedence do
        @behaviour LlmModels.Overrides

        @impl true
        def providers, do: [%{id: :openai, name: "OpenAI Behaviour"}]

        @impl true
        def models, do: []

        @impl true
        def excludes, do: %{}
      end

      packaged_data = %{
        providers: [%{id: :openai, name: "OpenAI Original"}],
        models: [%{id: "gpt-4o", provider: :openai}]
      }

      config = %{
        compile_embed: false,
        overrides: %{
          providers: [%{id: :openai, name: "OpenAI Config"}],
          models: [],
          exclude: %{}
        },
        overrides_module: TestOverridesPrecedence,
        allow: :all,
        deny: %{},
        prefer: []
      }

      with_packaged_snapshot(packaged_data, fn ->
        with_config(config, fn ->
          assert {:ok, snapshot} = Engine.run()

          assert snapshot.providers_by_id[:openai].name == "OpenAI Behaviour"
        end)
      end)
    end

    test "exclude handling removes models" do
      packaged_data = %{
        providers: [%{id: :openai, name: "OpenAI"}],
        models: [
          %{id: "gpt-4o", provider: :openai},
          %{id: "gpt-3.5-turbo", provider: :openai},
          %{id: "gpt-4o-mini", provider: :openai}
        ]
      }

      config = %{
        compile_embed: false,
        overrides: %{
          providers: [],
          models: [],
          exclude: %{openai: ["gpt-3.5-turbo"]}
        },
        overrides_module: nil,
        allow: :all,
        deny: %{},
        prefer: []
      }

      with_packaged_snapshot(packaged_data, fn ->
        with_config(config, fn ->
          assert {:ok, snapshot} = Engine.run()

          assert map_size(snapshot.models_by_key) == 2
          assert snapshot.models_by_key[{:openai, "gpt-4o"}] != nil
          assert snapshot.models_by_key[{:openai, "gpt-4o-mini"}] != nil
          assert snapshot.models_by_key[{:openai, "gpt-3.5-turbo"}] == nil
        end)
      end)
    end

    test "exclude with glob patterns" do
      packaged_data = %{
        providers: [%{id: :openai, name: "OpenAI"}],
        models: [
          %{id: "gpt-4o", provider: :openai},
          %{id: "gpt-3.5-turbo", provider: :openai},
          %{id: "gpt-3-turbo", provider: :openai}
        ]
      }

      config = %{
        compile_embed: false,
        overrides: %{
          providers: [],
          models: [],
          exclude: %{openai: ["gpt-3*"]}
        },
        overrides_module: nil,
        allow: :all,
        deny: %{},
        prefer: []
      }

      with_packaged_snapshot(packaged_data, fn ->
        with_config(config, fn ->
          assert {:ok, snapshot} = Engine.run()

          assert map_size(snapshot.models_by_key) == 1
          assert snapshot.models_by_key[{:openai, "gpt-4o"}] != nil
          assert snapshot.models_by_key[{:openai, "gpt-3.5-turbo"}] == nil
          assert snapshot.models_by_key[{:openai, "gpt-3-turbo"}] == nil
        end)
      end)
    end

    test "filter application with allow patterns" do
      packaged_data = %{
        providers: [
          %{id: :openai, name: "OpenAI"},
          %{id: :anthropic, name: "Anthropic"}
        ],
        models: [
          %{id: "gpt-4o", provider: :openai},
          %{id: "claude-3-opus", provider: :anthropic}
        ]
      }

      config = %{
        compile_embed: false,
        overrides: %{providers: [], models: [], exclude: %{}},
        overrides_module: nil,
        allow: %{openai: ["gpt-*"]},
        deny: %{},
        prefer: []
      }

      with_packaged_snapshot(packaged_data, fn ->
        with_config(config, fn ->
          assert {:ok, snapshot} = Engine.run()

          assert map_size(snapshot.models_by_key) == 1
          assert snapshot.models_by_key[{:openai, "gpt-4o"}] != nil
          assert snapshot.models_by_key[{:anthropic, "claude-3-opus"}] == nil
        end)
      end)
    end

    test "filter application with deny patterns" do
      packaged_data = %{
        providers: [%{id: :openai, name: "OpenAI"}],
        models: [
          %{id: "gpt-4o", provider: :openai},
          %{id: "gpt-3.5-turbo", provider: :openai}
        ]
      }

      config = %{
        compile_embed: false,
        overrides: %{providers: [], models: [], exclude: %{}},
        overrides_module: nil,
        allow: :all,
        deny: %{openai: ["gpt-3*"]},
        prefer: []
      }

      with_packaged_snapshot(packaged_data, fn ->
        with_config(config, fn ->
          assert {:ok, snapshot} = Engine.run()

          assert map_size(snapshot.models_by_key) == 1
          assert snapshot.models_by_key[{:openai, "gpt-4o"}] != nil
          assert snapshot.models_by_key[{:openai, "gpt-3.5-turbo"}] == nil
        end)
      end)
    end

    test "deny wins over allow" do
      packaged_data = %{
        providers: [%{id: :openai, name: "OpenAI"}],
        models: [
          %{id: "gpt-4o", provider: :openai},
          %{id: "gpt-3.5-turbo", provider: :openai}
        ]
      }

      config = %{
        compile_embed: false,
        overrides: %{providers: [], models: [], exclude: %{}},
        overrides_module: nil,
        allow: :all,
        deny: %{openai: ["gpt-4o"]},
        prefer: []
      }

      with_packaged_snapshot(packaged_data, fn ->
        with_config(config, fn ->
          assert {:ok, snapshot} = Engine.run()

          assert map_size(snapshot.models_by_key) == 1
          assert snapshot.models_by_key[{:openai, "gpt-3.5-turbo"}] != nil
          assert snapshot.models_by_key[{:openai, "gpt-4o"}] == nil
        end)
      end)
    end

    test "invalid data is dropped" do
      packaged_data = %{
        providers: [
          %{id: :openai, name: "OpenAI"},
          %{name: "Missing ID"}
        ],
        models: [
          %{id: "gpt-4o", provider: :openai},
          %{id: 123, provider: :openai},
          %{provider: :openai}
        ]
      }

      config = %{
        compile_embed: false,
        overrides: %{providers: [], models: [], exclude: %{}},
        overrides_module: nil,
        allow: :all,
        deny: %{},
        prefer: []
      }

      with_packaged_snapshot(packaged_data, fn ->
        with_config(config, fn ->
          assert {:ok, snapshot} = Engine.run()

          assert map_size(snapshot.providers_by_id) == 1
          assert snapshot.providers_by_id[:openai] != nil

          assert map_size(snapshot.models_by_key) == 1
          assert snapshot.models_by_key[{:openai, "gpt-4o"}] != nil
        end)
      end)
    end

    test "empty catalog returns error" do
      packaged_data = %{
        providers: [],
        models: []
      }

      config = %{
        compile_embed: false,
        overrides: %{providers: [], models: [], exclude: %{}},
        overrides_module: nil,
        allow: :all,
        deny: %{},
        prefer: []
      }

      with_packaged_snapshot(packaged_data, fn ->
        with_config(config, fn ->
          assert {:error, :empty_catalog} = Engine.run()
        end)
      end)
    end

    test "enrichment adds family and provider_model_id" do
      packaged_data = %{
        providers: [%{id: :openai, name: "OpenAI"}],
        models: [%{id: "gpt-4o-mini", provider: :openai}]
      }

      config = %{
        compile_embed: false,
        overrides: %{providers: [], models: [], exclude: %{}},
        overrides_module: nil,
        allow: :all,
        deny: %{},
        prefer: []
      }

      with_packaged_snapshot(packaged_data, fn ->
        with_config(config, fn ->
          assert {:ok, snapshot} = Engine.run()

          model = snapshot.models_by_key[{:openai, "gpt-4o-mini"}]
          assert model.family == "gpt-4o"
          assert model.provider_model_id == "gpt-4o-mini"
        end)
      end)
    end

    test "models are grouped by provider" do
      packaged_data = %{
        providers: [
          %{id: :openai, name: "OpenAI"},
          %{id: :anthropic, name: "Anthropic"}
        ],
        models: [
          %{id: "gpt-4o", provider: :openai},
          %{id: "gpt-3.5-turbo", provider: :openai},
          %{id: "claude-3-opus", provider: :anthropic}
        ]
      }

      config = %{
        compile_embed: false,
        overrides: %{providers: [], models: [], exclude: %{}},
        overrides_module: nil,
        allow: :all,
        deny: %{},
        prefer: []
      }

      with_packaged_snapshot(packaged_data, fn ->
        with_config(config, fn ->
          assert {:ok, snapshot} = Engine.run()

          assert length(snapshot.models[:openai]) == 2
          assert length(snapshot.models[:anthropic]) == 1
        end)
      end)
    end
  end

  describe "build_indexes/2" do
    test "builds providers_by_id index" do
      providers = [
        %{id: :openai, name: "OpenAI"},
        %{id: :anthropic, name: "Anthropic"}
      ]

      indexes = Engine.build_indexes(providers, [])

      assert map_size(indexes.providers_by_id) == 2
      assert indexes.providers_by_id[:openai].name == "OpenAI"
      assert indexes.providers_by_id[:anthropic].name == "Anthropic"
    end

    test "builds models_by_key index" do
      models = [
        %{id: "gpt-4o", provider: :openai},
        %{id: "claude-3-opus", provider: :anthropic}
      ]

      indexes = Engine.build_indexes([], models)

      assert map_size(indexes.models_by_key) == 2
      assert indexes.models_by_key[{:openai, "gpt-4o"}].id == "gpt-4o"
      assert indexes.models_by_key[{:anthropic, "claude-3-opus"}].id == "claude-3-opus"
    end

    test "builds models_by_provider index" do
      models = [
        %{id: "gpt-4o", provider: :openai},
        %{id: "gpt-3.5-turbo", provider: :openai},
        %{id: "claude-3-opus", provider: :anthropic}
      ]

      indexes = Engine.build_indexes([], models)

      assert length(indexes.models_by_provider[:openai]) == 2
      assert length(indexes.models_by_provider[:anthropic]) == 1
    end

    test "builds aliases_by_key index" do
      models = [
        %{id: "gpt-4o", provider: :openai, aliases: ["gpt4o", "gpt-4-omni"]},
        %{id: "claude-3-opus", provider: :anthropic, aliases: ["claude-opus"]}
      ]

      indexes = Engine.build_indexes([], models)

      assert indexes.aliases_by_key[{:openai, "gpt4o"}] == "gpt-4o"
      assert indexes.aliases_by_key[{:openai, "gpt-4-omni"}] == "gpt-4o"
      assert indexes.aliases_by_key[{:anthropic, "claude-opus"}] == "claude-3-opus"
    end
  end

  describe "apply_filters/2" do
    test "allows all when filter is :all" do
      models = [
        %{id: "gpt-4o", provider: :openai},
        %{id: "claude-3-opus", provider: :anthropic}
      ]

      filters = %{allow: :all, deny: %{}}

      result = Engine.apply_filters(models, filters)

      assert length(result) == 2
    end

    test "filters by allow patterns" do
      models = [
        %{id: "gpt-4o", provider: :openai},
        %{id: "claude-3-opus", provider: :anthropic}
      ]

      allow_patterns = %{openai: [~r/^gpt-4.*$/]}
      filters = %{allow: allow_patterns, deny: %{}}

      result = Engine.apply_filters(models, filters)

      assert length(result) == 1
      assert Enum.find(result, &(&1.id == "gpt-4o"))
    end

    test "filters by deny patterns" do
      models = [
        %{id: "gpt-4o", provider: :openai},
        %{id: "gpt-3.5-turbo", provider: :openai}
      ]

      deny_patterns = %{openai: [~r/^gpt-3.*$/]}
      filters = %{allow: :all, deny: deny_patterns}

      result = Engine.apply_filters(models, filters)

      assert length(result) == 1
      assert Enum.find(result, &(&1.id == "gpt-4o"))
    end

    test "deny wins over allow" do
      models = [%{id: "gpt-4o", provider: :openai}]

      allow_patterns = %{openai: [~r/^gpt.*$/]}
      deny_patterns = %{openai: [~r/^gpt-4.*$/]}
      filters = %{allow: allow_patterns, deny: deny_patterns}

      result = Engine.apply_filters(models, filters)

      assert length(result) == 0
    end
  end

  describe "build_aliases_index/1" do
    test "creates alias mappings to canonical IDs" do
      models = [
        %{id: "gpt-4o", provider: :openai, aliases: ["gpt4o", "gpt-4-omni"]},
        %{id: "claude-3-opus", provider: :anthropic, aliases: ["claude-opus"]}
      ]

      result = Engine.build_aliases_index(models)

      assert result[{:openai, "gpt4o"}] == "gpt-4o"
      assert result[{:openai, "gpt-4-omni"}] == "gpt-4o"
      assert result[{:anthropic, "claude-opus"}] == "claude-3-opus"
    end

    test "handles models without aliases" do
      models = [
        %{id: "gpt-4o", provider: :openai, aliases: []},
        %{id: "claude-3-opus", provider: :anthropic}
      ]

      result = Engine.build_aliases_index(models)

      assert map_size(result) == 0
    end

    test "handles empty model list" do
      result = Engine.build_aliases_index([])

      assert map_size(result) == 0
    end
  end

  describe "integration tests" do
    test "real-world scenario with multiple sources and filters" do
      packaged_data = %{
        providers: [
          %{id: :openai, name: "OpenAI", base_url: "https://api.openai.com"},
          %{id: :anthropic, name: "Anthropic"}
        ],
        models: [
          %{id: "gpt-4o", provider: :openai, aliases: ["gpt4o"]},
          %{id: "gpt-4o-mini", provider: :openai},
          %{id: "gpt-3.5-turbo", provider: :openai},
          %{id: "claude-3-opus", provider: :anthropic, aliases: ["claude-opus"]},
          %{id: "claude-3-sonnet", provider: :anthropic}
        ]
      }

      config = %{
        compile_embed: false,
        overrides: %{
          providers: [%{id: :openai, doc: "Updated docs"}],
          models: [%{id: "gpt-4o", provider: :openai, name: "GPT-4 Omni"}],
          exclude: %{openai: ["gpt-3*"]}
        },
        overrides_module: nil,
        allow: :all,
        deny: %{anthropic: ["*-sonnet"]},
        prefer: [:openai]
      }

      with_packaged_snapshot(packaged_data, fn ->
        with_config(config, fn ->
          assert {:ok, snapshot} = Engine.run()

          assert snapshot.providers_by_id[:openai].doc == "Updated docs"

          assert map_size(snapshot.models_by_key) == 3

          assert snapshot.models_by_key[{:openai, "gpt-4o"}].name == "GPT-4 Omni"
          assert snapshot.models_by_key[{:openai, "gpt-4o-mini"}] != nil
          assert snapshot.models_by_key[{:anthropic, "claude-3-opus"}] != nil

          assert snapshot.models_by_key[{:openai, "gpt-3.5-turbo"}] == nil
          assert snapshot.models_by_key[{:anthropic, "claude-3-sonnet"}] == nil

          assert snapshot.aliases_by_key[{:openai, "gpt4o"}] == "gpt-4o"
          assert snapshot.aliases_by_key[{:anthropic, "claude-opus"}] == "claude-3-opus"

          assert snapshot.prefer == [:openai]

          assert snapshot.models[:openai] |> Enum.all?(fn m -> m.family != nil end)
        end)
      end)
    end
  end

  # Test helpers

  defp with_packaged_snapshot(data, fun) do
    Application.put_env(:llm_models, :test_packaged_snapshot, data)

    try do
      :meck.new(LlmModels.Packaged, [:passthrough])
      :meck.expect(LlmModels.Packaged, :snapshot, fn -> data end)

      fun.()
    after
      :meck.unload(LlmModels.Packaged)
      Application.delete_env(:llm_models, :test_packaged_snapshot)
    end
  end

  defp with_config(config, fun) do
    Application.put_env(:llm_models, :test_config, config)

    try do
      :meck.new(LlmModels.Config, [:passthrough])
      :meck.expect(LlmModels.Config, :get, fn -> config end)

      fun.()
    after
      :meck.unload(LlmModels.Config)
      Application.delete_env(:llm_models, :test_config)
    end
  end
end
