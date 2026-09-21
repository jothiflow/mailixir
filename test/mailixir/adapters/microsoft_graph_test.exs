defmodule Mailixir.Adapters.MicrosoftGraphTest do
  use Mailixir.AdapterCase, async: true

  alias Mailixir.Adapters.MicrosoftGraph

  setup %{req_options: req_options} do
    {:ok, config: [adapter: MicrosoftGraph, access_token: "ms-token", req_options: req_options]}
  end

  test "full payload to /me", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      assert conn.host == "graph.microsoft.com"
      assert conn.request_path == "/v1.0/me/sendMail"
      assert_header(conn, "authorization", "Bearer ms-token")

      body = json_body(conn)
      assert body["saveToSentItems"] == false
      message = body["message"]
      assert message["subject"] == "Welcome"
      assert message["body"]["contentType"] == "HTML"
      assert message["body"]["content"] =~ "cid:logo"
      assert message["from"] == %{"emailAddress" => %{"address" => "no-reply@acme.com", "name" => "Acme"}}

      assert message["toRecipients"] == [
               %{"emailAddress" => %{"address" => "jane@example.com", "name" => "Jane"}},
               %{"emailAddress" => %{"address" => "john@example.com"}}
             ]

      assert message["ccRecipients"] == [%{"emailAddress" => %{"address" => "cc@example.com"}}]
      assert message["bccRecipients"] == [%{"emailAddress" => %{"address" => "bcc@example.com"}}]
      assert message["replyTo"] == [%{"emailAddress" => %{"address" => "support@acme.com", "name" => "Support"}}]
      assert message["internetMessageHeaders"] == [%{"name" => "X-Campaign", "value" => "onboarding"}]
      assert message["categories"] == ["welcome", "v2"]
      assert message["importance"] == "high"

      assert message["attachments"] == [
               %{
                 "@odata.type" => "#microsoft.graph.fileAttachment",
                 "name" => "guide.pdf",
                 "contentType" => "application/pdf",
                 "contentBytes" => Base.encode64("PDF"),
                 "isInline" => false
               },
               %{
                 "@odata.type" => "#microsoft.graph.fileAttachment",
                 "name" => "logo.png",
                 "contentType" => "image/png",
                 "contentBytes" => Base.encode64("PNG"),
                 "isInline" => true,
                 "contentId" => "logo"
               }
             ]

      Plug.Conn.send_resp(conn, 202, "")
    end)

    email =
      full_email()
      |> Email.put_provider_option(:save_to_sent_items, false)
      |> Email.put_provider_option(:importance, "high")

    assert {:ok, %Response{id: nil, provider: :microsoft_graph}} = Mailixir.deliver(email, config)
  end

  test "text body and explicit user", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      assert conn.request_path == "/v1.0/users/bob@acme.com/sendMail"
      body = json_body(conn)
      assert body["message"]["body"] == %{"contentType" => "Text", "content" => "T"}
      assert body["saveToSentItems"] == true
      Plug.Conn.send_resp(conn, 202, "")
    end)

    assert {:ok, _} = Mailixir.deliver(minimal_email(), config ++ [user_id: "bob@acme.com"])
  end

  test "api error", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      conn
      |> Plug.Conn.put_status(403)
      |> Req.Test.json(%{"error" => %{"code" => "ErrorAccessDenied", "message" => "Access is denied."}})
    end)

    assert {:error, %Error{status: 403, message: "HTTP 403: ErrorAccessDenied: Access is denied."}} =
             Mailixir.deliver(minimal_email(), config)
  end
end
