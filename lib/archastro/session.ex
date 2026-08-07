# Copyright (c) 2026 ArchAstro Inc. Licensed under the MIT License.

defmodule ArchAstro.Session do
  @moduledoc """
  Helpers for session-scoped authentication in LiveView and other multi-user apps.

  Login credentials exist only on the caller's stack. Successful bearer tokens
  are handed to the configured `ArchAstro.TokenServer`; usernames and passwords
  are never placed in GenServer configuration or ETS.
  """

  alias ArchAstro.{Auth, Client, TokenServer}

  @spec login(
          TokenServer.provider() | TokenServer.server_ref(),
          String.t(),
          String.t(),
          String.t(),
          keyword()
        ) ::
          {:ok, Client.t()} | {:error, ArchAstro.Error.reason()}
  def login(token_server, session_id, email, password, opts \\ [])
      when is_binary(session_id) and is_binary(email) and is_binary(password) do
    input = %ArchAstro.Types.Operations.PostApiV1AuthLogin.AuthInput{
      email: email,
      password: password
    }

    with {:ok, public_client} <- Client.public(token_server, opts),
         {:ok, tokens} <- Auth.login(public_client, input),
         :ok <- TokenServer.put_session(token_server, session_id, tokens),
         {:ok, session_client} <- Client.for_session(token_server, session_id, opts) do
      {:ok, session_client}
    end
  end

  @spec sign_out(TokenServer.provider() | TokenServer.server_ref(), String.t()) ::
          :ok | {:error, ArchAstro.Error.reason()}
  def sign_out(token_server, session_id), do: TokenServer.delete_session(token_server, session_id)
end
