# Copyright (c) 2026 ArchAstro Inc. Licensed under the MIT License.

defmodule ArchAstro.Client do
  @moduledoc "Immutable entry point for the ArchAstro Platform API."

  alias ArchAstro.TokenServer

  @enforce_keys [:base_url, :request, :token_binding]
  defstruct [:base_url, :request, :token_binding, telemetry_metadata: %{}]

  @type telemetry_metadata :: %{optional(atom()) => ArchAstro.JSON.t()}

  @type t :: %__MODULE__{
          base_url: String.t(),
          request: Req.Request.t(),
          token_binding: TokenServer.Binding.t(),
          telemetry_metadata: telemetry_metadata()
        }

  @type option ::
          {:base_url, String.t()}
          | {:req, Req.Request.t()}
          | {:telemetry_metadata, telemetry_metadata()}

  @spec for_server(TokenServer.provider() | TokenServer.server_ref(), [option()]) ::
          {:ok, t()} | {:error, ArchAstro.Error.reason()}
  def for_server(token_server, opts \\ []), do: build(token_server, :server, opts)

  @spec public(TokenServer.provider() | TokenServer.server_ref(), [option()]) ::
          {:ok, t()} | {:error, ArchAstro.Error.reason()}
  def public(token_server, opts \\ []), do: build(token_server, :public, opts)

  @spec for_session(TokenServer.provider() | TokenServer.server_ref(), String.t(), [option()]) ::
          {:ok, t()} | {:error, ArchAstro.Error.reason()}
  def for_session(token_server, session_id, opts \\ []) when is_binary(session_id),
    do: build(token_server, {:session, session_id}, opts)

  defp build(token_server, scope, opts) do
    with {:ok, binding} <- TokenServer.bind(token_server, scope) do
      {:ok,
       %__MODULE__{
         base_url:
           opts
           |> Keyword.get(:base_url, ArchAstro.GeneratedClient.default_base_url())
           |> String.trim_trailing("/"),
         request: Keyword.get(opts, :req, Req.new(retry: false)),
         token_binding: binding,
         telemetry_metadata: Keyword.get(opts, :telemetry_metadata, %{})
       }}
    end
  end
end

defimpl Inspect, for: ArchAstro.Client do
  import Inspect.Algebra

  def inspect(client, opts) do
    concat([
      "#ArchAstro.Client<base_url: ",
      to_doc(client.base_url, opts),
      ", token_binding: ",
      to_doc(client.token_binding, opts),
      ">"
    ])
  end
end
