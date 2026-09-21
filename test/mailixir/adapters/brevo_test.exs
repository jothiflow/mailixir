defmodule Mailixir.Adapters.BrevoTest do
  use Mailixir.AdapterCase, async: true

  alias Mailixir.Adapters.Brevo

  setup %{req_options: req_options} do
    {:ok, config: [adapter: Brevo, api_key: "xkeysib-1", req_options: req_options]}
  end

  test "full payload", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      assert conn.method == "POST"
      assert conn.host == "api.brevo.com"
      assert conn.request_path == "/v3/smtp/email"
      assert_header(conn, "api-key", "xkeysib-1")

      body = json_body(conn)
      assert body["sender"] == %{"name" => "Acme", "email" => "no-reply@acme.com"}

      assert body["to"] == [
               %{"name" => "Jane", "email" => "jane@example.com"},
               %{"email" => "john@example.com"}
             ]

      assert body["cc"] == [%{"email" => "cc@example.com"}]
      assert body["bcc"] == [%{"email" => "bcc@example.com"}]
      assert body["replyTo"] == %{"name" => "Support", "email" => "support@acme.com"}
      assert body["subject"] == "Welcome"
      assert body["textContent"] == "Hi"
      assert body["htmlContent"] =~ "cid:logo"

      assert body["headers"] == %{
               "X-Campaign" => "onboarding",
               "X-Mailin-custom" => ~s({"user_id":"42"})
             }

      assert body["attachment"] == [
               %{"name" => "guide.pdf", "content" => Base.encode64("PDF")},
               %{"name" => "logo.png", "content" => Base.encode64("PNG")}
             ]

      assert body["tags"] == ["welcome", "v2"]
      assert body["scheduledAt"] == "2030-01-01T00:00:00Z"
      assert body["batchId"] == "batch-1"
      refute Map.has_key?(body, "templateId")

      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(%{"messageId" => "<1@smtp-relay.mailin.fr>"})
    end)

    email =
      full_email()
      |> Email.put_provider_option(:scheduled_at, "2030-01-01T00:00:00Z")
      |> Email.put_provider_option(:batch_id, "batch-1")

    assert {:ok, %Response{id: "1@smtp-relay.mailin.fr", provider: :brevo}} =
             Mailixir.deliver(email, config)
  end

  test "template payload", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      body = json_body(conn)
      assert body["templateId"] == 7
      assert body["params"] == %{"name" => "Jane"}
      refute Map.has_key?(body, "headers")
      refute Map.has_key?(body, "subject")
      Req.Test.json(conn, %{"messageId" => "m"})
    end)

    email = Email.new(from: "a@x.com", to: "b@x.com") |> Email.template(7, %{name: "Jane"})
    assert {:ok, %Response{id: "m"}} = Mailixir.deliver(email, config)
  end

  test "api error", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{"code" => "unauthorized", "message" => "Key not found"})
    end)

    assert {:error,
            %Error{
              reason: :api_error,
              provider: :brevo,
              status: 401,
              message: "HTTP 401: Key not found"
            }} =
             Mailixir.deliver(minimal_email(), config)
  end

  test "missing api key" do
    assert {:error, %Error{reason: :invalid_config}} =
             Mailixir.deliver(minimal_email(), adapter: Brevo)
  end
end
