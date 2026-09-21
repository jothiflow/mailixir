defmodule Mailixir.Adapters.PostalTest do
  use Mailixir.AdapterCase, async: true

  alias Mailixir.Adapters.Postal

  setup %{req_options: req_options} do
    {:ok,
     config: [adapter: Postal, api_key: "postal-key", base_url: "https://postal.acme.com", req_options: req_options]}
  end

  test "full payload", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      assert conn.host == "postal.acme.com"
      assert conn.request_path == "/api/v1/send/message"
      assert_header(conn, "x-server-api-key", "postal-key")

      body = json_body(conn)
      assert body["from"] == "Acme <no-reply@acme.com>"
      assert body["to"] == ["Jane <jane@example.com>", "john@example.com"]
      assert body["cc"] == ["cc@example.com"]
      assert body["bcc"] == ["bcc@example.com"]
      assert body["reply_to"] == "Support <support@acme.com>"
      assert body["subject"] == "Welcome"
      assert body["tag"] == "welcome"
      assert body["plain_body"] == "Hi"
      assert body["html_body"] =~ "cid:logo"
      assert body["headers"] == %{"X-Campaign" => "onboarding"}
      assert body["bounce"] == true

      assert [%{"name" => "guide.pdf", "content_type" => "application/pdf", "data" => _}, %{"name" => "logo.png"}] =
               body["attachments"]

      Req.Test.json(conn, %{"status" => "success", "data" => %{"message_id" => "msg@postal", "messages" => %{}}})
    end)

    email = full_email() |> Email.put_provider_option(:bounce, true)
    assert {:ok, %Response{id: "msg@postal", provider: :postal}} = Mailixir.deliver(email, config)
  end

  test "application error with HTTP 200", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      Req.Test.json(conn, %{
        "status" => "error",
        "data" => %{"code" => "NoRecipients", "message" => "There are no recipients defined"}
      })
    end)

    assert {:error, %Error{status: 200, message: "HTTP 200: NoRecipients: There are no recipients defined"}} =
             Mailixir.deliver(minimal_email(), config)
  end

  test "requires base_url" do
    assert {:error, %Error{reason: :invalid_config, details: [:base_url]}} =
             Mailixir.deliver(minimal_email(), adapter: Postal, api_key: "k")
  end
end
