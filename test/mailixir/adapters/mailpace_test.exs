defmodule Mailixir.Adapters.MailPaceTest do
  use Mailixir.AdapterCase, async: true

  alias Mailixir.Adapters.MailPace

  setup %{req_options: req_options} do
    {:ok, config: [adapter: MailPace, api_key: "mp-token", req_options: req_options]}
  end

  test "full payload", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      assert conn.host == "app.mailpace.com"
      assert conn.request_path == "/api/v1/send"
      assert_header(conn, "mailpace-server-token", "mp-token")

      body = json_body(conn)
      assert body["from"] == "Acme <no-reply@acme.com>"
      assert body["to"] == "Jane <jane@example.com>, john@example.com"
      assert body["cc"] == "cc@example.com"
      assert body["bcc"] == "bcc@example.com"
      assert body["replyto"] == "Support <support@acme.com>"
      assert body["subject"] == "Welcome"
      assert body["textbody"] == "Hi"
      assert body["htmlbody"] =~ "cid:logo"
      assert body["tags"] == ["welcome", "v2"]
      assert body["list_unsubscribe"] == "<mailto:unsub@acme.com>"

      assert body["attachments"] == [
               %{"name" => "guide.pdf", "content" => Base.encode64("PDF"), "content_type" => "application/pdf"},
               %{
                 "name" => "logo.png",
                 "content" => Base.encode64("PNG"),
                 "content_type" => "image/png",
                 "cid" => "logo"
               }
             ]

      Req.Test.json(conn, %{"id" => 1234, "status" => "queued"})
    end)

    email = full_email() |> Email.put_provider_option(:list_unsubscribe, "<mailto:unsub@acme.com>")
    assert {:ok, %Response{id: "1234", provider: :mailpace}} = Mailixir.deliver(email, config)
  end

  test "validation errors", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{"errors" => %{"from" => ["is invalid", "is not verified"], "to" => "is blank"}})
    end)

    assert {:error, %Error{status: 400, message: "HTTP 400: from: is invalid, is not verified; to: is blank"}} =
             Mailixir.deliver(minimal_email(), config)
  end

  test "auth error", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => "Invalid API Token"})
    end)

    assert {:error, %Error{status: 401, message: "HTTP 401: Invalid API Token"}} =
             Mailixir.deliver(minimal_email(), config)
  end
end
