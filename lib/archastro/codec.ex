# Copyright (c) 2026 ArchAstro Inc. Licensed under the MIT License.

defmodule ArchAstro.SDK.Codec do
  @moduledoc """
  Converts between ArchAstro structs and their JSON wire representations.

  Generated resource and channel modules use descriptor values to validate and
  decode nested API payloads. Most applications use those generated modules
  rather than calling this low-level codec directly.
  """

  @type descriptor ::
          :void
          | :unknown
          | :string
          | :integer
          | :float
          | :boolean
          | :datetime
          | {:list, descriptor()}
          | {:map, descriptor()}
          | {:ref, module()}
          | {:enum, [String.t()]}
          | {:union, [descriptor()]}
          | {:union, [descriptor()], {String.t(), %{optional(String.t()) => module()}}}
          | {:nullable, descriptor()}
          | {:optional, descriptor()}
          | {:object, [{String.t(), descriptor()}]}

  @type field_descriptor :: {atom(), {String.t(), descriptor()}}

  @spec struct_from_map(module(), ArchAstro.SDK.JSON.object(), [field_descriptor()]) :: struct()
  def struct_from_map(module, data, fields) when is_map(data) do
    unless matches?(data, {:object, Keyword.values(fields)}) do
      raise ArgumentError, "response does not match required fields for #{inspect(module)}"
    end

    values =
      Enum.reduce(fields, %{}, fn {field, {wire, descriptor}}, acc ->
        case Map.fetch(data, wire) do
          {:ok, value} -> Map.put(acc, field, decode(value, descriptor))
          :error -> acc
        end
      end)

    struct(module, values)
  end

  @spec struct_to_map(struct(), [field_descriptor()]) :: ArchAstro.SDK.JSON.object()
  def struct_to_map(value, fields) do
    Enum.reduce(fields, %{}, fn {field, {wire, _descriptor}}, acc ->
      put_optional(acc, wire, Map.fetch!(value, field))
    end)
  end

  @spec put_optional(
          ArchAstro.SDK.JSON.object(),
          String.t(),
          ArchAstro.SDK.JSON.t() | ArchAstro.SDK.Unset.t() | struct()
        ) :: ArchAstro.SDK.JSON.object()
  def put_optional(map, _key, :__archastro_unset__), do: map
  def put_optional(map, key, value), do: Map.put(map, key, encode(value))

  @spec encode(
          ArchAstro.SDK.JSON.t()
          | ArchAstro.SDK.Unset.t()
          | struct()
          | Date.t()
          | DateTime.t()
        ) ::
          ArchAstro.SDK.JSON.t()
  def encode(:__archastro_unset__), do: nil
  def encode(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def encode(%Date{} = value), do: Date.to_iso8601(value)

  def encode(%NaiveDateTime{} = value) do
    raise ArgumentError,
          "cannot encode NaiveDateTime #{inspect(value)}: the API requires an " <>
            "ISO 8601 datetime with a UTC offset; convert it with " <>
            "DateTime.from_naive!(value, \"Etc/UTC\") first"
  end

  def encode(%Time{} = value) do
    raise ArgumentError,
          "cannot encode Time #{inspect(value)}: the API has no time-of-day wire " <>
            "format; send a full DateTime instead"
  end

  def encode(%module{} = value) do
    if Code.ensure_loaded?(module) and function_exported?(module, :to_map, 1),
      do: module.to_map(value),
      else: Map.from_struct(value)
  end

  def encode(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), encode(item)} end)

  def encode(value) when is_list(value), do: Enum.map(value, &encode/1)
  def encode(value), do: value

  @spec decode(ArchAstro.SDK.JSON.t(), descriptor()) ::
          ArchAstro.SDK.JSON.t() | struct() | DateTime.t() | :ok
  def decode(_value, :void), do: :ok
  def decode(value, :unknown), do: value
  def decode(value, :string) when is_binary(value), do: value
  def decode(value, :integer) when is_integer(value), do: value
  def decode(value, :float) when is_float(value) or is_integer(value), do: value
  def decode(value, :boolean) when is_boolean(value), do: value

  def decode(value, :datetime) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> raise ArgumentError, "response is not an ISO 8601 datetime"
    end
  end

  def decode(nil, {:nullable, _}), do: nil
  def decode(value, {:nullable, descriptor}), do: decode(value, descriptor)
  def decode(value, {:optional, descriptor}), do: decode(value, descriptor)

  def decode(value, {:list, descriptor}) when is_list(value),
    do: Enum.map(value, &decode(&1, descriptor))

  def decode(value, {:map, descriptor}) when is_map(value),
    do: Map.new(value, fn {k, v} -> {k, decode(v, descriptor)} end)

  def decode(value, {:ref, module}) when is_map(value), do: module.from_map(value)

  def decode(value, {:enum, values}) do
    if value in values,
      do: value,
      else: raise(ArgumentError, "response does not match enum values")
  end

  def decode(value, {:union, _descriptors, {property, mapping}}) when is_map(value) do
    case mapping[Map.get(value, property)] do
      nil ->
        raise ArgumentError,
              "response discriminator #{inspect(property)} does not select a known union variant"

      module ->
        module.from_map(value)
    end
  end

  def decode(value, {:union, descriptors}), do: decode_union(value, descriptors)

  def decode(:ok, {:object, []}), do: :ok

  def decode(value, {:object, fields}) when is_map(value) do
    unless matches?(value, {:object, fields}) do
      raise ArgumentError, "response does not match required object fields"
    end

    Enum.reduce(fields, %{}, fn {wire, descriptor}, decoded ->
      case Map.fetch(value, wire) do
        {:ok, item} -> Map.put(decoded, wire, decode(item, descriptor))
        :error -> decoded
      end
    end)
  end

  def decode(_value, descriptor) do
    raise ArgumentError, "response does not match #{inspect(descriptor)}"
  end

  @spec matches?(ArchAstro.SDK.JSON.t(), descriptor()) :: boolean()
  def matches?(_value, :unknown), do: true
  def matches?(value, :string), do: is_binary(value)
  def matches?(value, :integer), do: is_integer(value)
  def matches?(value, :float), do: is_float(value) or is_integer(value)
  def matches?(value, :boolean), do: is_boolean(value)

  def matches?(value, :datetime) when is_binary(value) do
    match?({:ok, %DateTime{}, _offset}, DateTime.from_iso8601(value))
  end

  def matches?(_value, :datetime), do: false

  def matches?(value, {:list, descriptor}) when is_list(value),
    do: Enum.all?(value, &matches?(&1, descriptor))

  def matches?(_value, {:list, _descriptor}), do: false

  def matches?(value, {:map, descriptor}) when is_map(value),
    do: Enum.all?(value, fn {_key, item} -> matches?(item, descriptor) end)

  def matches?(_value, {:map, _descriptor}), do: false

  def matches?(value, {:ref, module}) when is_atom(module),
    do:
      Code.ensure_loaded?(module) and function_exported?(module, :matches?, 1) and
        module.matches?(value)

  def matches?(value, {:enum, values}), do: value in values
  def matches?(value, {:union, descriptors}), do: Enum.any?(descriptors, &matches?(value, &1))

  def matches?(value, {:union, _descriptors, {property, mapping}}) when is_map(value) do
    case mapping[Map.get(value, property)] do
      nil -> false
      module -> matches?(value, {:ref, module})
    end
  end

  def matches?(_value, {:union, _descriptors, _discriminator}), do: false
  def matches?(nil, {:nullable, _descriptor}), do: true
  def matches?(value, {:nullable, descriptor}), do: matches?(value, descriptor)
  def matches?(value, {:optional, descriptor}), do: matches?(value, descriptor)

  def matches?(value, {:object, fields}) when is_map(value) do
    Enum.all?(fields, fn {wire, descriptor} ->
      optional = match?({:optional, _}, descriptor)

      case Map.fetch(value, wire) do
        {:ok, item} -> matches?(item, descriptor)
        :error -> optional
      end
    end)
  end

  def matches?(_value, {:object, _fields}), do: false
  def matches?(_value, :void), do: false

  defp decode_union(value, descriptors) do
    case Enum.find(descriptors, &matches?(value, &1)) do
      nil -> raise ArgumentError, "response does not match any union variant"
      descriptor -> decode(value, descriptor)
    end
  end
end
