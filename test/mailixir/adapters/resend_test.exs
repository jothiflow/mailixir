defmodule Mailixir.Adapters.ResendTest do
  use Mailixir.AdapterCase, async: true

  alias Mailixir.Adapters.Resend

  setup %{req_options: req_options} do
    {:ok, config: [adapter: Resend, api_key: "re_123", req_options: req_options]}
  end

  test "full payload", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      assert conn.method == "POST"
      assert conn.host == "api.resend.com"
      assert conn.request_path == "/emails"
      assert_header(conn, "authorization", "Bearer re_123")
      assert_header(conn, "idempotency-key", "idem-1")

      body = json_body(conn)
      assert body["from"] == "Acme <no-reply@acme.com>"
      assert body["to"] == ["Jane <jane@example.com>", "john@example.com"]
      assert body["cc"] == ["cc@example.com"]
      assert body["bcc"] == ["bcc@example.com"]
      assert body["reply_to"] == "Support <support@acme.com>"
      assert body["subject"] == "Welcome"
      assert body["text"] == "Hi"
      assert body["html"] =~ "cid:logo"
      assert body["headers"] == %{"X-Campaign" => "onboarding"}

      assert body["attachments"] == [
               %{
                 "filename" => "guide.pdf",
                 "content" => Base.encode64("PDF"),
                 "content_type" => "application/pdf"
               },
               %{
                 "filename" => "logo.png",
                 "content" => Base.encode64("PNG"),
                 "content_type" => "image/png",
                 "content_id" => "logo"
               }
             ]

      assert body["tags"] == [
               %{"name" => "tag", "value" => "welcome"},
               %{"name" => "tag", "value" => "v2"},
               %{"name" => "user_id", "value" => "42"}
             ]

      assert body["scheduled_at"] == "in 1 hour"
      refute Map.has_key?(body, "template")

      Req.Test.json(conn, %{"id" => "msg_1"})
    end)

    email =
      full_email()
      |> Email.put_provider_option(:scheduled_at, "in 1 hour")
      |> Email.put_provider_option(:idempotency_key, "idem-1")

    assert {:ok, %Response{id: "msg_1", provider: :resend, raw: %{"id" => "msg_1"}}} =
             Mailixir.deliver(email, config)
  end

  test "minimal payload omits empty fields and supports templates", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      body = json_body(conn)
      assert Map.keys(body) |> Enum.sort() == ["from", "subject", "template", "text", "to"]
      assert body["template"] == %{"id" => "tpl_1", "variables" => %{"name" => "Jane"}}
      assert Plug.Conn.get_req_header(conn, "idempotency-key") == []
      Req.Test.json(conn, %{"id" => "msg_2"})
    end)

    email = minimal_email() |> Email.template("tpl_1", %{name: "Jane"})
    assert {:ok, %Response{id: "msg_2"}} = Mailixir.deliver(email, config)
  end

  test "custom base_url", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      assert conn.host == "resend.internal"
      Req.Test.json(conn, %{"id" => "x"})
    end)

    assert {:ok, _} =
             Mailixir.deliver(minimal_email(), config ++ [base_url: "https://resend.internal"])
  end

  test "api error", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      conn
      |> Plug.Conn.put_status(422)
      |> Req.Test.json(%{
        "statusCode" => 422,
        "name" => "validation_error",
        "message" => "Invalid `from`"
      })
    end)

    assert {:error,
            %Error{
              reason: :api_error,
              provider: :resend,
              status: 422,
              message: message,
              details: details
            }} =
             Mailixir.deliver(minimal_email(), config)

    assert message == "HTTP 422: Invalid `from`"
    assert details["name"] == "validation_error"
  end

  test "transport error", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

    assert {:error, %Error{reason: :transport, provider: :resend, details: %Req.TransportError{}}} =
             Mailixir.deliver(minimal_email(), config)
  end

  test "missing api key" do
    assert {:error, %Error{reason: :invalid_config, details: [:api_key]}} =
             Mailixir.deliver(minimal_email(), adapter: Resend)
  end
end
