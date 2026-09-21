defmodule Mailixir.Adapters.MandrillTest do
  use Mailixir.AdapterCase, async: true

  alias Mailixir.Adapters.Mandrill

  setup %{req_options: req_options} do
    {:ok, config: [adapter: Mandrill, api_key: "md-key", req_options: req_options]}
  end

  test "full payload", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      assert conn.method == "POST"
      assert conn.host == "mandrillapp.com"
      assert conn.request_path == "/api/1.0/messages/send"

      body = json_body(conn)
      assert body["key"] == "md-key"
      assert body["async"] == true
      assert body["ip_pool"] == "Main Pool"
      refute Map.has_key?(body, "template_name")

      message = body["message"]
      assert message["from_email"] == "no-reply@acme.com"
      assert message["from_name"] == "Acme"

      assert message["to"] == [
               %{"email" => "jane@example.com", "name" => "Jane", "type" => "to"},
               %{"email" => "john@example.com", "type" => "to"},
               %{"email" => "cc@example.com", "type" => "cc"},
               %{"email" => "bcc@example.com", "type" => "bcc"}
             ]

      assert message["subject"] == "Welcome"
      assert message["text"] == "Hi"
      assert message["html"] =~ "cid:logo"

      assert message["headers"] == %{
               "X-Campaign" => "onboarding",
               "Reply-To" => "Support <support@acme.com>"
             }

      assert message["attachments"] == [
               %{
                 "type" => "application/pdf",
                 "name" => "guide.pdf",
                 "content" => Base.encode64("PDF")
               }
             ]

      assert message["images"] == [
               %{"type" => "image/png", "name" => "logo", "content" => Base.encode64("PNG")}
             ]

      assert message["tags"] == ["welcome", "v2"]
      assert message["metadata"] == %{"user_id" => "42"}
      assert message["track_opens"] == true
      refute Map.has_key?(message, "global_merge_vars")

      Req.Test.json(conn, [
        %{
          "email" => "jane@example.com",
          "status" => "sent",
          "_id" => "abc",
          "reject_reason" => nil
        }
      ])
    end)

    email =
      full_email()
      |> Email.put_provider_option(:async, true)
      |> Email.put_provider_option(:ip_pool, "Main Pool")
      |> Email.put_provider_option(:track_opens, true)

    assert {:ok, %Response{id: "abc", provider: :mandrill, raw: [_]}} =
             Mailixir.deliver(email, config)
  end

  test "template payload uses send-template", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      assert conn.request_path == "/api/1.0/messages/send-template"
      body = json_body(conn)
      assert body["template_name"] == "welcome"
      assert body["template_content"] == [%{"name" => "main", "content" => "<p>x</p>"}]
      assert body["message"]["global_merge_vars"] == [%{"name" => "name", "content" => "Jane"}]
      assert body["message"]["merge_language"] == "handlebars"
      Req.Test.json(conn, [%{"email" => "b@x.com", "status" => "queued", "_id" => "q1"}])
    end)

    email =
      Email.new(from: "a@x.com", to: "b@x.com")
      |> Email.template("welcome", %{name: "Jane"})
      |> Email.put_provider_option(:template_content, [%{name: "main", content: "<p>x</p>"}])
      |> Email.put_provider_option(:merge_language, "handlebars")

    assert {:ok, %Response{id: "q1"}} = Mailixir.deliver(email, config)
  end

  test "rejected recipient is an error", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      Req.Test.json(conn, [
        %{"email" => "a@x.com", "status" => "sent", "_id" => "1"},
        %{
          "email" => "b@x.com",
          "status" => "rejected",
          "_id" => "2",
          "reject_reason" => "hard-bounce"
        },
        %{"email" => "c@x.com", "status" => "invalid", "_id" => "3", "reject_reason" => nil}
      ])
    end)

    assert {:error,
            %Error{
              reason: :api_error,
              provider: :mandrill,
              status: 200,
              message: message,
              details: [_, _, _]
            }} =
             Mailixir.deliver(minimal_email(), config)

    assert message == "HTTP 200: b@x.com: rejected (hard-bounce); c@x.com: invalid (no reason)"
  end

  test "api error", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      conn
      |> Plug.Conn.put_status(500)
      |> Req.Test.json(%{
        "status" => "error",
        "code" => -1,
        "name" => "Invalid_Key",
        "message" => "Invalid API key"
      })
    end)

    assert {:error, %Error{status: 500, message: "HTTP 500: Invalid API key"}} =
             Mailixir.deliver(minimal_email(), config)
  end
end
