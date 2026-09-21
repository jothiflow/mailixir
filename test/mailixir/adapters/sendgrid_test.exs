defmodule Mailixir.Adapters.SendGridTest do
  use Mailixir.AdapterCase, async: true

  alias Mailixir.Adapters.SendGrid

  setup %{req_options: req_options} do
    {:ok, config: [adapter: SendGrid, api_key: "SG.key", req_options: req_options]}
  end

  test "full payload", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      assert conn.host == "api.sendgrid.com"
      assert conn.request_path == "/v3/mail/send"
      assert_header(conn, "authorization", "Bearer SG.key")

      body = json_body(conn)

      assert body["personalizations"] == [
               %{
                 "to" => [%{"email" => "jane@example.com", "name" => "Jane"}, %{"email" => "john@example.com"}],
                 "cc" => [%{"email" => "cc@example.com"}],
                 "bcc" => [%{"email" => "bcc@example.com"}]
               }
             ]

      assert body["from"] == %{"email" => "no-reply@acme.com", "name" => "Acme"}
      assert body["reply_to"] == %{"email" => "support@acme.com", "name" => "Support"}
      assert body["subject"] == "Welcome"
      assert [%{"type" => "text/plain", "value" => "Hi"}, %{"type" => "text/html", "value" => html}] = body["content"]
      assert html =~ "cid:logo"
      assert body["headers"] == %{"X-Campaign" => "onboarding"}
      assert body["categories"] == ["welcome", "v2"]
      assert body["custom_args"] == %{"user_id" => "42"}
      assert body["send_at"] == 1_900_000_000
      assert body["asm"] == %{"group_id" => 7}

      assert body["attachments"] == [
               %{
                 "content" => Base.encode64("PDF"),
                 "type" => "application/pdf",
                 "filename" => "guide.pdf",
                 "disposition" => "attachment"
               },
               %{
                 "content" => Base.encode64("PNG"),
                 "type" => "image/png",
                 "filename" => "logo.png",
                 "disposition" => "inline",
                 "content_id" => "logo"
               }
             ]

      conn |> Plug.Conn.put_resp_header("x-message-id", "sg-1") |> Plug.Conn.send_resp(202, "")
    end)

    email =
      full_email()
      |> Email.put_provider_option(:send_at, 1_900_000_000)
      |> Email.put_provider_option(:asm, %{group_id: 7})

    assert {:ok, %Response{id: "sg-1", provider: :sendgrid}} = Mailixir.deliver(email, config)
  end

  test "dynamic template", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      body = json_body(conn)
      assert body["template_id"] == "d-123"
      assert [%{"dynamic_template_data" => %{"name" => "Jane"}}] = body["personalizations"]
      refute Map.has_key?(body, "content")
      Plug.Conn.send_resp(conn, 202, "")
    end)

    email = Email.new(from: "a@x.com", to: "b@x.com") |> Email.template("d-123", %{name: "Jane"})
    assert {:ok, %Response{id: nil}} = Mailixir.deliver(email, config)
  end

  test "api error lists fields", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{
        "errors" => [
          %{"message" => "The from email does not contain a valid address.", "field" => "from.email", "help" => nil}
        ]
      })
    end)

    assert {:error,
            %Error{status: 400, message: "HTTP 400: The from email does not contain a valid address. (from.email)"}} =
             Mailixir.deliver(minimal_email(), config)
  end
end
