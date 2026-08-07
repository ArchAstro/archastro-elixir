# Copyright (c) 2026 ArchAstro Inc. Licensed under the MIT License.

defmodule ArchAstro.Channel do
  @moduledoc "A joined Phoenix Channel owned by an `ArchAstro.Socket` process."

  @enforce_keys [:socket, :topic, :module]
  defstruct [:socket, :topic, :module, :join_response]

  @type t :: %__MODULE__{
          socket: GenServer.server(),
          topic: String.t(),
          module: module(),
          join_response: ArchAstro.JSON.t() | struct()
        }

  @spec join(
          GenServer.server(),
          String.t(),
          ArchAstro.JSON.object() | struct(),
          module(),
          ArchAstro.Codec.descriptor(),
          timeout()
        ) :: {:ok, t()} | {:error, ArchAstro.Error.reason()}
  def join(socket, topic, payload, module, descriptor, timeout \\ 5_000),
    do: GenServer.call(socket, {:archastro_join, topic, payload, module, descriptor}, timeout)

  @spec push(
          t(),
          String.t(),
          ArchAstro.JSON.object() | struct(),
          ArchAstro.Codec.descriptor(),
          timeout()
        ) :: {:ok, ArchAstro.JSON.t() | struct() | :ok} | {:error, ArchAstro.Error.reason()}
  def push(%__MODULE__{} = channel, event, payload, descriptor, timeout \\ 5_000),
    do:
      GenServer.call(
        channel.socket,
        {:archastro_push, channel.topic, event, payload, descriptor},
        timeout
      )

  @spec subscribe(t(), String.t(), pid(), ArchAstro.Codec.descriptor()) :: :ok
  def subscribe(%__MODULE__{} = channel, event, subscriber, descriptor)
      when is_pid(subscriber) do
    GenServer.call(
      channel.socket,
      {:archastro_subscribe, channel.topic, event, subscriber, descriptor}
    )
  end

  @spec leave(t(), timeout()) :: :ok | {:error, ArchAstro.Error.reason()}
  def leave(%__MODULE__{} = channel, timeout \\ 5_000),
    do: GenServer.call(channel.socket, {:archastro_leave, channel.topic}, timeout)
end

defimpl Inspect, for: ArchAstro.Channel do
  import Inspect.Algebra

  def inspect(channel, opts) do
    concat([
      "#ArchAstro.Channel<topic: ",
      to_doc(channel.topic, opts),
      ", module: ",
      to_doc(channel.module, opts),
      ">"
    ])
  end
end
