# Copyright (c) 2026 ArchAstro Inc. Licensed under the MIT License.

defmodule ArchAstro.SDK.Channel do
  @moduledoc "A joined Phoenix Channel owned by an `ArchAstro.SDK.Socket` process."

  @enforce_keys [:socket, :topic, :module]
  defstruct [:socket, :topic, :module, :join_response]

  @type t :: %__MODULE__{
          socket: GenServer.server(),
          topic: String.t(),
          module: module(),
          join_response: ArchAstro.SDK.JSON.t() | struct()
        }

  @spec join(
          GenServer.server(),
          String.t(),
          ArchAstro.SDK.JSON.object() | struct(),
          module(),
          ArchAstro.SDK.Codec.descriptor(),
          timeout()
        ) :: {:ok, t()} | {:error, ArchAstro.SDK.Error.reason()}
  # Payloads are encoded here rather than in the socket process: an
  # unencodable value must fail its own caller, not take down the shared
  # socket and every other channel riding on it.
  def join(socket, topic, payload, module, descriptor, timeout \\ 5_000) do
    encoded = ArchAstro.SDK.Codec.encode(payload)
    GenServer.call(socket, {:archastro_join, topic, encoded, module, descriptor}, timeout)
  end

  @spec push(
          t(),
          String.t(),
          ArchAstro.SDK.JSON.object() | struct(),
          ArchAstro.SDK.Codec.descriptor(),
          timeout()
        ) :: {:ok, ArchAstro.SDK.JSON.t() | struct() | :ok} | {:error, ArchAstro.SDK.Error.reason()}
  def push(%__MODULE__{} = channel, event, payload, descriptor, timeout \\ 5_000) do
    encoded = ArchAstro.SDK.Codec.encode(payload)

    GenServer.call(
      channel.socket,
      {:archastro_push, channel.topic, event, encoded, descriptor},
      timeout
    )
  end

  @spec subscribe(t(), String.t(), pid(), ArchAstro.SDK.Codec.descriptor()) :: :ok
  def subscribe(%__MODULE__{} = channel, event, subscriber, descriptor)
      when is_pid(subscriber) do
    GenServer.call(
      channel.socket,
      {:archastro_subscribe, channel.topic, event, subscriber, descriptor}
    )
  end

  @spec leave(t(), timeout()) :: :ok | {:error, ArchAstro.SDK.Error.reason()}
  def leave(%__MODULE__{} = channel, timeout \\ 5_000),
    do: GenServer.call(channel.socket, {:archastro_leave, channel.topic}, timeout)
end

defimpl Inspect, for: ArchAstro.SDK.Channel do
  import Inspect.Algebra

  def inspect(channel, opts) do
    concat([
      "#ArchAstro.SDK.Channel<topic: ",
      to_doc(channel.topic, opts),
      ", module: ",
      to_doc(channel.module, opts),
      ">"
    ])
  end
end
