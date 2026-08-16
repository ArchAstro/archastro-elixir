# Copyright (c) 2026 ArchAstro Inc. Licensed under the MIT License.

defmodule ArchAstro.SDK.HTTP do
  @moduledoc false

  alias ArchAstro.SDK.{Client, Codec, Error, Query, TokenServer}

  @type method :: :get | :post | :put | :patch | :delete
  @type option ::
          {:body, ArchAstro.SDK.JSON.t() | struct()}
          | {:query, ArchAstro.SDK.JSON.object() | struct()}
          | {:decode, Codec.descriptor()}
          | {:raw, boolean()}

  @spec request(Client.t(), method(), String.t(), [option()]) ::
          {:ok, ArchAstro.SDK.JSON.t() | struct() | Req.Response.t() | :ok}
          | {:error, Error.reason()}
  def request(%Client{} = client, method, path, opts \\ []) do
    with {:ok, authorization} <- TokenServer.authorization(client.token_binding) do
      execute(client, authorization, method, path, opts, true)
    end
  end

  defp execute(client, authorization, method, path, opts, allow_refresh) do
    started = System.monotonic_time()
    metadata = Map.merge(client.telemetry_metadata, %{method: method, path: path})

    :telemetry.execute(
      [:archastro, :request, :start],
      %{system_time: System.system_time()},
      metadata
    )

    request_opts = [
      method: method,
      url: Query.append(client.base_url <> path, opts[:query]),
      headers: authorization.headers,
      retry: false
    ]

    request_opts =
      if Keyword.get(opts, :raw, false),
        do: Keyword.put(request_opts, :decode_body, false),
        else: request_opts

    request_opts =
      case Keyword.fetch(opts, :body) do
        {:ok, value} -> Keyword.put(request_opts, :json, Codec.encode(value))
        :error -> request_opts
      end

    result = Req.request(client.request, request_opts)

    duration = System.monotonic_time() - started

    case result do
      {:ok, %{status: 401}} when allow_refresh and authorization.refreshable ->
        case TokenServer.refresh_if_current(client.token_binding, authorization.generation) do
          {:ok, next} -> execute(client, next, method, path, opts, false)
          {:error, reason} -> {:error, reason}
        end

      {:ok, %{status: status} = response} when status in 200..299 ->
        decoded =
          if Keyword.get(opts, :raw, false),
            do: response,
            else: Codec.decode(response.body, Keyword.get(opts, :decode, :unknown))

        :telemetry.execute(
          [:archastro, :request, :stop],
          %{duration: duration},
          Map.put(metadata, :status, status)
        )

        {:ok, decoded}

      {:ok, response} ->
        error = response |> decode_error_body() |> Error.from_response()

        :telemetry.execute(
          [:archastro, :request, :stop],
          %{duration: duration},
          Map.merge(metadata, %{status: response.status, error: error})
        )

        {:error, error}

      {:error, reason} ->
        error = Error.transport(reason)

        :telemetry.execute(
          [:archastro, :request, :exception],
          %{duration: duration},
          Map.put(metadata, :error, error)
        )

        {:error, error}
    end
  end

  # Raw requests suppress Req's body decoding, which would otherwise strip the
  # structured error envelope off a failure response too.
  defp decode_error_body(%Req.Response{body: body} = response) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> %{response | body: decoded}
      {:error, _reason} -> response
    end
  end

  defp decode_error_body(response), do: response
end
