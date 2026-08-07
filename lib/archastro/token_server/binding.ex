# Copyright (c) 2026 ArchAstro Inc. Licensed under the MIT License.

defmodule ArchAstro.TokenServer.Binding do
  @moduledoc "Opaque binding between an immutable client and a token-server scope."
  @enforce_keys [:provider, :value, :scope]
  defstruct [:provider, :value, :scope]

  @type t :: %__MODULE__{
          provider: module(),
          value: ArchAstro.TokenServer.provider_binding(),
          scope: ArchAstro.TokenServer.scope()
        }
end

defimpl Inspect, for: ArchAstro.TokenServer.Binding do
  def inspect(value, _opts),
    do:
      "#ArchAstro.TokenServer.Binding<provider: #{inspect(value.provider)}, scope: #{inspect(value.scope)}>"
end
