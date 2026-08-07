# Copyright (c) 2026 ArchAstro Inc. Licensed under the MIT License.

defmodule ArchAstro.Unset do
  @moduledoc "Sentinel used to distinguish an omitted JSON field from an explicit null."
  @type t :: :__archastro_unset__
  @spec value() :: t()
  def value, do: :__archastro_unset__
end
