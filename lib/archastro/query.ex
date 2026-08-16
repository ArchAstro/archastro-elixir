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
      # A nil param means "not provided", never the string "null". The
      # sentinel still arrives un-rewritten from Codec.encode's
      # Map.from_struct fallback (structs without to_map/1).
      {_key, value} when value in [nil, :__archastro_unset__] ->
        []

      {key, values} when is_list(values) ->
        for value <- values, value not in [nil, :__archastro_unset__], do: {key, scalar(value)}

      {key, item} ->
        [{key, scalar(item)}]
    end)
    |> URI.encode_query()
  end

  defp scalar(value) when is_binary(value), do: value
  defp scalar(value) when is_boolean(value) or is_number(value), do: to_string(value)
  defp scalar(value) when is_map(value) or is_list(value), do: Jason.encode!(value)
end
