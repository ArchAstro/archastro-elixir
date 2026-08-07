defmodule ArchAstro.SocketTest do
  use ExUnit.Case, async: true

  alias ArchAstro.Auth.TokenSet

  test "concurrent joins to one topic retain and reply to every waiter" do
    first_tag = make_ref()
    second_tag = make_ref()

    socket =
      Slipstream.Socket.new()
      |> Slipstream.Socket.assign(:channels, %{})
      |> Slipstream.Socket.assign(:pending_joins, %{})

    assert {:noreply, pending_socket} =
             ArchAstro.Socket.handle_call(
               {:archastro_join, "room:1", %{}, __MODULE__, {:object, []}},
               {self(), first_tag},
               socket
             )

    assert {:noreply, coalesced_socket} =
             ArchAstro.Socket.handle_call(
               {:archastro_join, "room:1", %{}, __MODULE__, {:object, []}},
               {self(), second_tag},
               pending_socket
             )

    assert length(coalesced_socket.assigns.pending_joins["room:1"].froms) == 2
    assert {:ok, _joined_socket} = ArchAstro.Socket.handle_join("room:1", %{}, coalesced_socket)
    assert_receive {^first_tag, {:ok, %ArchAstro.Channel{topic: "room:1"}}}
    assert_receive {^second_tag, {:ok, %ArchAstro.Channel{topic: "room:1"}}}
  end

  test "refreshes expired credentials before channel connection or reconnect" do
    counter = start_supervised!({Agent, fn -> 0 end})

    plug = fn conn ->
      Agent.update(counter, &(&1 + 1))
      Req.Test.json(conn, %{"access_token" => "fresh", "refresh_token" => "rotated"})
    end

    server =
      start_supervised!(
        {ArchAstro.TokenServer.Default,
         mode: {:sessions, publishable_key: "pk"},
         base_url: "http://test",
         req: Req.new(plug: plug, retry: false)}
      )

    assert :ok =
             ArchAstro.TokenServer.put_session(server, "session", %TokenSet{
               access_token: "expired",
               refresh_token: "refresh",
               expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
             })

    assert {:ok, client} = ArchAstro.Client.for_session(server, "session")
    assert {:ok, authorization} = ArchAstro.Socket.ensure_fresh_authorization(client)
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

    cleared = ArchAstro.Socket.fail_pending_pushes(socket, :transport_closed)
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

    updated = ArchAstro.Socket.fail_topic_pushes(socket, "room:1", {:topic_closed, :server})
    assert Map.keys(updated.assigns.pending_pushes) == ["2"]
    assert_receive {^closed_tag, {:error, {:topic_closed, :server}}}
    refute_received {^retained_tag, _reply}
  end

  test "normalizes Phoenix JSON error replies to ArchAstro.Error" do
    tag = make_ref()

    socket =
      Slipstream.Socket.new()
      |> Slipstream.Socket.assign(:pending_pushes, %{
        "1" => %{from: {self(), tag}, topic: "room:1", descriptor: :string}
      })

    assert {:ok, updated} =
             ArchAstro.Socket.handle_reply(
               "1",
               {:error, %{"code" => "unknown_event", "reason" => "not allowed"}},
               socket
             )

    assert updated.assigns.pending_pushes == %{}

    assert_receive {^tag, {:error, %ArchAstro.Error{code: "unknown_event", message: "not allowed"}}}
  end

  test "leave removes and fences the local channel before replying" do
    tag = make_ref()
    channel = %ArchAstro.Channel{socket: self(), topic: "room:1", module: __MODULE__}

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
             ArchAstro.Socket.handle_call({:archastro_leave, "room:1"}, {self(), tag}, socket)

    refute Map.has_key?(left_socket.assigns.channels, "room:1")
    assert Map.has_key?(left_socket.assigns.pending_leaves, "room:1")

    assert {:ok, acknowledged_socket} = ArchAstro.Socket.handle_leave("room:1", left_socket)
    assert acknowledged_socket.assigns.pending_leaves == %{}
  end

  test "join waits behind an acknowledged leave instead of returning a stale channel" do
    tag = make_ref()
    channel = %ArchAstro.Channel{socket: self(), topic: "room:1", module: __MODULE__}

    socket =
      Slipstream.Socket.new()
      |> Slipstream.Socket.assign(:channels, %{"room:1" => channel})
      |> Slipstream.Socket.assign(:pending_joins, %{})
      |> Slipstream.Socket.assign(:pending_leaves, %{"room:1" => [{self(), make_ref()}]})

    assert {:noreply, waiting_socket} =
             ArchAstro.Socket.handle_call(
               {:archastro_join, "room:1", %{}, __MODULE__, {:object, []}},
               {self(), tag},
               socket
             )

    assert waiting_socket.assigns.pending_joins["room:1"].froms == [{self(), tag}]
    refute_received {^tag, {:ok, ^channel}}
  end

  test "rejoins established topics after reconnect with their original payload" do
    channel = %ArchAstro.Channel{socket: self(), topic: "room:1", module: __MODULE__}

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

    assert {:ok, _rejoining_socket} = ArchAstro.Socket.handle_connect(socket)

    assert_receive {:__slipstream_command__,
                    %Slipstream.Commands.JoinTopic{
                      topic: "room:1",
                      payload: %{"cursor" => "saved"}
                    }}
  end

  test "leave while disconnected does not create an acknowledgement fence" do
    channel = %ArchAstro.Channel{socket: self(), topic: "room:1", module: __MODULE__}

    socket =
      Slipstream.Socket.new()
      |> Slipstream.Socket.assign(:channels, %{"room:1" => channel})
      |> Slipstream.Socket.assign(:pending_joins, %{})
      |> Slipstream.Socket.assign(:pending_leaves, %{})
      |> Slipstream.Socket.assign(:subscriptions, %{})

    assert {:reply, :ok, left_socket} =
             ArchAstro.Socket.handle_call(
               {:archastro_leave, "room:1"},
               {self(), make_ref()},
               socket
             )

    assert left_socket.assigns.pending_leaves == %{}
    refute Map.has_key?(left_socket.assigns.channels, "room:1")
  end
end
