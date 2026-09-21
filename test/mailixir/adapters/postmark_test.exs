defmodule Mailixir.Adapters.PostmarkTest do
  use Mailixir.AdapterCase, async: true

  alias Mailixir.Adapters.Postmark

  setup %{req_options: req_options} do
    {:ok, config: [adapter: Postmark, api_key: "server-token", req_options: req_options]}
  end

  @ok %{
    "To" => "jane@example.com",
    "SubmittedAt" => "2026-09-21T10:00:00Z",
    "MessageID" => "pm-1",
    "ErrorCode" => 0,
    "Message" => "OK"
  }

  test "full payload", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      assert conn.host == "api.postmarkapp.com"
      assert conn.request_path == "/email"
      assert_header(conn, "x-postmark-server-token", "server-token")

      body = json_body(conn)
      assert body["From"] == "Acme <no-reply@acme.com>"
      assert body["To"] == "Jane <jane@example.com>, john@example.com"
      assert body["Cc"] == "cc@example.com"
      assert body["Bcc"] == "bcc@example.com"
      assert body["ReplyTo"] == "Support <support@acme.com>"
      assert body["Subject"] == "Welcome"
      assert body["TextBody"] == "Hi"
      assert body["HtmlBody"] =~ "cid:logo"
      assert body["Tag"] == "welcome"
      assert body["Metadata"] == %{"user_id" => "42"}
      assert body["Headers"] == [%{"Name" => "X-Campaign", "Value" => "onboarding"}]
      assert body["MessageStream"] == "outbound"
      assert body["TrackOpens"] == true

      assert body["Attachments"] == [
               %{"Name" => "guide.pdf", "Content" => Base.encode64("PDF"), "ContentType" => "application/pdf"},
               %{
                 "Name" => "logo.png",
                 "Content" => Base.encode64("PNG"),
                 "ContentType" => "image/png",
                 "ContentID" => "cid:logo"
               }
             ]

      Req.Test.json(conn, @ok)
    end)

    email = full_email() |> Email.put_provider_option(:track_opens, true)

    assert {:ok, %Response{id: "pm-1", provider: :postmark}} =
             Mailixir.deliver(email, config ++ [message_stream: "outbound"])
  end

  test "template by id and by alias", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      assert conn.request_path == "/email/withTemplate"
      body = json_body(conn)

      case body do
        %{"TemplateId" => 123} -> assert body["TemplateModel"] == %{"name" => "Jane"}
        %{"TemplateAlias" => "welcome"} -> :ok
      end

      refute Map.has_key?(body, "Subject")
      Req.Test.json(conn, @ok)
    end)

    base = Email.new(from: "a@x.com", to: "b@x.com")
    assert {:ok, _} = Mailixir.deliver(Email.template(base, 123, %{name: "Jane"}), config)
    assert {:ok, _} = Mailixir.deliver(Email.template(base, "welcome"), config)
  end

  test "api error", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{"ErrorCode" => 300, "Message" => "Invalid 'From' address."})
    end)

    assert {:error,
            %Error{reason: :api_error, status: 422, message: "HTTP 422: Invalid 'From' address. (error code 300)"}} =
             Mailixir.deliver(minimal_email(), config)
  end

  describe "deliver_many/2" do
    test "batches plain emails", %{stub: stub, config: config} do
      Req.Test.stub(stub, fn conn ->
        assert conn.request_path == "/email/batch"
        assert [%{"Subject" => "1"}, %{"Subject" => "2"}] = json_body(conn)
        Req.Test.json(conn, [Map.put(@ok, "MessageID", "a"), Map.put(@ok, "MessageID", "b")])
      end)

      emails = for s <- ["1", "2"], do: Email.new(from: "a@x.com", to: "b@x.com", subject: s, text_body: "t")
      assert {:ok, [%Response{id: "a"}, %Response{id: "b"}]} = Mailixir.deliver_many(emails, config)
    end

    test "batches templated emails under Messages", %{stub: stub, config: config} do
      Req.Test.stub(stub, fn conn ->
        assert conn.request_path == "/email/batchWithTemplates"
        assert %{"Messages" => [%{"TemplateAlias" => "t"}]} = json_body(conn)
        Req.Test.json(conn, [@ok])
      end)

      email = Email.new(from: "a@x.com", to: "b@x.com") |> Email.template("t")
      assert {:ok, [_]} = Mailixir.deliver_many([email], config)
    end

    test "per-message failures", %{stub: stub, config: config} do
      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, [@ok, %{"ErrorCode" => 406, "Message" => "Inactive recipient"}])
      end)

      emails = for _ <- 1..2, do: minimal_email()

      assert {:error, %Error{reason: :api_error, message: "HTTP 200: Inactive recipient (error code 406)"}} =
               Mailixir.deliver_many(emails, config)
    end

    test "refuses mixed batches", %{config: config} do
      templated = Email.new(from: "a@x.com", to: "b@x.com") |> Email.template("t")
      assert {:error, %Error{reason: :unsupported}} = Mailixir.deliver_many([minimal_email(), templated], config)
    end
  end
end
