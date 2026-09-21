defmodule Mailixir.Adapters.MailgunTest do
  use Mailixir.AdapterCase, async: true

  alias Mailixir.Adapters.Mailgun

  setup %{req_options: req_options} do
    {:ok, config: [adapter: Mailgun, api_key: "key-1", domain: "mg.acme.com", req_options: req_options]}
  end

  test "full multipart payload", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      assert conn.method == "POST"
      assert conn.host == "api.mailgun.net"
      assert conn.request_path == "/v3/mg.acme.com/messages"
      assert_header(conn, "authorization", "Basic " <> Base.encode64("api:key-1"))

      parts = multipart_body(conn)
      assert field_values(parts, "from") == ["Acme <no-reply@acme.com>"]
      assert field_values(parts, "to") == ["Jane <jane@example.com>", "john@example.com"]
      assert field_values(parts, "cc") == ["cc@example.com"]
      assert field_values(parts, "bcc") == ["bcc@example.com"]
      assert field_values(parts, "h:Reply-To") == ["Support <support@acme.com>"]
      assert field_values(parts, "subject") == ["Welcome"]
      assert field_values(parts, "text") == ["Hi"]
      assert [html] = field_values(parts, "html")
      assert html =~ "cid:logo"
      assert field_values(parts, "h:X-Campaign") == ["onboarding"]
      assert field_values(parts, "o:tag") == ["welcome", "v2"]
      assert field_values(parts, "v:user_id") == ["42"]
      assert field_values(parts, "o:testmode") == ["true"]

      assert [%{filename: "guide.pdf", content_type: "application/pdf", value: "PDF"}] =
               Enum.filter(parts, &(&1.name == "attachment"))

      assert [%{filename: "logo", content_type: "image/png", value: "PNG"}] =
               Enum.filter(parts, &(&1.name == "inline"))

      Req.Test.json(conn, %{"id" => "<1@mg.acme.com>", "message" => "Queued. Thank you."})
    end)

    email = full_email() |> Email.put_provider_option(:testmode, true)

    assert {:ok, %Response{id: "1@mg.acme.com", provider: :mailgun}} =
             Mailixir.deliver(email, config)
  end

  test "template and EU base url", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      assert conn.host == "api.eu.mailgun.net"
      parts = multipart_body(conn)
      assert field_values(parts, "template") == ["welcome"]
      assert field_values(parts, "t:variables") == [~s({"name":"Jane"})]
      assert field_values(parts, "subject") == ["S"]
      Req.Test.json(conn, %{"id" => "x"})
    end)

    email = minimal_email() |> Email.template("welcome", %{name: "Jane"})
    assert {:ok, _} = Mailixir.deliver(email, config ++ [base_url: "https://api.eu.mailgun.net"])
  end

  test "api error", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{"message" => "'from' parameter is missing"})
    end)

    assert {:error, %Error{reason: :api_error, provider: :mailgun, status: 400, message: msg}} =
             Mailixir.deliver(minimal_email(), config)

    assert msg == "HTTP 400: 'from' parameter is missing"
  end

  test "non-JSON error body is surfaced", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn -> Plug.Conn.send_resp(conn, 401, "Forbidden") end)

    assert {:error, %Error{reason: :api_error, status: 401, message: "HTTP 401: Forbidden"}} =
             Mailixir.deliver(minimal_email(), config)
  end

  test "missing domain" do
    assert {:error, %Error{reason: :invalid_config, details: [:domain]}} =
             Mailixir.deliver(minimal_email(), adapter: Mailgun, api_key: "k")
  end
end
