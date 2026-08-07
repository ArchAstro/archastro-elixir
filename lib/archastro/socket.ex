# Copyright (c) 2026 ArchAstro Inc. Licensed under the MIT License.

defmodule ArchAstro.Socket do
  @moduledoc """
  Supervised Phoenix Channels client backed by Slipstream.

  The socket resolves bearer credentials from the client's token binding when
  it connects and reconnects. It never owns or persists tokens itself.
  """

  use Slipstream

  alias ArchAstro.{Channel, Client, Codec, Error, TokenServer}

  @type option ::
          {:name, GenServer.name()}
          | {:socket_path, String.t()}
          | {:heartbeat_interval_msec, non_neg_integer()}
          | {:reconnect_after_msec, [non_neg_integer()]}
          | {:rejoin_after_msec, [non_neg_integer()]}
          | {:mint_opts, keyword()}

  @spec start_link(Client.t(), [option()]) :: GenServer.on_start()
  def start_link(%Client{} = client, opts \\ []) do
    {gen_opts, socket_opts} = Keyword.split(opts, [:name])
    Slipstream.start_link(__MODULE__, {client, socket_opts}, gen_opts)
  end

  @impl Slipstream
  def init({client, opts}) do
    with {:ok, config} <- connection_config(client, opts) do
      socket =
        new_socket()
        |> assign(
          client: client,
          socket_opts: opts,
          pending_joins: %{},
          channels: %{},
          pending_pushes: %{},
          subscriptions: %{},
          pending_leaves: %{}
        )

      connect(socket, config)
    end
  end

  @impl Slipstream
  def handle_connect(socket) do
    pending_leaves = socket.assigns[:pending_leaves] || %{}
    pending_joins = socket.assigns.pending_joins

    socket =
      Enum.reduce(socket.assigns.channels, socket, fn {topic, _channel}, current ->
        cond do
          Map.has_key?(pending_leaves, topic) -> current
          Map.has_key?(pending_joins, topic) -> current
          true -> rejoin_established(current, topic)
        end
      end)

    socket =
      Enum.reduce(pending_joins, socket, fn {topic, pending}, current ->
        join_and_remember(current, topic, pending.payload)
      end)

    {:ok, socket}
  end

  @impl Slipstream
  def handle_disconnect(reason, socket) do
    socket =
      socket
      |> fail_pending_pushes({:disconnected, reason})
      |> assign(:pending_leaves, %{})

    with {:ok, options} <- connection_config(socket.assigns.client, socket.assigns.socket_opts),
         {:ok, config} <- Slipstream.Configuration.validate(options),
         {:ok, socket} <- reconnect(%{socket | channel_config: config}) do
      {:ok, socket}
    else
      {:error, reason} -> {:stop, reason, socket}
    end
  end

  @doc false
  @spec fail_pending_pushes(Slipstream.Socket.t(), ArchAstro.Error.reason()) ::
          Slipstream.Socket.t()
  def fail_pending_pushes(socket, reason) do
    Enum.each(socket.assigns.pending_pushes, fn {_ref, request} ->
      GenServer.reply(request.from, {:error, reason})
    end)

    assign(socket, :pending_pushes, %{})
  end

  @impl Slipstream
  def handle_call({:archastro_join, topic, payload, module, descriptor}, from, socket) do
    pending_leaves = socket.assigns[:pending_leaves] || %{}

    if Map.has_key?(pending_leaves, topic) do
      pending = socket.assigns.pending_joins[topic]
      socket = queue_join(socket, topic, payload, module, descriptor, from, pending)
      {:noreply, socket}
    else
      handle_join_call(topic, payload, module, descriptor, from, socket)
    end
  end

  def handle_call({:archastro_push, topic, event, payload, descriptor}, from, socket) do
    case push(socket, topic, event, Codec.encode(payload)) do
      {:ok, ref} ->
        pending = %{from: from, topic: topic, descriptor: descriptor}
        {:noreply, update(socket, :pending_pushes, &Map.put(&1, ref, pending))}

      {:error, reason} ->
        {:reply, {:error, Error.channel(reason)}, socket}
    end
  end

  def handle_call({:archastro_subscribe, topic, event, subscriber, descriptor}, _from, socket) do
    key = {topic, event}
    item = %{subscriber: subscriber, descriptor: descriptor}
    subscriptions = Map.update(socket.assigns.subscriptions, key, [item], &[item | &1])
    {:reply, :ok, assign(socket, :subscriptions, subscriptions)}
  end

  def handle_call({:archastro_leave, topic}, _from, socket) do
    pending_leaves = socket.assigns[:pending_leaves] || %{}

    cond do
      Map.has_key?(pending_leaves, topic) ->
        {:reply, :ok, socket}

      Map.has_key?(socket.assigns.channels, topic) ->
        wait_for_ack? = joined?(socket, topic)
        socket = if wait_for_ack?, do: leave(socket, topic), else: socket

        subscriptions =
          Map.reject(socket.assigns.subscriptions, fn {{subscription_topic, _event}, _items} ->
            subscription_topic == topic
          end)

        socket =
          socket
          |> assign(
            :pending_leaves,
            if(wait_for_ack?, do: Map.put(pending_leaves, topic, true), else: pending_leaves)
          )
          |> assign(:subscriptions, subscriptions)
          |> update(:channels, &Map.delete(&1, topic))

        {:reply, :ok, socket}

      true ->
        {:reply, :ok, socket}
    end
  end

  defp handle_join_call(topic, payload, module, descriptor, from, socket) do
    case {socket.assigns.channels[topic], socket.assigns.pending_joins[topic]} do
      {%Channel{} = channel, _pending} ->
        {:reply, {:ok, channel}, socket}

      {nil, pending} when not is_nil(pending) ->
        {:noreply, queue_join(socket, topic, payload, module, descriptor, from, pending)}

      {nil, nil} ->
        socket = queue_join(socket, topic, payload, module, descriptor, from, nil)
        pending = socket.assigns.pending_joins[topic]
        {:noreply, join(socket, topic, pending.payload)}
    end
  end

  defp queue_join(socket, topic, payload, module, descriptor, from, nil) do
    pending = %{
      froms: [from],
      payload: Codec.encode(payload),
      module: module,
      descriptor: descriptor
    }

    update(socket, :pending_joins, &Map.put(&1, topic, pending))
  end

  defp queue_join(socket, topic, _payload, _module, _descriptor, from, pending) do
    pending = %{pending | froms: [from | pending.froms]}
    update(socket, :pending_joins, &Map.put(&1, topic, pending))
  end

  defp rejoin_established(socket, topic) do
    case socket.joins[topic] do
      %{params: payload} -> join_and_remember(socket, topic, payload)
      nil -> socket
    end
  end

  defp join_and_remember(socket, topic, payload) do
    socket = join(socket, topic, payload)

    case socket.joins[topic] do
      nil -> socket
      prior -> put_in(socket.joins[topic], %{prior | params: payload})
    end
  end

  @impl Slipstream
  def handle_join(topic, response, socket) do
    case Map.pop(socket.assigns.pending_joins, topic) do
      {nil, pending_joins} ->
        {:ok, assign(socket, :pending_joins, pending_joins)}

      {pending, pending_joins} ->
        channel = %Channel{
          socket: self(),
          topic: topic,
          module: pending.module,
          join_response: Codec.decode(response, pending.descriptor)
        }

        Enum.each(pending.froms, &GenServer.reply(&1, {:ok, channel}))

        {:ok,
         socket
         |> assign(:pending_joins, pending_joins)
         |> update(:channels, &Map.put(&1, topic, channel))}
    end
  end

  @impl Slipstream
  def handle_reply(ref, reply, socket) do
    case Map.pop(socket.assigns.pending_pushes, ref) do
      {nil, pending} ->
        {:ok, assign(socket, :pending_pushes, pending)}

      {request, pending} ->
        GenServer.reply(request.from, decode_reply(reply, request.descriptor))
        {:ok, assign(socket, :pending_pushes, pending)}
    end
  end

  @impl Slipstream
  def handle_message(topic, event, message, socket) do
    channel = socket.assigns.channels[topic]

    Enum.each(socket.assigns.subscriptions[{topic, event}] || [], fn subscription ->
      decoded = Codec.decode(message, subscription.descriptor)
      send(subscription.subscriber, {:archastro_channel, channel, event, decoded})
    end)

    {:ok, socket}
  end

  @impl Slipstream
  def handle_topic_close(topic, reason, socket) do
    error = Error.channel(reason)
    socket = fail_topic_pushes(socket, topic, error)

    case socket.assigns.pending_joins[topic] do
      nil ->
        case rejoin(socket, topic) do
          {:ok, socket} -> {:ok, socket}
          {:error, :never_joined} -> {:ok, socket}
        end

      pending ->
        Enum.each(pending.froms, &GenServer.reply(&1, {:error, error}))
        {:ok, update(socket, :pending_joins, &Map.delete(&1, topic))}
    end
  end

  @doc false
  @spec fail_topic_pushes(Slipstream.Socket.t(), String.t(), ArchAstro.Error.reason()) ::
          Slipstream.Socket.t()
  def fail_topic_pushes(socket, topic, reason) do
    {failed, retained} =
      Enum.split_with(socket.assigns.pending_pushes, fn {_ref, request} ->
        request.topic == topic
      end)

    Enum.each(failed, fn {_ref, request} ->
      GenServer.reply(request.from, {:error, reason})
    end)

    assign(socket, :pending_pushes, Map.new(retained))
  end

  @impl Slipstream
  def handle_leave(topic, socket) do
    {_request, pending_leaves} = Map.pop(socket.assigns[:pending_leaves] || %{}, topic)

    socket =
      socket
      |> assign(:pending_leaves, pending_leaves)

    case socket.assigns.pending_joins[topic] do
      nil -> {:ok, socket}
      pending -> {:ok, join_and_remember(socket, topic, pending.payload)}
    end
  end

  defp connection_config(client, opts) do
    with {:ok, authorization} <- ensure_fresh_authorization(client),
         {:ok, token} <- bearer_token(authorization.headers) do
      uri = websocket_uri(client.base_url, Keyword.get(opts, :socket_path, "/api/socket/websocket"))
      query = %{"token" => token}

      query =
        case header(authorization.headers, "x-archastro-api-key") do
          nil -> query
          api_key -> Map.put(query, "api_key", api_key)
        end

      config =
        opts
        |> Keyword.take([
          :heartbeat_interval_msec,
          :reconnect_after_msec,
          :rejoin_after_msec,
          :mint_opts
        ])
        |> Keyword.put(:uri, %{uri | query: URI.encode_query(query)})

      {:ok, config}
    end
  end

  @doc false
  @spec ensure_fresh_authorization(Client.t()) ::
          {:ok, ArchAstro.Authorization.t()} | {:error, ArchAstro.Error.reason()}
  def ensure_fresh_authorization(client) do
    with {:ok, authorization} <- TokenServer.authorization(client.token_binding) do
      if expired?(authorization) do
        TokenServer.refresh_if_current(client.token_binding, authorization.generation)
      else
        {:ok, authorization}
      end
    end
  end

  defp expired?(%{refreshable: true, expires_at: %DateTime{} = expires_at}),
    do: DateTime.compare(expires_at, DateTime.utc_now()) != :gt

  defp expired?(_authorization), do: false

  defp websocket_uri(base_url, socket_path) do
    uri = URI.parse(base_url)
    scheme = if uri.scheme == "https", do: "wss", else: "ws"
    %{uri | scheme: scheme, path: socket_path, query: nil, fragment: nil}
  end

  defp bearer_token(headers) do
    case header(headers, "authorization") do
      "Bearer " <> token -> {:ok, token}
      _ -> {:error, :websocket_requires_bearer_token}
    end
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(key) == name, do: value
    end)
  end

  defp decode_reply({:ok, value}, descriptor), do: {:ok, Codec.decode(value, descriptor)}
  defp decode_reply({:error, reason}, _descriptor), do: {:error, Error.channel(reason)}

  defp decode_reply(%{"status" => "ok", "response" => value}, descriptor),
    do: {:ok, Codec.decode(value, descriptor)}

  defp decode_reply(%{"status" => "error", "response" => reason}, _descriptor),
    do: {:error, Error.channel(reason)}

  defp decode_reply(value, descriptor), do: {:ok, Codec.decode(value, descriptor)}
end
