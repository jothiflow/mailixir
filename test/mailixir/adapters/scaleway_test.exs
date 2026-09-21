defmodule Mailixir.Adapters.ScalewayTest do
  use Mailixir.AdapterCase, async: true

  alias Mailixir.Adapters.Scaleway

  setup %{req_options: req_options} do
    {:ok, config: [adapter: Scaleway, secret_key: "scw-secret", project_id: "proj-1", req_options: req_options]}
  end

  test "full payload", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      assert conn.host == "api.scaleway.com"
      assert conn.request_path == "/transactional-email/v1alpha1/regions/nl-ams/emails"
      assert_header(conn, "x-auth-token", "scw-secret")

      body = json_body(conn)
      assert body["project_id"] == "proj-1"
      assert body["from"] == %{"email" => "no-reply@acme.com", "name" => "Acme"}
      assert body["to"] == [%{"email" => "jane@example.com", "name" => "Jane"}, %{"email" => "john@example.com"}]
      assert body["cc"] == [%{"email" => "cc@example.com"}]
      assert body["bcc"] == [%{"email" => "bcc@example.com"}]
      assert body["subject"] == "Welcome"
      assert body["text"] == "Hi"
      assert body["html"] =~ "cid:logo"

      assert body["additional_headers"] == [
               %{"key" => "Reply-To", "value" => "Support <support@acme.com>"},
               %{"key" => "X-Campaign", "value" => "onboarding"}
             ]

      assert body["attachments"] == [
               %{"name" => "guide.pdf", "type" => "application/pdf", "content" => Base.encode64("PDF")},
               %{"name" => "logo.png", "type" => "image/png", "content" => Base.encode64("PNG")}
             ]

      assert body["send_before"] == "2030-01-01T00:00:00Z"
      Req.Test.json(conn, %{"emails" => [%{"id" => "e-1", "message_id" => "<m-1@scw>", "status" => "new"}]})
    end)

    email = full_email() |> Email.put_provider_option(:send_before, "2030-01-01T00:00:00Z")

    assert {:ok, %Response{id: "m-1@scw", provider: :scaleway}} =
             Mailixir.deliver(email, config ++ [region: "nl-ams"])
  end

  test "default region", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      assert conn.request_path =~ "/regions/fr-par/"
      Req.Test.json(conn, %{"emails" => []})
    end)

    assert {:ok, %Response{id: nil}} = Mailixir.deliver(minimal_email(), config)
  end

  test "api error", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      conn
      |> Plug.Conn.put_status(403)
      |> Req.Test.json(%{"message" => "insufficient permissions", "type" => "permissions_denied"})
    end)

    assert {:error, %Error{status: 403, message: "HTTP 403: insufficient permissions"}} =
             Mailixir.deliver(minimal_email(), config)
  end

  test "missing project" do
    assert {:error, %Error{reason: :invalid_config, details: [:project_id]}} =
             Mailixir.deliver(minimal_email(), adapter: Scaleway, secret_key: "s")
  end
end
