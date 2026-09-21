defmodule Mailixir.Adapters.SMTP2GOTest do
  use Mailixir.AdapterCase, async: true

  alias Mailixir.Adapters.SMTP2GO

  setup %{req_options: req_options} do
    {:ok, config: [adapter: SMTP2GO, api_key: "api-key", req_options: req_options]}
  end

  test "full payload", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      assert conn.host == "api.smtp2go.com"
      assert conn.request_path == "/v3/email/send"
      assert_header(conn, "x-smtp2go-api-key", "api-key")

      body = json_body(conn)
      assert body["sender"] == "Acme <no-reply@acme.com>"
      assert body["to"] == ["Jane <jane@example.com>", "john@example.com"]
      assert body["cc"] == ["cc@example.com"]
      assert body["bcc"] == ["bcc@example.com"]
      assert body["subject"] == "Welcome"
      assert body["text_body"] == "Hi"
      assert body["html_body"] =~ "cid:logo"

      assert body["custom_headers"] == [
               %{"header" => "Reply-To", "value" => "Support <support@acme.com>"},
               %{"header" => "X-Campaign", "value" => "onboarding"}
             ]

      assert body["attachments"] == [
               %{"filename" => "guide.pdf", "fileblob" => Base.encode64("PDF"), "mimetype" => "application/pdf"}
             ]

      assert body["inlines"] == [%{"filename" => "logo", "fileblob" => Base.encode64("PNG"), "mimetype" => "image/png"}]

      Req.Test.json(conn, %{
        "request_id" => "r",
        "data" => %{"succeeded" => 1, "failed" => 0, "failures" => [], "email_id" => "1a2b"}
      })
    end)

    assert {:ok, %Response{id: "1a2b", provider: :smtp2go}} = Mailixir.deliver(full_email(), config)
  end

  test "template", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      body = json_body(conn)
      assert body["template_id"] == "tpl"
      assert body["template_data"] == %{"name" => "Jane"}
      Req.Test.json(conn, %{"data" => %{"succeeded" => 1, "email_id" => "x"}})
    end)

    email = Email.new(from: "a@x.com", to: "b@x.com") |> Email.template("tpl", %{name: "Jane"})
    assert {:ok, _} = Mailixir.deliver(email, config)
  end

  test "api error", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{
        "data" => %{"error" => "Sender not allowed", "error_code" => "E_ApiResponseCodes.NON_VALIDATING_IN_PAYLOAD"}
      })
    end)

    assert {:error,
            %Error{status: 400, message: "HTTP 400: E_ApiResponseCodes.NON_VALIDATING_IN_PAYLOAD: Sender not allowed"}} =
             Mailixir.deliver(minimal_email(), config)
  end

  test "all recipients failed", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      Req.Test.json(conn, %{"data" => %{"succeeded" => 0, "failed" => 1, "failures" => ["b@x.com: rejected"]}})
    end)

    assert {:error, %Error{status: 200, message: ~s(HTTP 200: "b@x.com: rejected")}} =
             Mailixir.deliver(minimal_email(), config)
  end
end
