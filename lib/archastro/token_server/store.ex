# Copyright (c) 2026 ArchAstro Inc. Licensed under the MIT License.

defmodule ArchAstro.TokenServer.Store do
  @moduledoc "Optional durable backing store for the default ETS TokenServer."
  @type store_ref :: GenServer.server() | struct() | ArchAstro.JSON.t()
  @callback load(store_ref(), String.t()) ::
              {:ok, ArchAstro.Auth.TokenSet.t()}
              | :not_found
              | {:error, ArchAstro.Error.reason()}
  @callback save(store_ref(), String.t(), ArchAstro.Auth.TokenSet.t()) ::
              :ok | {:error, ArchAstro.Error.reason()}
  @callback delete(store_ref(), String.t()) :: :ok | {:error, ArchAstro.Error.reason()}
end
