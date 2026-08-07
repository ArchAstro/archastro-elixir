defmodule ArchAstro.SSETest do
  use ExUnit.Case, async: true

  test "parses events framed with bare carriage returns" do
    assert {[%ArchAstro.SSE.Event{event: "message", data: %{"ok" => true}}], ""} =
             ArchAstro.SSE.parse_events("event: message\rdata: {\"ok\":true}\r\r")
  end

  test "preserves a CRLF separator split across chunks" do
    assert {[], buffer} = ArchAstro.SSE.parse_events("data: {\"ok\":true}\r")

    assert {[%ArchAstro.SSE.Event{data: %{"ok" => true}}], ""} =
             ArchAstro.SSE.parse_events(buffer <> "\n\r\n")
  end

  test "stream enumeration leaves unrelated caller messages in the mailbox" do
    server =
      start_supervised!(
        {ArchAstro.TokenServer.Default,
         mode: {:system_user, publishable_key: "pk", access_token: "token"}}
      )

    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
      |> Plug.Conn.send_resp(200, "data: {\"ok\":true}\n\n")
    end

    assert {:ok, client} = ArchAstro.Client.for_server(server, req: Req.new(plug: plug))
    send(self(), :unrelated)

    assert [%ArchAstro.SSE.Event{data: %{"ok" => true}}] =
             ArchAstro.SSE.stream(client, :get, "/events") |> Enum.to_list()

    assert_received :unrelated
  end

  test "removes only one optional space after an SSE field colon" do
    assert {[%ArchAstro.SSE.Event{event: "  note", data: "  hello"}], ""} =
             ArchAstro.SSE.parse_events("event:   note\ndata:   hello\n\n")
  end

  test "defaults unnamed SSE events to message" do
    assert {[%ArchAstro.SSE.Event{event: "message", data: %{"ok" => true}}], ""} =
             ArchAstro.SSE.parse_events("data: {\"ok\":true}\n\n")

    assert {[%ArchAstro.SSE.Event{event: "message", data: %{"ok" => true}}], ""} =
             ArchAstro.SSE.parse_events("event:\ndata: {\"ok\":true}\n\n")
  end

  test "replaces malformed UTF-8 without suppressing later events" do
    input = <<0xFF>> <> "\n\ndata: {\"ok\":true}\n\n"

    assert {[%ArchAstro.SSE.Event{data: %{"ok" => true}}], ""} =
             ArchAstro.SSE.parse_events(input)
  end

  test "implements colonless, id, and retry field semantics" do
    input = "data\nid: keep\nid: bad#{<<0>>}value\nretry: invalid\nretry: 1500\n\n"

    assert {[%ArchAstro.SSE.Event{data: "", id: "keep", retry: 1500}], ""} =
             ArchAstro.SSE.parse_events(input)
  end

  test "ignores exactly one UTF-8 BOM at the start of a stream" do
    assert {[%ArchAstro.SSE.Event{data: "first"}], ""} =
             ArchAstro.SSE.parse_events(<<0xEF, 0xBB, 0xBF>> <> "data: first\n\n")

    assert {[], _buffer} =
             ArchAstro.SSE.parse_events(<<0xEF, 0xBB, 0xBF>> <> "data: later\n\n", false)
  end

  test "buffers a UTF-8 BOM split across transport chunks" do
    assert {[], first} = ArchAstro.SSE.parse_events(<<0xEF>>)

    assert {[%ArchAstro.SSE.Event{data: "first"}], ""} =
             ArchAstro.SSE.parse_events(first <> <<0xBB, 0xBF>> <> "data: first\n\n")
  end

  test "rejects successful responses that are not event streams" do
    server =
      start_supervised!(
        {ArchAstro.TokenServer.Default,
         mode: {:system_user, publishable_key: "pk", access_token: "token"}}
      )

    plug = fn conn -> Req.Test.json(conn, %{"ok" => true}) end
    assert {:ok, client} = ArchAstro.Client.for_server(server, req: Req.new(plug: plug))

    assert_raise ArchAstro.Error, fn ->
      ArchAstro.SSE.stream(client, :get, "/events") |> Enum.to_list()
    end
  end

  test "raises a typed error for an async non-success response" do
    server =
      start_supervised!(
        {ArchAstro.TokenServer.Default,
         mode: {:system_user, publishable_key: "pk", access_token: "token"}}
      )

    plug = fn conn ->
      conn
      |> Plug.Conn.put_status(402)
      |> Req.Test.json(%{
        "error" => %{
          "code" => "plan_not_entitled",
          "message" => "not entitled",
          "details" => %{"plan" => "free"}
        }
      })
    end

    assert {:ok, client} = ArchAstro.Client.for_server(server, req: Req.new(plug: plug))

    error =
      assert_raise ArchAstro.Error, fn ->
        ArchAstro.SSE.stream(client, :get, "/events") |> Enum.to_list()
      end

    assert error.status == 402
    assert error.code == "plan_not_entitled"
    assert error.message == "not entitled"
    assert error.details == %{"plan" => "free"}
  end
end
