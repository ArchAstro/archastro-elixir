# Copyright (c) 2026 ArchAstro Inc. Licensed under the MIT License.

defmodule ArchAstro.SDK.JSON do
  @moduledoc "Recursive types for values accepted by and decoded from JSON."

  @type scalar :: nil | boolean() | number() | String.t()
  @type object :: %{optional(String.t()) => t()}
  @type t :: scalar() | [t()] | object()
end
