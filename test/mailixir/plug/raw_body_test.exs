defmodule Mailixir.Plug.RawBodyTest do
  use ExUnit.Case, async: true

  import Plug.Test

  @parsers Plug.Parsers.init(parsers: [:json], json_decoder: JSON, body_reader: {Mailixir.Plug.RawBody, :read_body, []})

  test "keeps the raw body for webhook paths" do
    body = ~s({"a": 1})

    conn =
      conn(:post, "/webhooks/mailgun", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Parsers.call(@parsers)

    assert conn.assigns.raw_body == body
    assert conn.body_params == %{"a" => 1}
  end

  test "skips other paths" do
    conn =
      conn(:post, "/api/things", ~s({"a": 1}))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Parsers.call(@parsers)

    refute Map.has_key?(conn.assigns, :raw_body)
  end
end
