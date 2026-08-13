# Copyright (c) 2026 ArchAstro Inc. Licensed under the MIT License.

defmodule ArchAstro.SDK.TokenServer do
  @moduledoc """
  Behaviour and dispatch API for immutable-client credential providers.

  Implementations bind a client to an explicit credential scope. A secret-key
  provider must reject every session scope rather than falling back to its
  privileged server credential.
  """

  alias ArchAstro.SDK.Auth.TokenSet
  alias ArchAstro.SDK.TokenServer.Binding

  @type scope :: :server | :public | {:session, String.t()}
  @type server_ref :: GenServer.server()
  @type provider :: {:provider, module(), server_ref()}
  @type provider_binding :: server_ref() | {server_ref(), scope()} | struct()
  @type token_input :: TokenSet.t() | ArchAstro.SDK.JSON.object() | struct()

  @callback bind(server_ref(), scope()) ::
              {:ok, provider_binding()} | {:error, ArchAstro.SDK.Error.reason()}
  @callback authorization(provider_binding()) ::
              {:ok, ArchAstro.SDK.Authorization.t()} | {:error, ArchAstro.SDK.Error.reason()}
  @callback refresh_if_current(provider_binding(), non_neg_integer()) ::
              {:ok, ArchAstro.SDK.Authorization.t()} | {:error, ArchAstro.SDK.Error.reason()}
  @callback put_session(server_ref(), String.t(), TokenSet.t()) ::
              :ok | {:error, ArchAstro.SDK.Error.reason()}
  @callback delete_session(server_ref(), String.t()) :: :ok | {:error, ArchAstro.SDK.Error.reason()}

  @spec bind(provider() | server_ref(), scope()) ::
          {:ok, Binding.t()} | {:error, ArchAstro.SDK.Error.reason()}
  def bind({:provider, provider, server}, scope) when is_atom(provider) do
    with {:ok, value} <- provider.bind(server, scope) do
      {:ok, %Binding{provider: provider, value: value, scope: scope}}
    end
  end

  def bind(server, scope), do: bind({:provider, ArchAstro.SDK.TokenServer.Default, server}, scope)

  @spec authorization(Binding.t()) ::
          {:ok, ArchAstro.SDK.Authorization.t()} | {:error, ArchAstro.SDK.Error.reason()}
  def authorization(%Binding{provider: provider, value: value}), do: provider.authorization(value)

  @spec refresh_if_current(Binding.t(), non_neg_integer()) ::
          {:ok, ArchAstro.SDK.Authorization.t()} | {:error, ArchAstro.SDK.Error.reason()}
  def refresh_if_current(%Binding{provider: provider, value: value}, generation),
    do: provider.refresh_if_current(value, generation)

  @spec put_session(provider() | server_ref(), String.t(), token_input()) ::
          :ok | {:error, ArchAstro.SDK.Error.reason()}
  def put_session({:provider, provider, server}, session_id, tokens) when is_atom(provider) do
    with {:ok, normalized} <- normalize_tokens(tokens) do
      provider.put_session(server, session_id, normalized)
    end
  end

  def put_session(server, session_id, tokens) do
    put_session({:provider, ArchAstro.SDK.TokenServer.Default, server}, session_id, tokens)
  end

  @spec delete_session(provider() | server_ref(), String.t()) ::
          :ok | {:error, ArchAstro.SDK.Error.reason()}
  def delete_session({:provider, provider, server}, session_id),
    do: provider.delete_session(server, session_id)

  def delete_session(server, session_id),
    do: delete_session({:provider, ArchAstro.SDK.TokenServer.Default, server}, session_id)

  defp normalize_tokens(%TokenSet{} = tokens) do
    if TokenSet.valid?(tokens),
      do: {:ok, TokenSet.normalize(tokens)},
      else: {:error, :invalid_token_set}
  end

  defp normalize_tokens(tokens) do
    {:ok, TokenSet.from_map(tokens)}
  rescue
    _error -> {:error, :invalid_token_set}
  end
end
