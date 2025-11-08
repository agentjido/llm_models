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
                         default: Zoi.any() |> Zoi.nullish(),
                         doc: Zoi.string() |> Zoi.nullish()
                       })

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.atom(),
              name: Zoi.string() |> Zoi.nullish(),
              base_url: Zoi.string() |> Zoi.nullish(),
              env: Zoi.array(Zoi.string()) |> Zoi.nullish(),
              config_schema: Zoi.array(@config_field_schema) |> Zoi.nullish(),
              doc: Zoi.string() |> Zoi.nullish(),
              exclude_models: Zoi.array(Zoi.string()) |> Zoi.default([]) |> Zoi.nullish(),
              extra: Zoi.map() |> Zoi.nullish()
            },
            coerce: true
          )

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

defimpl DeepMerge.Resolver, for: LLMDb.Provider do
  @moduledoc false

  def resolve(original, override = %LLMDb.Provider{}, resolver) do
    cleaned_override =
      override
      |> Map.from_struct()
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    Map.merge(original, cleaned_override, resolver)
  end

  def resolve(original, override, resolver) when is_map(override) do
    Map.merge(original, override, resolver)
  end

  def resolve(_original, override, _resolver), do: override
end
