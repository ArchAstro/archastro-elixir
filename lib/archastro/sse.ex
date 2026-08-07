# Copyright (c) 2026 ArchAstro Inc. Licensed under the MIT License.

defmodule ArchAstro.SSE.Event do
  @moduledoc "A Server-Sent Event."
  defstruct [:event, :data, :id, :retry]

  @type t :: %__MODULE__{
          event: String.t() | nil,
          data: ArchAstro.JSON.t(),
          id: String.t() | nil,
          retry: non_neg_integer() | nil
        }
end

defmodule ArchAstro.SSE.Stream do
  @moduledoc "Typed, lazy stream of decoded server-sent events."
  @enforce_keys [:source, :decoder]
  defstruct [:source, :decoder]

  @type t(event) :: %__MODULE__{
          source: Enumerable.t(),
          decoder: (ArchAstro.SSE.Event.t() -> event)
        }

  @spec new(Enumerable.t(), (ArchAstro.SSE.Event.t() -> event)) :: t(event) when event: var
  def new(source, decoder), do: %__MODULE__{source: source, decoder: decoder}
end

defimpl Enumerable, for: ArchAstro.SSE.Stream do
  def reduce(stream, acc, fun),
    do: Enumerable.reduce(Stream.map(stream.source, stream.decoder), acc, fun)

  def count(_stream), do: {:error, __MODULE__}
  def member?(_stream, _value), do: {:error, __MODULE__}
  def slice(_stream), do: {:error, __MODULE__}
end

defmodule ArchAstro.SSE do
  @moduledoc false

  @type option(event) ::
          ArchAstro.HTTP.option()
          | {:decode_event, (ArchAstro.SSE.Event.t() -> event)}

  @spec stream(
          ArchAstro.Client.t(),
          ArchAstro.HTTP.method(),
          String.t(),
          [option(event)]
        ) :: ArchAstro.SSE.Stream.t(event)
        when event: var
  def stream(client, method, path, opts \\ []) do
    source =
      Stream.resource(
        fn -> open(client, method, path, opts) end,
        &next/1,
        &close/1
      )

    ArchAstro.SSE.Stream.new(source, Keyword.get(opts, :decode_event, &Function.identity/1))
  end

  defp open(client, method, path, opts) do
    case ArchAstro.TokenServer.authorization(client.token_binding) do
      {:ok, authorization} ->
        open(client, authorization, method, path, opts, true)

      {:error, reason} ->
        raise "unable to resolve ArchAstro credentials: #{inspect(reason)}"
    end
  end

  defp open(client, authorization, method, path, opts, allow_refresh) do
    request_opts = [
      method: method,
      url: ArchAstro.Query.append(client.base_url <> path, opts[:query]),
      headers: [{"accept", "text/event-stream"} | authorization.headers],
      into: :self,
      retry: false
    ]

    request_opts =
      if Keyword.has_key?(opts, :body),
        do: Keyword.put(request_opts, :json, ArchAstro.Codec.encode(opts[:body])),
        else: request_opts

    request = Req.request!(client.request, request_opts)

    cond do
      request.status == 401 and allow_refresh and authorization.refreshable ->
        Req.cancel_async_response(request)

        case ArchAstro.TokenServer.refresh_if_current(
               client.token_binding,
               authorization.generation
             ) do
          {:ok, next} -> open(client, next, method, path, opts, false)
          {:error, reason} -> raise "unable to refresh ArchAstro credentials: #{inspect(reason)}"
        end

      request.status in 200..299 and event_stream_response?(request) ->
        %{response: request, buffer: "", events: [], done: false, started: false}

      request.status in 200..299 ->
        Req.cancel_async_response(request)
        raise ArchAstro.Error.transport(:invalid_event_stream_content_type)

      true ->
        raise ArchAstro.Error.from_response(complete_error_response(request))
    end
  end

  defp complete_error_response(%Req.Response{body: %Req.Response.Async{} = async} = response) do
    raw = async |> Enum.to_list() |> IO.iodata_to_binary()

    body =
      case Jason.decode(raw) do
        {:ok, decoded} -> decoded
        {:error, _reason} -> raw
      end

    %{response | body: body}
  end

  defp complete_error_response(response), do: response

  defp next(%{events: [event | rest]} = state), do: {[event], %{state | events: rest}}
  defp next(%{done: true} = state), do: {:halt, state}

  defp next(state) do
    ref = state.response.body.ref

    receive do
      {^ref, _payload} = message ->
        case Req.parse_message(state.response, message) do
          {:ok, chunks} -> consume_chunks(chunks, state)
          {:error, reason} -> raise ArchAstro.Error.transport(reason)
          :unknown -> raise "Req rejected a message carrying its own async response reference"
        end
    end
  end

  defp consume_chunks(chunks, state) do
    Enum.reduce(chunks, {[], state}, fn
      _chunk, {events, %{done: true} = current} ->
        {events, current}

      {:data, data}, {events, current} ->
        input = current.buffer <> data
        {parsed_events, buffer, consumed?} = consume_utf8(input, not current.started)

        {events ++ parsed_events,
         %{current | buffer: buffer, started: current.started or consumed?}}

      :done, {events, current} ->
        {events, %{current | done: true}}

      _chunk, acc ->
        acc
    end)
    |> case do
      {[], %{done: true} = current} -> {:halt, current}
      {[], current} -> next(current)
      {events, current} -> {events, current}
    end
  end

  @doc false
  @spec parse_events(binary(), boolean()) :: {[ArchAstro.SSE.Event.t()], binary()}
  def parse_events(buffer, strip_bom \\ true) do
    {events, rest, _consumed?} = consume_utf8(buffer, strip_bom)
    {events, rest}
  end

  defp consume_utf8(buffer, strip_bom) do
    {valid, incomplete} = normalize_utf8(buffer)
    valid = if strip_bom, do: String.trim_leading(valid, <<0xEF, 0xBB, 0xBF>>), else: valid
    parts = Regex.split(~r/(?:\r\n|\r|\n){2}/, valid)
    complete = Enum.drop(parts, -1)
    rest = (List.last(parts) || "") <> incomplete
    events = Enum.map(complete, &parse_event/1) |> Enum.reject(&is_nil/1)
    {events, rest, valid != ""}
  end

  defp normalize_utf8(input), do: normalize_utf8(input, "")

  defp normalize_utf8(input, prefix) do
    case :unicode.characters_to_binary(input, :utf8, :utf8) do
      valid when is_binary(valid) ->
        {prefix <> valid, ""}

      {:incomplete, valid, incomplete} ->
        {prefix <> valid, incomplete}

      {:error, valid, <<_invalid, rest::binary>>} ->
        normalize_utf8(rest, prefix <> valid <> <<0xEF, 0xBF, 0xBD>>)
    end
  end

  defp parse_event(block) do
    fields =
      block
      |> String.split(~r/\r\n|\r|\n/)
      |> Enum.reject(&String.starts_with?(&1, ":"))
      |> Enum.reduce(%{data: []}, fn line, acc ->
        {field, value} =
          case String.split(line, ":", parts: 2) do
            [field, value] -> {field, strip_optional_space(value)}
            [field] -> {field, ""}
          end

        case {field, value} do
          {"data", value} ->
            %{acc | data: [value | acc.data]}

          {"event", value} ->
            Map.put(acc, :event, value)

          {"id", value} ->
            if String.contains?(value, <<0>>), do: acc, else: Map.put(acc, :id, value)

          {"retry", value} ->
            if Regex.match?(~r/^\d+$/, value),
              do: Map.put(acc, :retry, String.to_integer(value)),
              else: acc

          _ ->
            acc
        end
      end)

    if fields.data == [] do
      nil
    else
      raw = fields.data |> Enum.reverse() |> Enum.join("\n")

      data =
        case Jason.decode(raw) do
          {:ok, value} -> value
          _ -> raw
        end

      struct(ArchAstro.SSE.Event, %{
        event: if(fields[:event] in [nil, ""], do: "message", else: fields[:event]),
        data: data,
        id: fields[:id],
        retry: fields[:retry]
      })
    end
  end

  defp strip_optional_space(" " <> value), do: value
  defp strip_optional_space(value), do: value

  defp event_stream_response?(response) do
    response
    |> Req.Response.get_header("content-type")
    |> Enum.any?(fn value ->
      value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase() ==
        "text/event-stream"
    end)
  end

  defp close(%{response: response}), do: Req.cancel_async_response(response)
  defp close(_), do: :ok
end
