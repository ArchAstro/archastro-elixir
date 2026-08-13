# Copyright (c) 2026 ArchAstro Inc. Licensed under the MIT License.

defmodule ArchAstro.SDK.Path do
  @moduledoc false
  @type encodable :: String.t() | integer() | float() | atom()
  @spec encode(encodable()) :: String.t()
  def encode(value), do: value |> to_string() |> URI.encode(&URI.char_unreserved?/1)
end
