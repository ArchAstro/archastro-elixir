# Copyright (c) 2026 ArchAstro Inc. Licensed under the MIT License.

defmodule ArchAstro.SDK.Query do
  @moduledoc false

  @spec append(String.t(), ArchAstro.SDK.JSON.object() | struct() | nil) :: String.t()
  def append(url, nil), do: url

  def append(url, value) do
    case encode(value) do
      "" -> url
      query -> url <> if(String.contains?(url, "?"), do: "&", else: "?") <> query
    end
  end

  @spec encode(ArchAstro.SDK.JSON.object() | struct()) :: String.t()
  def encode(value) do
    value
    |> ArchAstro.SDK.Codec.encode()
    |> Enum.flat_map(fn
      {_key, :__archastro_unset__} -> []
      {key, values} when is_list(values) -> Enum.map(values, &{key, scalar(&1)})
      {key, item} -> [{key, scalar(item)}]
    end)
    |> URI.encode_query()
  end

  defp scalar(nil), do: "null"
  defp scalar(value) when is_binary(value), do: value
  defp scalar(value) when is_boolean(value) or is_number(value), do: to_string(value)
  defp scalar(value) when is_map(value) or is_list(value), do: Jason.encode!(value)
end
