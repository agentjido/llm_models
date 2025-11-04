# LlmModels

[![Hex.pm](https://img.shields.io/hexpm/v/llm_models.svg)](https://hex.pm/packages/llm_models)
[![License](https://img.shields.io/hexpm/l/llm_models.svg)](https://github.com/yourorg/llm_models/blob/main/LICENSE)

Fast, persistent_term-backed LLM model metadata catalog with explicit refresh controls.

`llm_models` provides a standalone, capability-aware query API for LLM model metadata. It ships with a packaged snapshot, supports manual refresh from [models.dev](https://models.dev), and offers O(1) lock-free queries backed by `:persistent_term`.

## Overview

`llm_models` centralizes model metadata lifecycle (ingest → normalize → validate → enrich → index → publish) behind a simple, reusable library designed for Elixir AI applications like ReqLLM.

### Why LlmModels?

- **Packaged snapshot**: Ships with model data embedded at compile time—no network required by default
- **Fast queries**: O(1), lock-free reads via `:persistent_term`
- **Explicit refresh**: Manual updates only via Mix tasks (`mix llm_models.pull`, `mix llm_models.activate`)
- **Capability-based selection**: Find models by features (tools, JSON mode, streaming, etc.)
- **Canonical spec parsing**: Owns "provider:model" format parsing and resolution
- **Flexible overrides**: Configure via `config.exs` or custom behaviour modules

### Key Features

- **No magic**: Stability-first design with explicit semantics
- **Simple allow/deny filtering**: Control which models are available
- **Precedence rules**: Packaged snapshot < config overrides < behaviour overrides
- **Forward compatible**: Unknown upstream keys pass through to `extra` field
- **Minimal dependencies**: Only `zoi` (validation) and `jason` (JSON)

## Installation

Add `llm_models` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:llm_models, "~> 0.1.0"}
  ]
end
```

## Quick Start

```elixir
# Load the catalog (run once at startup)
{:ok, _snapshot} = LlmModels.load()

# List available providers
[:anthropic, :openai, :google_vertex] = LlmModels.list_providers()

# Find models with specific capabilities
{:ok, {:openai, "gpt-4o-mini"}} = LlmModels.select(
  require: [chat: true, tools: true, json_native: true],
  prefer: [:openai, :anthropic]
)

# Parse and resolve model specs
{:ok, {:openai, "gpt-4o-mini"}} = LlmModels.parse_spec("openai:gpt-4o-mini")
{:ok, {provider, id, model}} = LlmModels.resolve("openai:gpt-4o-mini")

# Check capabilities
caps = LlmModels.capabilities({:openai, "gpt-4o-mini"})
caps.tools.enabled       #=> true
caps.json.native         #=> true
caps.streaming.text      #=> true
```

## Usage

### Loading the Catalog

The catalog must be loaded before querying. Typically done once at application startup:

```elixir
# Load with defaults
{:ok, snapshot} = LlmModels.load()

# Reload with last-known options
:ok = LlmModels.reload()

# Get current snapshot
snapshot = LlmModels.snapshot()

# Get current epoch (increments on each load)
epoch = LlmModels.epoch()
```

### Querying Providers

```elixir
# List all providers
providers = LlmModels.list_providers()
#=> [:anthropic, :google_vertex, :openai]

# Get provider metadata
{:ok, provider} = LlmModels.get_provider(:openai)
provider.name        #=> "OpenAI"
provider.base_url    #=> "https://api.openai.com"
provider.env         #=> ["OPENAI_API_KEY"]
```

### Querying Models

```elixir
# List all models for a provider
models = LlmModels.list_models(:openai)

# Filter by required capabilities
models = LlmModels.list_models(:openai,
  require: [tools: true, json_native: true]
)

# Exclude models with specific capabilities
models = LlmModels.list_models(:openai,
  require: [tools: true],
  forbid: [streaming_tool_calls: true]
)

# Get a specific model
{:ok, model} = LlmModels.get_model(:openai, "gpt-4o-mini")
model.id                    #=> "gpt-4o-mini"
model.provider              #=> :openai
model.family                #=> "gpt-4o"
model.limits.context        #=> 128000
model.limits.output         #=> 16384
model.cost.input            #=> 0.15 (per 1M tokens)
model.cost.output           #=> 0.60 (per 1M tokens)
```

### Model Selection

Find the best model matching your criteria:

```elixir
# Select with capability requirements
{:ok, {provider, model_id}} = LlmModels.select(
  require: [chat: true, tools: true, json_native: true],
  prefer: [:openai, :anthropic]
)

# Select from specific provider
{:ok, {provider, model_id}} = LlmModels.select(
  require: [tools: true],
  scope: :openai
)

# Select with forbidden capabilities
{:ok, {provider, model_id}} = LlmModels.select(
  require: [chat: true],
  forbid: [streaming_tool_calls: true],
  prefer: [:anthropic]
)

# Handle no match
case LlmModels.select(require: [impossible: true]) do
  {:ok, {provider, model_id}} -> # use model
  {:error, :no_match} -> # fallback
end
```

**Supported capability keys:**

- `:chat` - Chat completion support
- `:embeddings` - Embeddings support
- `:reasoning` - Extended reasoning capability
- `:tools` - Tool/function calling
- `:tools_streaming` - Streaming tool calls
- `:tools_strict` - Strict tool schemas
- `:tools_parallel` - Parallel tool execution
- `:json_native` - Native JSON mode
- `:json_schema` - JSON schema support
- `:json_strict` - Strict JSON mode
- `:streaming_text` - Text streaming
- `:streaming_tool_calls` - Tool call streaming

### Spec Parsing

Parse and resolve model specifications:

```elixir
# Parse provider identifier
{:ok, :openai} = LlmModels.parse_provider("openai")
{:ok, :google_vertex} = LlmModels.parse_provider("google-vertex")
{:error, :unknown_provider} = LlmModels.parse_provider("invalid")

# Parse "provider:model" spec
{:ok, {:openai, "gpt-4o-mini"}} = LlmModels.parse_spec("openai:gpt-4o-mini")
{:error, :invalid_format} = LlmModels.parse_spec("no-colon")

# Resolve spec to full model record
{:ok, {provider, id, model}} = LlmModels.resolve("openai:gpt-4o-mini")
{:ok, {provider, id, model}} = LlmModels.resolve({:openai, "gpt-4o-mini"})

# Resolve with scope (bare model ID)
{:ok, {provider, id, model}} = LlmModels.resolve("gpt-4o-mini", scope: :openai)

# Handle aliases
{:ok, {provider, id, model}} = LlmModels.resolve("openai:gpt-4-mini")
# Returns canonical ID "gpt-4o-mini"
```

### Checking Availability

Use allow/deny filters to control model availability:

```elixir
# Check if a model is allowed
true = LlmModels.allowed?({:openai, "gpt-4o-mini"})
false = LlmModels.allowed?({:openai, "gpt-5-pro"})  # if denied

# Works with spec strings too
true = LlmModels.allowed?("openai:gpt-4o-mini")
```

## Configuration

Configure `llm_models` in your `config/config.exs`:

```elixir
config :llm_models,
  # Embed snapshot at compile time (default: true)
  compile_embed: true,
  
  # Provider and model overrides
  overrides: %{
    providers: [
      %{id: :openai, env: ["OPENAI_API_KEY"]},
      %{id: :anthropic, env: ["ANTHROPIC_API_KEY"]}
    ],
    models: [
      %{
        id: "gpt-4o-mini",
        provider: :openai,
        capabilities: %{
          tools: %{enabled: true, streaming: false},
          json: %{native: true}
        }
      }
    ],
    # Exclude specific models (supports glob patterns)
    exclude: %{
      openai: ["gpt-5-pro", "o3-*"],
      anthropic: ["claude-instant-*"]
    }
  },
  
  # Custom overrides module (see below)
  overrides_module: MyApp.LlmModelOverrides,
  
  # Global allow/deny filters
  allow: %{
    openai: :all,
    anthropic: ["claude-3-*", "claude-4-*"]
  },
  deny: %{
    openai: ["*-preview"]
  },
  
  # Provider preference order
  prefer: [:openai, :anthropic, :google_vertex]
```

### Precedence Rules

Sources are merged in this order (later wins):

1. **Packaged snapshot** (bundled in `priv/llm_models/snapshot.json`)
2. **Config overrides** (`:llm_models, :overrides`)
3. **Behaviour overrides** (`:llm_models, :overrides_module`)

For maps, fields are deep-merged. For lists, values are deduplicated. For scalars, higher precedence wins.

**Deny always wins over allow.**

## Custom Overrides

For more control, implement the `LlmModels.Overrides` behaviour:

```elixir
defmodule MyApp.LlmModelOverrides do
  use LlmModels.Overrides
  
  @impl true
  def providers do
    [
      %{id: :openai, env: ["OPENAI_API_KEY"], base_url: "https://api.openai.com"},
      %{id: :custom_provider, env: ["CUSTOM_API_KEY"], base_url: "https://custom.ai"}
    ]
  end
  
  @impl true
  def models do
    [
      %{
        id: "gpt-4o-mini",
        provider: :openai,
        capabilities: %{
          tools: %{enabled: true, streaming: false},
          json: %{native: true, schema: true}
        }
      },
      %{
        id: "custom-model",
        provider: :custom_provider,
        capabilities: %{chat: true}
      }
    ]
  end
  
  @impl true
  def excludes do
    %{
      openai: ["gpt-5-pro", "o3-*"],
      anthropic: ["claude-instant-*"]
    }
  end
end
```

Then configure the module:

```elixir
config :llm_models, overrides_module: MyApp.LlmModelOverrides
```

The `use LlmModels.Overrides` macro provides default implementations (empty lists/maps), so you only need to override what you need.

## Updating Model Data

Model data is packaged at compile time by default. To update:

### 1. Fetch Latest Data

```bash
# Fetch from models.dev
mix llm_models.pull

# Fetch from custom URL
mix llm_models.pull --url https://custom.source/api.json

# Fetch to custom location
mix llm_models.pull --out priv/llm_models/upstream.json
```

This downloads and caches the upstream data to `priv/llm_models/upstream.json`.

### 2. Activate the Update

```bash
# Process and package the fetched data
mix llm_models.activate

# Activate from custom source
mix llm_models.activate --from priv/llm_models/upstream.json
```

This validates, normalizes, and writes `priv/llm_models/snapshot.json`.

### 3. Reload (Development) or Recompile (Production)

**Development:**
```elixir
# Reload in development without recompiling
LlmModels.reload()
```

**Production:**
```bash
# Recompile to pick up new snapshot
mix compile --force
```

When `compile_embed: true`, the snapshot is embedded at compile time via `@external_resource`, so changes trigger automatic recompilation.

## Architecture

### ETL Pipeline

The catalog is built through a seven-stage pipeline:

1. **Ingest** - Load from packaged snapshot, config overrides, behaviour overrides
2. **Normalize** - Convert provider IDs to atoms, standardize dates and formats
3. **Validate** - Validate via Zoi schemas, drop invalid entries
4. **Merge** - Apply precedence rules (deep merge maps, dedupe lists)
5. **Enrich** - Derive `family` from model ID, apply capability defaults
6. **Filter** - Apply global allow/deny patterns
7. **Index + Publish** - Build indexes and publish to `:persistent_term`

### Storage

- **Compile-time embedding**: Snapshot is read at compile time when `compile_embed: true` (default)
- **Runtime loading**: `LlmModels.load/1` merges sources and publishes to `:persistent_term`
- **Reads**: All queries use `:persistent_term.get(:llm_models_snapshot)` for O(1), lock-free access
- **No ETS**: Simpler and faster with `:persistent_term`

### Data Structures

Internally, the snapshot contains:

- `providers_by_id` - Map of provider atoms to provider metadata
- `models` - Map of provider atoms to lists of models
- `models_by_key` - Map of `{provider, id}` tuples to model records
- `aliases_by_key` - Map of `{provider, alias}` to canonical model IDs
- `filters` - Compiled allow/deny patterns

## Integration with ReqLLM

`llm_models` was designed to power ReqLLM but can be used standalone:

```elixir
# In your application startup
defmodule MyApp.Application do
  use Application
  
  def start(_type, _args) do
    # Load the catalog
    {:ok, _} = LlmModels.load()
    
    children = [
      # Your other children...
    ]
    
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

In ReqLLM integration:

```elixir
# Use LlmModels for provider registry
{:ok, {provider, id, model}} = LlmModels.resolve("openai:gpt-4o-mini")

# Check capabilities
caps = LlmModels.capabilities({provider, id})

# Select best model
{:ok, {provider, id}} = LlmModels.select(
  require: [tools: true, streaming_text: true],
  prefer: [:openai]
)
```

## API Reference

### Main Module: `LlmModels`

**Lifecycle:**
- `load/1` - Load catalog and publish to persistent_term
- `reload/0` - Reload using last-known options
- `snapshot/0` - Get current snapshot
- `epoch/0` - Get current epoch

**Lookup and Listing:**
- `list_providers/0` - List all provider atoms
- `get_provider/1` - Get provider metadata
- `list_models/2` - List models with filters
- `get_model/2` - Get specific model
- `capabilities/1` - Get model capabilities
- `allowed?/1` - Check if model passes filters

**Selection:**
- `select/1` - Select model by capability requirements

**Spec Parsing:**
- `parse_provider/1` - Parse provider identifier
- `parse_spec/1` - Parse "provider:model" spec
- `resolve/2` - Resolve spec to model record

### Behaviour: `LlmModels.Overrides`

**Callbacks:**
- `providers/0` - Return provider overrides
- `models/0` - Return model overrides
- `excludes/0` - Return exclusion patterns

### Mix Tasks

- `mix llm_models.pull` - Fetch upstream data from models.dev
- `mix llm_models.activate` - Process and package snapshot

## Design Principles

From the [design plan](LLM_MODELS_PLAN.md):

1. **Standalone with packaged snapshot** - No network required by default
2. **Manual refresh only** - Explicit updates via Mix tasks
3. **O(1) lock-free queries** - Fast reads via `:persistent_term`
4. **Simple allow/deny filtering** - Clear, compiled-once patterns
5. **Explicit semantics** - No magic, predictable behavior
6. **Stability first** - Remove over-engineering, focus on the 80% case

### Simplifications

- No per-field provenance in v1 (may add debug mode later)
- Dates stored as strings (`"YYYY-MM-DD"`)
- No DSL for overrides (use behaviour callbacks and plain maps)
- No schema version juggling (handled by code updates)
- Selection returns simple match or `:no_match`

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure `mix test` passes
5. Submit a pull request

## License

MIT License. See [LICENSE](LICENSE) for details.

---

For detailed architectural information, see [LLM_MODELS_PLAN.md](LLM_MODELS_PLAN.md).
