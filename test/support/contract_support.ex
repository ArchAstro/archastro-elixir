# Copyright (c) 2026 ArchAstro Inc. Licensed under the MIT License.

defmodule ArchAstro.SDK.ContractSupport do
  @moduledoc false

  @prism_name __MODULE__.Prism

  def client do
    build_client([])
  end

  def error_client(status) when is_integer(status) do
    build_client([{"prefer", "code=#{status}"}])
  end

  defp build_client(headers) do
    ensure_prism!()

    {:ok, token_server} =
      ArchAstro.SDK.TokenServer.Default.start_link(
        mode: {:system_user, publishable_key: "pk_test-key", access_token: "test-token"}
      )

    {:ok, client} =
      ArchAstro.SDK.Client.for_server(token_server,
        base_url: prism_url(),
        req: Req.new(headers: headers, retry: false)
      )

    client
  end

  @type channel_error ::
          {:channel_not_found, String.t()} | {:channel_join_not_found, String.t(), String.t()}

  @spec verify_channel(
          String.t(),
          String.t(),
          (GenServer.server(), (String.t(), String.t() -> :ok) -> :ok)
        ) :: :ok | {:error, channel_error()}
  def verify_channel(channel_name, topic_pattern, exercise) when is_function(exercise, 2) do
    if System.get_env("ARCHASTRO_RUN_CHANNEL_CONTRACT_TESTS") in [
         "1",
         "true",
         "TRUE",
         "yes",
         "YES"
       ] do
      spec = Jason.decode!(File.read!(spec_path()))
      channels = get_in(spec, ["x-channels"]) || []

      case Enum.find(channels, &(Map.get(&1, "name") == channel_name)) do
        nil ->
          {:error, {:channel_not_found, channel_name}}

        channel ->
          case Enum.find(channel["joins"] || [], &(Map.get(&1, "pattern") == topic_pattern)) do
            nil -> {:error, {:channel_join_not_found, channel_name, topic_pattern}}
            join -> verify_channel_with_harness(channel, join, exercise)
          end
      end
    else
      :ok
    end
  end

  @type stream_error ::
          {:unexpected_stream_events, [String.t()], [String.t()]} | :stream_did_not_fail

  @spec verify_stream(
          String.t(),
          [String.t()],
          (ArchAstro.SDK.Client.t() -> Enumerable.t())
        ) :: {:ok, [ArchAstro.SDK.SSE.Event.t()]} | {:error, stream_error()}
  def verify_stream(route, expected_events, stream_factory) when is_function(stream_factory, 1) do
    with_harness(fn %{"controlUrl" => control_url} ->
      actions = Enum.map(expected_events, &%{type: "autoEmit", event: &1})

      assert_contract_response!(
        Req.post(control_url <> "/stream-scenarios",
          json: %{route: route, actions: actions},
          retry: false
        )
      )

      {:ok, token_server} =
        ArchAstro.SDK.TokenServer.Default.start_link(
          mode: {:system_user, publishable_key: "pk_test-key", access_token: "test-token"}
        )

      {:ok, client} = ArchAstro.SDK.Client.for_server(token_server, base_url: control_url)
      events = stream_factory.(client) |> Enum.to_list()
      actual_events = Enum.map(events, & &1.event)

      if actual_events == expected_events do
        {:ok, events}
      else
        {:error, {:unexpected_stream_events, expected_events, actual_events}}
      end
    end)
  end

  @spec verify_stream_error(String.t(), (ArchAstro.SDK.Client.t() -> Enumerable.t())) ::
          :ok | {:error, :stream_did_not_fail}
  def verify_stream_error(route, stream_factory) when is_function(stream_factory, 1) do
    with_harness(fn %{"controlUrl" => control_url} ->
      assert_contract_response!(
        Req.post(control_url <> "/stream-scenarios",
          json: %{
            route: route,
            actions: [%{type: "status", code: 402, body: %{error: %{code: "plan_not_entitled"}}}]
          },
          retry: false
        )
      )

      {:ok, token_server} =
        ArchAstro.SDK.TokenServer.Default.start_link(
          mode: {:system_user, publishable_key: "pk_test-key", access_token: "test-token"}
        )

      {:ok, client} = ArchAstro.SDK.Client.for_server(token_server, base_url: control_url)

      try do
        stream_factory.(client) |> Enum.to_list()
        {:error, :stream_did_not_fail}
      rescue
        ArchAstro.SDK.Error -> :ok
      end
    end)
  end

  defp verify_channel_with_harness(channel, join, exercise) do
    bin =
      System.get_env("ARCHASTRO_HARNESS_BIN") ||
        Path.join([repo_root(), "node_modules", "@archastro", "channel-harness", "dist", "bin.js"])

    unless File.exists?(bin) do
      raise "channel harness not found at #{bin}; set ARCHASTRO_HARNESS_BIN or run npm ci"
    end

    with_harness(bin, &exercise_join!(channel, join, exercise, &1))
  end

  defp with_harness(callback) do
    bin =
      System.get_env("ARCHASTRO_HARNESS_BIN") ||
        Path.join([repo_root(), "node_modules", "@archastro", "channel-harness", "dist", "bin.js"])

    unless File.exists?(bin) do
      raise "channel harness not found at #{bin}; set ARCHASTRO_HARNESS_BIN or run npm ci"
    end

    with_harness(bin, callback)
  end

  defp with_harness(bin, callback) do
    port =
      Port.open(
        {:spawn_executable, System.find_executable("node")},
        [:binary, :exit_status, :stderr_to_stdout, args: [bin, spec_path()]]
      )

    try do
      endpoints = await_harness_endpoints!(port, "", System.monotonic_time(:millisecond) + 30_000)
      callback.(endpoints)
    after
      if Port.info(port), do: Port.close(port)
    end
  end

  defp await_harness_endpoints!(port, buffer, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      raise "channel harness did not start within 30 seconds"
    end

    receive do
      {^port, {:data, output}} ->
        data = buffer <> output

        case String.split(data, "\n", parts: 2) do
          [line, rest] ->
            case Jason.decode(line) do
              {:ok, %{"wsUrl" => _, "controlUrl" => _} = endpoints} -> endpoints
              _ -> await_harness_endpoints!(port, rest, deadline)
            end

          [_partial] ->
            await_harness_endpoints!(port, data, deadline)
        end

      {^port, {:exit_status, status}} ->
        raise "channel harness exited with status #{status}"
    after
      100 -> await_harness_endpoints!(port, buffer, deadline)
    end
  end

  defp exercise_join!(channel, join, exercise, %{"wsUrl" => ws_url, "controlUrl" => control_url}) do
    params = get_in(join, ["params", "example"]) || %{}
    pattern = Map.fetch!(join, "pattern")

    topic =
      Regex.replace(~r/\{([^}]+)\}/, pattern, fn _, name ->
        to_string(params[name] || "test-value")
      end)

    assert_contract_response!(Req.post(control_url <> "/reset", retry: false))

    message_handlers =
      Map.new(channel["messages"] || [], fn message ->
        reply = get_in(message, ["returns", "example"]) || %{}
        {Map.fetch!(message, "event"), [%{type: "reply", payload: reply}]}
      end)

    assert_contract_response!(
      Req.post(control_url <> "/scenarios",
        json: %{
          topic: topic,
          onJoin: [%{type: "reply", payload: get_in(join, ["returns", "example"]) || %{}}],
          onMessage: message_handlers
        },
        retry: false
      )
    )

    uri = URI.parse(ws_url)

    base_uri = %{
      uri
      | scheme: if(uri.scheme == "wss", do: "https", else: "http"),
        path: nil,
        query: nil
    }

    {:ok, token_server} =
      ArchAstro.SDK.TokenServer.Default.start_link(
        mode: {:system_user, publishable_key: "pk_test-key", access_token: "test-token"}
      )

    {:ok, client} = ArchAstro.SDK.Client.for_server(token_server, base_url: URI.to_string(base_uri))
    {:ok, socket} = ArchAstro.SDK.Socket.start_link(client, socket_path: uri.path)

    try do
      push = fn joined_topic, event ->
        assert_contract_response!(
          Req.post(control_url <> "/pushes",
            json: %{topic: joined_topic, event: event},
            retry: false
          )
        )
      end

      exercise.(socket, push)
    after
      GenServer.stop(socket)
    end
  end

  defp assert_contract_response!({:ok, %{status: status}}) when status in 200..299, do: :ok

  defp assert_contract_response!(other),
    do: raise("harness control request failed: #{inspect(other)}")

  def stop_servers do
    case Process.whereis(@prism_name) do
      nil ->
        :ok

      pid ->
        GenServer.stop(pid, :normal, 5_000)
    end
  catch
    :exit, _ -> :ok
  end

  defp ensure_prism! do
    case Process.whereis(@prism_name) do
      nil -> start_prism!()
      _pid -> :ok
    end
  end

  defp start_prism! do
    if prism_stably_answers?() do
      {:ok, _} = ArchAstro.SDK.ContractSupport.PrismServer.start(name: @prism_name)
      :ok
    else
      bin = System.get_env("PRISM_BIN") || Path.join([repo_root(), "node_modules", ".bin", "prism"])

      unless File.exists?(bin) do
        raise "Prism not found at #{bin}; set PRISM_BIN or run npm ci"
      end

      {:ok, server} =
        ArchAstro.SDK.ContractSupport.PrismServer.start(
          name: @prism_name,
          executable: bin,
          args: [
            "mock",
            spec_path(),
            "--port",
            prism_port(),
            "--host",
            "127.0.0.1"
          ]
        )

      await_prism!(server, System.monotonic_time(:millisecond) + 60_000)
    end
  end

  defp await_prism!(server, deadline) do
    cond do
      prism_answers?() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        GenServer.stop(server)
        raise "Prism did not start on port #{prism_port()} within 60 seconds"

      true ->
        if Process.alive?(server),
          do: Process.sleep(100),
          else: raise("Prism exited during startup")

        await_prism!(server, deadline)
    end
  end

  defp prism_answers? do
    case Req.get(prism_url() <> "/", receive_timeout: 1_000, retry: false) do
      {:ok, _response} -> true
      {:error, _reason} -> false
    end
  rescue
    _ -> false
  end

  defp prism_stably_answers? do
    if prism_answers?() do
      Process.sleep(500)
      prism_answers?()
    else
      false
    end
  end

  defp repo_root, do: Path.expand("../..", __DIR__)

  defp spec_path,
    do: System.get_env("OPENAPI_SPEC_PATH") || Path.join(repo_root(), "specs/platform-openapi.json")

  defp prism_port, do: System.get_env("PRISM_PORT") || "4040"
  defp prism_url, do: "http://127.0.0.1:" <> prism_port()
end

defmodule ArchAstro.SDK.ContractSupport.PrismServer do
  @moduledoc false
  use GenServer

  def start(opts), do: GenServer.start(__MODULE__, opts, Keyword.take(opts, [:name]))

  @impl GenServer
  def init(opts) do
    port =
      case opts[:executable] do
        nil ->
          nil

        executable ->
          Port.open(
            {:spawn_executable, executable},
            [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              args: Keyword.fetch!(opts, :args)
            ]
          )
      end

    {:ok, port}
  end

  @impl GenServer
  def handle_info({_port, {:data, _output}}, state), do: {:noreply, state}
  def handle_info({_port, {:exit_status, status}}, state), do: {:stop, {:prism_exit, status}, state}

  @impl GenServer
  def terminate(_reason, port) when is_port(port) do
    if Port.info(port), do: Port.close(port)
  catch
    :error, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok
end
