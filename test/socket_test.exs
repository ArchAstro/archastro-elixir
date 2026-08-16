defmodule ArchAstro.SDK.SocketTest do
  use ExUnit.Case, async: true

  alias ArchAstro.SDK.Auth.TokenSet

  test "concurrent joins to one topic retain and reply to every waiter" do
    first_tag = make_ref()
    second_tag = make_ref()

    socket =
      Slipstream.Socket.new()
      |> Slipstream.Socket.assign(:channels, %{})
      |> Slipstream.Socket.assign(:pending_joins, %{})

    assert {:noreply, pending_socket} =
             ArchAstro.SDK.Socket.handle_call(
               {:archastro_join, "room:1", %{}, __MODULE__, {:object, []}},
               {self(), first_tag},
               socket
             )

    assert {:noreply, coalesced_socket} =
             ArchAstro.SDK.Socket.handle_call(
               {:archastro_join, "room:1", %{}, __MODULE__, {:object, []}},
               {self(), second_tag},
               pending_socket
             )

    assert length(coalesced_socket.assigns.pending_joins["room:1"].froms) == 2
    assert {:ok, _joined_socket} = ArchAstro.SDK.Socket.handle_join("room:1", %{}, coalesced_socket)
    assert_receive {^first_tag, {:ok, %ArchAstro.SDK.Channel{topic: "room:1"}}}
    assert_receive {^second_tag, {:ok, %ArchAstro.SDK.Channel{topic: "room:1"}}}
  end

  test "refreshes expired credentials before channel connection or reconnect" do
    counter = start_supervised!({Agent, fn -> 0 end})

    plug = fn conn ->
      Agent.update(counter, &(&1 + 1))
      Req.Test.json(conn, %{"access_token" => "fresh", "refresh_token" => "rotated"})
    end

    server =
      start_supervised!(
        {ArchAstro.SDK.TokenServer.Default,
         mode: {:sessions, publishable_key: "pk"},
         base_url: "http://test",
         req: Req.new(plug: plug, retry: false)}
      )

    assert :ok =
             ArchAstro.SDK.TokenServer.put_session(server, "session", %TokenSet{
               access_token: "expired",
               refresh_token: "refresh",
               expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
             })

    assert {:ok, client} = ArchAstro.SDK.Client.for_session(server, "session")
    assert {:ok, authorization} = ArchAstro.SDK.Socket.ensure_fresh_authorization(client)
    assert {"authorization", "Bearer fresh"} in authorization.headers
    assert Agent.get(counter, & &1) == 1
  end

  test "disconnects fail and clear pending channel pushes" do
    tag = make_ref()

    socket =
      Slipstream.Socket.new()
      |> Slipstream.Socket.assign(:pending_pushes, %{
        "1" => %{from: {self(), tag}, descriptor: :string}
      })

    cleared = ArchAstro.SDK.Socket.fail_pending_pushes(socket, :transport_closed)
    assert cleared.assigns.pending_pushes == %{}
    assert_receive {^tag, {:error, :transport_closed}}
  end

  test "topic closure fails only pushes pending on that topic" do
    closed_tag = make_ref()
    retained_tag = make_ref()

    socket =
      Slipstream.Socket.new()
      |> Slipstream.Socket.assign(:pending_pushes, %{
        "1" => %{from: {self(), closed_tag}, topic: "room:1", descriptor: :string},
        "2" => %{from: {self(), retained_tag}, topic: "room:2", descriptor: :string}
      })

    updated = ArchAstro.SDK.Socket.fail_topic_pushes(socket, "room:1", {:topic_closed, :server})
    assert Map.keys(updated.assigns.pending_pushes) == ["2"]
    assert_receive {^closed_tag, {:error, {:topic_closed, :server}}}
    refute_received {^retained_tag, _reply}
  end

  test "normalizes Phoenix JSON error replies to ArchAstro.SDK.Error" do
    tag = make_ref()

    socket =
      Slipstream.Socket.new()
      |> Slipstream.Socket.assign(:pending_pushes, %{
        "1" => %{from: {self(), tag}, topic: "room:1", descriptor: :string}
      })

    assert {:ok, updated} =
             ArchAstro.SDK.Socket.handle_reply(
               "1",
               {:error, %{"code" => "unknown_event", "reason" => "not allowed"}},
               socket
             )

    assert updated.assigns.pending_pushes == %{}

    assert_receive {^tag,
                    {:error, %ArchAstro.SDK.Error{code: "unknown_event", message: "not allowed"}}}
  end

  test "leave removes and fences the local channel before replying" do
    tag = make_ref()
    channel = %ArchAstro.SDK.Channel{socket: self(), topic: "room:1", module: __MODULE__}

    socket =
      Slipstream.Socket.new()
      |> Map.put(:channel_pid, self())
      |> Map.put(:joins, %{
        "room:1" => %Slipstream.Socket.Join{
          topic: "room:1",
          params: %{},
          status: :joined,
          rejoin_counter: 0
        }
      })
      |> Slipstream.Socket.assign(:channels, %{"room:1" => channel})
      |> Slipstream.Socket.assign(:pending_joins, %{})
      |> Slipstream.Socket.assign(:pending_leaves, %{})
      |> Slipstream.Socket.assign(:subscriptions, %{})

    assert {:reply, :ok, left_socket} =
             ArchAstro.SDK.Socket.handle_call({:archastro_leave, "room:1"}, {self(), tag}, socket)

    refute Map.has_key?(left_socket.assigns.channels, "room:1")
    assert Map.has_key?(left_socket.assigns.pending_leaves, "room:1")

    assert {:ok, acknowledged_socket} = ArchAstro.SDK.Socket.handle_leave("room:1", left_socket)
    assert acknowledged_socket.assigns.pending_leaves == %{}
  end

  test "join waits behind an acknowledged leave instead of returning a stale channel" do
    tag = make_ref()
    channel = %ArchAstro.SDK.Channel{socket: self(), topic: "room:1", module: __MODULE__}

    socket =
      Slipstream.Socket.new()
      |> Slipstream.Socket.assign(:channels, %{"room:1" => channel})
      |> Slipstream.Socket.assign(:pending_joins, %{})
      |> Slipstream.Socket.assign(:pending_leaves, %{"room:1" => [{self(), make_ref()}]})

    assert {:noreply, waiting_socket} =
             ArchAstro.SDK.Socket.handle_call(
               {:archastro_join, "room:1", %{}, __MODULE__, {:object, []}},
               {self(), tag},
               socket
             )

    assert waiting_socket.assigns.pending_joins["room:1"].froms == [{self(), tag}]
    refute_received {^tag, {:ok, ^channel}}
  end

  test "rejoins established topics after reconnect with their original payload" do
    channel = %ArchAstro.SDK.Channel{socket: self(), topic: "room:1", module: __MODULE__}

    socket =
      Slipstream.Socket.new()
      |> Map.put(:channel_pid, self())
      |> Map.put(:joins, %{
        "room:1" => %Slipstream.Socket.Join{
          topic: "room:1",
          params: %{"cursor" => "saved"},
          status: :closed,
          rejoin_counter: 0
        }
      })
      |> Slipstream.Socket.assign(:channels, %{"room:1" => channel})
      |> Slipstream.Socket.assign(:pending_joins, %{})
      |> Slipstream.Socket.assign(:pending_leaves, %{})

    assert {:ok, _rejoining_socket} = ArchAstro.SDK.Socket.handle_connect(socket)

    assert_receive {:__slipstream_command__,
                    %Slipstream.Commands.JoinTopic{
                      topic: "room:1",
                      payload: %{"cursor" => "saved"}
                    }}
  end

  test "leave while disconnected does not create an acknowledgement fence" do
    channel = %ArchAstro.SDK.Channel{socket: self(), topic: "room:1", module: __MODULE__}

    socket =
      Slipstream.Socket.new()
      |> Slipstream.Socket.assign(:channels, %{"room:1" => channel})
      |> Slipstream.Socket.assign(:pending_joins, %{})
      |> Slipstream.Socket.assign(:pending_leaves, %{})
      |> Slipstream.Socket.assign(:subscriptions, %{})

    assert {:reply, :ok, left_socket} =
             ArchAstro.SDK.Socket.handle_call(
               {:archastro_leave, "room:1"},
               {self(), make_ref()},
               socket
             )

    assert left_socket.assigns.pending_leaves == %{}
    refute Map.has_key?(left_socket.assigns.channels, "room:1")
  end

  describe "pending entry sweep" do
    test "sweeps pushes and joins that were never acknowledged, keeping fresh ones" do
      stale_push_tag = make_ref()
      fresh_push_tag = make_ref()
      stale_join_tag = make_ref()

      now = System.monotonic_time(:millisecond)
      stale = now - 200_000

      socket =
        Slipstream.Socket.new()
        |> Slipstream.Socket.assign(:channels, %{})
        |> Slipstream.Socket.assign(:subscriptions, %{})
        |> Slipstream.Socket.assign(:pending_pushes, %{
          "1" => %{
            from: {self(), stale_push_tag},
            topic: "room:1",
            descriptor: :string,
            inserted_at: stale
          },
          "2" => %{
            from: {self(), fresh_push_tag},
            topic: "room:1",
            descriptor: :string,
            inserted_at: now
          }
        })
        |> Slipstream.Socket.assign(:pending_joins, %{
          "room:2" => %{
            froms: [{self(), stale_join_tag}],
            payload: %{},
            module: __MODULE__,
            descriptor: :string,
            inserted_at: stale
          }
        })

      assert {:noreply, swept} =
               ArchAstro.SDK.Socket.handle_info(:archastro_sweep_pending, socket)

      assert Map.keys(swept.assigns.pending_pushes) == ["2"]
      assert swept.assigns.pending_joins == %{}

      assert_receive {^stale_push_tag, {:error, %ArchAstro.SDK.Error{code: "no_reply"}}}
      assert_receive {^stale_join_tag, {:error, %ArchAstro.SDK.Error{code: "no_reply"}}}
      refute_received {^fresh_push_tag, _reply}
    end

    test "new pushes and queued joins carry an insertion timestamp" do
      socket =
        Slipstream.Socket.new()
        |> Slipstream.Socket.assign(:channels, %{})
        |> Slipstream.Socket.assign(:pending_joins, %{})
        |> Slipstream.Socket.assign(:pending_leaves, %{"room:1" => true})

      assert {:noreply, queued} =
               ArchAstro.SDK.Socket.handle_call(
                 {:archastro_join, "room:1", %{}, __MODULE__, {:object, []}},
                 {self(), make_ref()},
                 socket
               )

      assert is_integer(queued.assigns.pending_joins["room:1"].inserted_at)
    end
  end

  describe "decode failures do not crash the socket" do
    setup do
      handler_id = "socket-decode-failure-#{inspect(make_ref())}"

      :telemetry.attach(
        handler_id,
        [:archastro, :channel, :decode_failure],
        fn event, _measurements, metadata, pid -> send(pid, {:telemetry, event, metadata}) end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "a malformed broadcast is dropped with telemetry instead of raising" do
      channel = %ArchAstro.SDK.Channel{socket: self(), topic: "room:1", module: __MODULE__}

      socket =
        Slipstream.Socket.new()
        |> Slipstream.Socket.assign(:channels, %{"room:1" => channel})
        |> Slipstream.Socket.assign(:subscriptions, %{
          {"room:1", "evt"} => [%{subscriber: self(), descriptor: :string}]
        })

      assert {:ok, _socket} =
               ArchAstro.SDK.Socket.handle_message("room:1", "evt", %{"bad" => true}, socket)

      refute_received {:archastro_channel, _channel, _event, _payload}

      assert_received {:telemetry, [:archastro, :channel, :decode_failure],
                       %{topic: "room:1", event: "evt", kind: :message}}
    end

    test "a well-formed broadcast is still delivered" do
      channel = %ArchAstro.SDK.Channel{socket: self(), topic: "room:1", module: __MODULE__}

      socket =
        Slipstream.Socket.new()
        |> Slipstream.Socket.assign(:channels, %{"room:1" => channel})
        |> Slipstream.Socket.assign(:subscriptions, %{
          {"room:1", "evt"} => [%{subscriber: self(), descriptor: :string}]
        })

      assert {:ok, _socket} =
               ArchAstro.SDK.Socket.handle_message("room:1", "evt", "hello", socket)

      assert_received {:archastro_channel, ^channel, "evt", "hello"}
    end

    test "an undecodable reply fails only that push" do
      tag = make_ref()

      socket =
        Slipstream.Socket.new()
        |> Slipstream.Socket.assign(:pending_pushes, %{
          "1" => %{from: {self(), tag}, topic: "room:1", descriptor: :string}
        })

      assert {:ok, updated} =
               ArchAstro.SDK.Socket.handle_reply(
                 "1",
                 %{"status" => "ok", "response" => 42},
                 socket
               )

      assert updated.assigns.pending_pushes == %{}
      assert_receive {^tag, {:error, %ArchAstro.SDK.Error{code: "decode_failure"}}}

      assert_received {:telemetry, [:archastro, :channel, :decode_failure],
                       %{topic: "room:1", kind: :reply}}
    end

    test "an empty error reply resolves the push as a channel error" do
      tag = make_ref()

      socket =
        Slipstream.Socket.new()
        |> Slipstream.Socket.assign(:pending_pushes, %{
          "1" => %{from: {self(), tag}, topic: "room:1", descriptor: :string}
        })

      assert {:ok, updated} = ArchAstro.SDK.Socket.handle_reply("1", :error, socket)

      assert updated.assigns.pending_pushes == %{}
      assert_receive {^tag, {:error, %ArchAstro.SDK.Error{} = error}}
      assert error.message == "ArchAstro channel operation failed"
    end

    test "an undecodable join response fails the join instead of the socket" do
      tag = make_ref()

      socket =
        Slipstream.Socket.new()
        |> Slipstream.Socket.assign(:channels, %{})
        |> Slipstream.Socket.assign(:pending_joins, %{
          "room:1" => %{
            froms: [{self(), tag}],
            payload: %{},
            module: __MODULE__,
            descriptor: :string
          }
        })

      assert {:ok, updated} =
               ArchAstro.SDK.Socket.handle_join("room:1", %{"bad" => true}, socket)

      assert updated.assigns.pending_joins == %{}
      refute Map.has_key?(updated.assigns.channels, "room:1")
      assert_receive {^tag, {:error, %ArchAstro.SDK.Error{code: "decode_failure"}}}

      assert_received {:telemetry, [:archastro, :channel, :decode_failure],
                       %{topic: "room:1", kind: :join}}
    end
  end
end
