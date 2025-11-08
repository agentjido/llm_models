defmodule LLMDb.Provider do
  @moduledoc """
  Provider struct with Zoi schema validation.

  Represents an LLM provider with metadata including identity, base URL,
  environment variables, and documentation.
  """

  @config_field_schema Zoi.object(%{
                         name: Zoi.string(),
                         type: Zoi.string(),
                         required: Zoi.boolean() |> Zoi.default(false),
                         default: Zoi.any() |> Zoi.optional(),
                         doc: Zoi.string() |> Zoi.optional()
                       })

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.atom(),
              name: Zoi.string() |> Zoi.optional(),
              base_url: Zoi.string() |> Zoi.optional(),
              env: Zoi.array(Zoi.string()) |> Zoi.optional(),
              config_schema: Zoi.array(@config_field_schema) |> Zoi.optional(),
              doc: Zoi.string() |> Zoi.optional(),
              exclude_models: Zoi.array(Zoi.string()) |> Zoi.default([]) |> Zoi.optional(),
              extra: Zoi.map() |> Zoi.optional()
            }, coerce: true)

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for Provider"
  def schema, do: @schema

  @doc """
  Creates a new Provider struct from a map, validating with Zoi schema.

  ## Examples

      iex> LLMDb.Provider.new(%{id: :openai, name: "OpenAI"})
      {:ok, %LLMDb.Provider{id: :openai, name: "OpenAI"}}

      iex> LLMDb.Provider.new(%{})
      {:error, _validation_errors}
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    Zoi.parse(@schema, attrs)
  end

  @doc """
  Creates a new Provider struct from a map, raising on validation errors.

  ## Examples

      iex> LLMDb.Provider.new!(%{id: :openai, name: "OpenAI"})
      %LLMDb.Provider{id: :openai, name: "OpenAI"}
  """
  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    case new(attrs) do
      {:ok, provider} -> provider
      {:error, reason} -> raise ArgumentError, "Invalid provider: #{inspect(reason)}"
    end
  end
end
