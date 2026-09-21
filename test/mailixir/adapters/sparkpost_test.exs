defmodule Mailixir.Adapters.SparkPostTest do
  use Mailixir.AdapterCase, async: true

  alias Mailixir.Adapters.SparkPost

  setup %{req_options: req_options} do
    {:ok, config: [adapter: SparkPost, api_key: "sp-key", req_options: req_options]}
  end

  test "full payload", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      assert conn.host == "api.sparkpost.com"
      assert conn.request_path == "/api/v1/transmissions"
      assert_header(conn, "authorization", "sp-key")

      body = json_body(conn)
      assert body["campaign_id"] == "welcome"
      assert body["metadata"] == %{"user_id" => "42"}
      assert body["options"] == %{"transactional" => true}

      header_to = "Jane <jane@example.com>,john@example.com"

      assert body["recipients"] == [
               %{"address" => %{"email" => "jane@example.com", "name" => "Jane"}},
               %{"address" => %{"email" => "john@example.com"}},
               %{"address" => %{"email" => "cc@example.com", "header_to" => header_to}},
               %{"address" => %{"email" => "bcc@example.com", "header_to" => header_to}}
             ]

      content = body["content"]
      assert content["from"] == %{"email" => "no-reply@acme.com", "name" => "Acme"}
      assert content["subject"] == "Welcome"
      assert content["reply_to"] == "Support <support@acme.com>"
      assert content["headers"] == %{"X-Campaign" => "onboarding", "CC" => "cc@example.com"}
      assert content["text"] == "Hi"
      assert content["html"] =~ "cid:logo"

      assert content["attachments"] == [
               %{"name" => "guide.pdf", "type" => "application/pdf", "data" => Base.encode64("PDF")}
             ]

      assert content["inline_images"] == [%{"name" => "logo", "type" => "image/png", "data" => Base.encode64("PNG")}]

      Req.Test.json(conn, %{
        "results" => %{"total_rejected_recipients" => 0, "total_accepted_recipients" => 4, "id" => "tx-1"}
      })
    end)

    email = full_email() |> Email.put_provider_option(:options, %{transactional: true})
    assert {:ok, %Response{id: "tx-1", provider: :sparkpost}} = Mailixir.deliver(email, config)
  end

  test "template", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      body = json_body(conn)
      assert body["content"] == %{"template_id" => "welcome"}
      assert body["substitution_data"] == %{"name" => "Jane"}
      Req.Test.json(conn, %{"results" => %{"id" => "tx-2"}})
    end)

    email = Email.new(from: "a@x.com", to: "b@x.com") |> Email.template("welcome", %{name: "Jane"})
    assert {:ok, %Response{id: "tx-2"}} = Mailixir.deliver(email, config)
  end

  test "api error", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{
        "errors" => [
          %{"message" => "Invalid domain", "description" => "Sending domain is not verified", "code" => "7001"}
        ]
      })
    end)

    assert {:error, %Error{status: 400, message: "HTTP 400: Sending domain is not verified"}} =
             Mailixir.deliver(minimal_email(), config)
  end
end
