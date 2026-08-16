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

  test "typed requests still auto-decode application/json bodies" do
    client = client(json_plug(~s({"note":"blob"})))

    assert {:ok, %{"note" => "blob"}} =
             ArchAstro.SDK.HTTP.request(client, :get, "/api/v1/things/thing_1", decode: :unknown)
  end
end
