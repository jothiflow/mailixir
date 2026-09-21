defmodule Mailixir.Adapters.GmailTest do
  use Mailixir.AdapterCase, async: true

  alias Mailixir.Adapters.Gmail

  def token, do: {:ok, "fetched-token"}

  setup %{req_options: req_options} do
    {:ok, config: [adapter: Gmail, access_token: "static-token", req_options: req_options]}
  end

  test "sends the MIME message base64url-encoded", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      assert conn.host == "gmail.googleapis.com"
      assert conn.request_path == "/gmail/v1/users/me/messages/send"
      assert_header(conn, "authorization", "Bearer static-token")

      body = json_body(conn)
      assert body["threadId"] == "thread-1"
      raw = Base.url_decode64!(body["raw"], padding: false)
      assert raw =~ "From: Acme <no-reply@acme.com>\r\n"
      assert raw =~ "Subject: Welcome\r\n"
      assert raw =~ "Content-Type: multipart/mixed"
      refute raw =~ "bcc@example.com"

      Req.Test.json(conn, %{"id" => "gm-1", "threadId" => "thread-1", "labelIds" => ["SENT"]})
    end)

    email = full_email() |> Email.put_provider_option(:thread_id, "thread-1")
    assert {:ok, %Response{id: "gm-1", provider: :gmail}} = Mailixir.deliver(email, config)
  end

  test "token fetchers and user id", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      assert conn.request_path == "/gmail/v1/users/alice@acme.com/messages/send"
      assert_header(conn, "authorization", "Bearer fetched-token")
      Req.Test.json(conn, %{"id" => "gm-2"})
    end)

    config = Keyword.merge(config, user_id: "alice@acme.com")
    assert {:ok, _} = Mailixir.deliver(minimal_email(), Keyword.put(config, :access_token, {__MODULE__, :token, []}))
    assert {:ok, _} = Mailixir.deliver(minimal_email(), Keyword.put(config, :access_token, fn -> "fetched-token" end))
  end

  test "token fetch failure", %{config: config} do
    assert {:error, %Error{reason: :invalid_config, message: message}} =
             Mailixir.deliver(minimal_email(), Keyword.put(config, :access_token, fn -> {:error, :expired} end))

    assert message =~ "fetching :access_token failed: :expired"

    assert {:error, %Error{reason: :invalid_config}} =
             Mailixir.deliver(minimal_email(), Keyword.put(config, :access_token, 42))
  end

  test "api error", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{
        "error" => %{"code" => 401, "message" => "Invalid Credentials", "status" => "UNAUTHENTICATED"}
      })
    end)

    assert {:error, %Error{status: 401, message: "HTTP 401: Invalid Credentials"}} =
             Mailixir.deliver(minimal_email(), config)
  end
end
