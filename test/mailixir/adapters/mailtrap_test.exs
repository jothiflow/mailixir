defmodule Mailixir.Adapters.MailtrapTest do
  use Mailixir.AdapterCase, async: true

  alias Mailixir.Adapters.Mailtrap

  setup %{req_options: req_options} do
    {:ok, config: [adapter: Mailtrap, api_key: "mt-token", req_options: req_options]}
  end

  test "full payload to the sending API", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      assert conn.host == "send.api.mailtrap.io"
      assert conn.request_path == "/api/send"
      assert_header(conn, "api-token", "mt-token")

      body = json_body(conn)
      assert body["from"] == %{"email" => "no-reply@acme.com", "name" => "Acme"}
      assert body["to"] == [%{"email" => "jane@example.com", "name" => "Jane"}, %{"email" => "john@example.com"}]
      assert body["cc"] == [%{"email" => "cc@example.com"}]
      assert body["bcc"] == [%{"email" => "bcc@example.com"}]
      assert body["reply_to"] == %{"email" => "support@acme.com", "name" => "Support"}
      assert body["subject"] == "Welcome"
      assert body["text"] == "Hi"
      assert body["html"] =~ "cid:logo"
      assert body["headers"] == %{"X-Campaign" => "onboarding"}
      assert body["category"] == "welcome"
      assert body["custom_variables"] == %{"user_id" => "42"}

      assert [%{"disposition" => "attachment"}, %{"disposition" => "inline", "content_id" => "logo"}] =
               body["attachments"]

      Req.Test.json(conn, %{"success" => true, "message_ids" => ["mt-1"]})
    end)

    assert {:ok, %Response{id: "mt-1", provider: :mailtrap}} = Mailixir.deliver(full_email(), config)
  end

  test "endpoint selection" do
    assert Mailtrap.endpoint([]) == {"https://send.api.mailtrap.io", "/api/send"}
    assert Mailtrap.endpoint(bulk: true) == {"https://bulk.api.mailtrap.io", "/api/send"}
    assert Mailtrap.endpoint(inbox_id: 42) == {"https://sandbox.api.mailtrap.io", "/api/send/42"}
  end

  test "sandbox inbox and template", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      assert conn.host == "sandbox.api.mailtrap.io"
      assert conn.request_path == "/api/send/42"
      body = json_body(conn)
      assert body["template_uuid"] == "uuid-1"
      assert body["template_variables"] == %{"name" => "Jane"}
      Req.Test.json(conn, %{"success" => true, "message_ids" => ["mt-2"]})
    end)

    email = Email.new(from: "a@x.com", to: "b@x.com") |> Email.template("uuid-1", %{name: "Jane"})
    assert {:ok, %Response{id: "mt-2"}} = Mailixir.deliver(email, config ++ [inbox_id: 42])
  end

  test "api error", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{"success" => false, "errors" => ["Unauthorized", "Bad token"]})
    end)

    assert {:error, %Error{status: 401, message: "HTTP 401: Unauthorized; Bad token"}} =
             Mailixir.deliver(minimal_email(), config)
  end
end
