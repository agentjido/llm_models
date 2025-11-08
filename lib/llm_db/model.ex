defmodule LLMDb.Model do
  @moduledoc """
  Model struct with Zoi schema validation.

  Represents an LLM model with complete metadata including identity, provider,
  dates, limits, costs, modalities, capabilities, tags, deprecation status, and aliases.
  """

  require LLMDb.Schema.Capabilities
  require LLMDb.Schema.Cost
  require LLMDb.Schema.Limits

  @limits_schema LLMDb.Schema.Limits.schema()
  @cost_schema LLMDb.Schema.Cost.schema()
  @capabilities_schema LLMDb.Schema.Capabilities.schema()

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(),
              provider: Zoi.atom(),
              provider_model_id: Zoi.string() |> Zoi.optional(),
              name: Zoi.string() |> Zoi.optional(),
              family: Zoi.string() |> Zoi.optional(),
              release_date: Zoi.string() |> Zoi.optional(),
              last_updated: Zoi.string() |> Zoi.optional(),
              knowledge: Zoi.string() |> Zoi.optional(),
              limits: @limits_schema |> Zoi.optional(),
              cost: @cost_schema |> Zoi.optional(),
              modalities:
                Zoi.object(%{
                  input: Zoi.array(Zoi.atom()) |> Zoi.optional(),
                  output: Zoi.array(Zoi.atom()) |> Zoi.optional()
                })
                |> Zoi.optional(),
              capabilities: @capabilities_schema |> Zoi.optional(),
              tags: Zoi.array(Zoi.string()) |> Zoi.optional(),
              deprecated: Zoi.boolean() |> Zoi.default(false),
              aliases: Zoi.array(Zoi.string()) |> Zoi.default([]),
              extra: Zoi.map() |> Zoi.optional()
            }, coerce: true)

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for Model"
  def schema, do: @schema

  @doc """
  Creates a new Model struct from a map, validating with Zoi schema.

  ## Examples

      iex> LLMDb.Model.new(%{id: "gpt-4", provider: :openai})
      {:ok, %LLMDb.Model{id: "gpt-4", provider: :openai}}

      iex> LLMDb.Model.new(%{})
      {:error, _validation_errors}
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    Zoi.parse(@schema, attrs)
  end

  @doc """
  Creates a new Model struct from a map, raising on validation errors.

  ## Examples

      iex> LLMDb.Model.new!(%{id: "gpt-4", provider: :openai})
      %LLMDb.Model{id: "gpt-4", provider: :openai}
  """
  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    case new(attrs) do
      {:ok, model} -> model
      {:error, reason} -> raise ArgumentError, "Invalid model: #{inspect(reason)}"
    end
  end
end
