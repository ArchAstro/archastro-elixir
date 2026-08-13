# Copyright (c) 2026 ArchAstro Inc. Licensed under the MIT License.

defmodule ArchAstro.SDK.TokenServer.Store do
  @moduledoc "Optional durable backing store for the default ETS TokenServer."
  @type store_ref :: GenServer.server() | struct() | ArchAstro.SDK.JSON.t()
  @callback load(store_ref(), String.t()) ::
              {:ok, ArchAstro.SDK.Auth.TokenSet.t()}
              | :not_found
              | {:error, ArchAstro.SDK.Error.reason()}
  @callback save(store_ref(), String.t(), ArchAstro.SDK.Auth.TokenSet.t()) ::
              :ok | {:error, ArchAstro.SDK.Error.reason()}
  @callback delete(store_ref(), String.t()) :: :ok | {:error, ArchAstro.SDK.Error.reason()}
end
