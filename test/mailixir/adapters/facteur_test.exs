defmodule Mailixir.Adapters.FacteurTest do
  use Mailixir.AdapterCase, async: true

  alias Mailixir.Adapters.Facteur

  setup %{req_options: req_options} do
    {:ok,
     config: [
       adapter: Facteur,
       api_key: "fk_123",
       base_url: "https://mail.acme.com",
       req_options: req_options
     ]}
  end

  defp accepted(conn, id \\ "6f0d") do
    Req.Test.json(Plug.Conn.put_status(conn, 202), %{"data" => %{"id" => id, "subject" => "Welcome"}})
  end

  test "full payload", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      assert conn.method == "POST"
      assert conn.host == "mail.acme.com"
      assert conn.request_path == "/api/v1/emails"
      assert_header(conn, "authorization", "Bearer fk_123")
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
      assert body["tags"] == ["welcome", "v2"]
      assert body["metadata"] == %{"user_id" => "42"}

      assert body["attachments"] == [
               %{
                 "filename" => "guide.pdf",
                 "content_type" => "application/pdf",
                 "content" => Base.encode64("PDF")
               },
               %{
                 "filename" => "logo.png",
                 "content_type" => "image/png",
                 "content" => Base.encode64("PNG"),
                 "disposition" => "inline",
                 "content_id" => "logo"
               }
             ]

      accepted(conn)
    end)

    email = %{full_email() | provider_options: %{idempotency_key: "idem-1"}}

    assert {:ok, %Response{id: "6f0d", provider: :facteur, raw: %{"subject" => "Welcome"}}} =
             Mailixir.deliver(email, config)
  end

  test "minimal payload omits empty fields", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      body = json_body(conn)
      assert body |> Map.keys() |> Enum.sort() == ["from", "subject", "text", "to"]
      assert Plug.Conn.get_req_header(conn, "idempotency-key") == []
      accepted(conn)
    end)

    assert {:ok, %Response{id: "6f0d"}} = Mailixir.deliver(minimal_email(), config)
  end

  test "list_unsubscribe is passed through in Facteur's shape", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      send(self(), {:list_unsubscribe, json_body(conn)["list_unsubscribe"]})
      accepted(conn)
    end)

    for {option, sent} <- [
          {:none, "none"},
          {:facteur, "facteur"},
          {[url: "https://acme.com/prefs"], %{"url" => "https://acme.com/prefs"}},
          {%{url: "https://acme.com/prefs", mailto: "unsub@acme.com"},
           %{"url" => "https://acme.com/prefs", "mailto" => "unsub@acme.com"}}
        ] do
      email = %{minimal_email() | provider_options: %{list_unsubscribe: option}}
      assert {:ok, _} = Mailixir.deliver(email, config)
      assert_received {:list_unsubscribe, ^sent}
    end
  end

  test "an idempotent replay is a success too", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      Req.Test.json(Plug.Conn.put_status(conn, 200), %{"data" => %{"id" => "original"}})
    end)

    assert {:ok, %Response{id: "original"}} = Mailixir.deliver(minimal_email(), config)
  end

  test "validation errors carry the status and details", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      Req.Test.json(Plug.Conn.put_status(conn, 422), %{
        "error" => %{
          "type" => "validation_error",
          "message" => "Validation failed",
          "details" => %{"from" => ["acme.com is not verified yet"]}
        }
      })
    end)

    assert {:error, %Error{reason: :api_error, status: 422} = error} =
             Mailixir.deliver(minimal_email(), config)

    assert error.message == "HTTP 422: Validation failed"
    assert error.details["error"]["details"] == %{"from" => ["acme.com is not verified yet"]}
  end

  test "an unauthorized key is an api error", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      Req.Test.json(Plug.Conn.put_status(conn, 401), %{
        "error" => %{"type" => "unauthorized", "message" => "Invalid or revoked API key"}
      })
    end)

    assert {:error, %Error{reason: :api_error, status: 401, message: message}} =
             Mailixir.deliver(minimal_email(), config)

    assert message == "HTTP 401: Invalid or revoked API key"
  end

  test "templates are unsupported", %{config: config} do
    email = Mailixir.Email.new(from: "a@x.com", to: "b@x.com", subject: "S", template: "welcome")

    assert {:error, %Error{reason: :unsupported, provider: :facteur}} =
             Mailixir.deliver(email, config)
  end

  test "api_key and base_url are required" do
    assert {:error, %Error{reason: :invalid_config, details: [:api_key, :base_url]}} =
             Mailixir.deliver(minimal_email(), adapter: Facteur)
  end
end
