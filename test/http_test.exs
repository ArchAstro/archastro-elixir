# Copyright (c) 2026 ArchAstro Inc. Licensed under the MIT License.

defmodule ArchAstro.SDK.HTTPTest do
  use ExUnit.Case, async: true

  alias ArchAstro.SDK.{Client, TokenServer}

  defp client(plug) do
    server =
      start_supervised!(
        {TokenServer.Default, mode: {:system_user, publishable_key: "pk", access_token: "token"}}
      )

    {:ok, client} = Client.for_server(server, req: Req.new(plug: plug))
    client
  end

  defp json_plug(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  test "raw requests deliver an application/json body as the raw binary" do
    raw_body = ~s({"steps":[{"n":1}],"note":"blob"})
    client = client(json_plug(raw_body))

    assert {:ok, %Req.Response{} = response} =
             ArchAstro.SDK.HTTP.request(client, :get, "/api/v1/trajectories/tra_1/contents",
               raw: true
             )

    assert response.body == raw_body
  end

  test "raw requests keep structured API errors on failure responses" do
    error_plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        404,
        ~s({"error":{"message":"Trajectory not found","code":"not_found"}})
      )
    end

    client = client(error_plug)

    assert {:error, %ArchAstro.SDK.Error{} = error} =
             ArchAstro.SDK.HTTP.request(client, :get, "/api/v1/trajectories/tra_1/contents",
               raw: true
             )

    assert error.status == 404
    assert error.message == "Trajectory not found"
    assert error.code == "not_found"
  end

  test "raw requests tolerate a non-JSON failure body" do
    error_plug = fn conn -> Plug.Conn.send_resp(conn, 502, "upstream exploded") end
    client = client(error_plug)

    assert {:error, %ArchAstro.SDK.Error{status: 502} = error} =
             ArchAstro.SDK.HTTP.request(client, :get, "/api/v1/files/file_1/avatar", raw: true)

    assert error.message == "ArchAstro API returned HTTP 502"
  end

  test "typed requests still auto-decode application/json bodies" do
    client = client(json_plug(~s({"note":"blob"})))

    assert {:ok, %{"note" => "blob"}} =
             ArchAstro.SDK.HTTP.request(client, :get, "/api/v1/things/thing_1", decode: :unknown)
  end
end
