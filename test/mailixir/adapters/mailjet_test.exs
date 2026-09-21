defmodule Mailixir.Adapters.MailjetTest do
  use Mailixir.AdapterCase, async: true

  alias Mailixir.Adapters.Mailjet

  setup %{req_options: req_options} do
    {:ok, config: [adapter: Mailjet, api_key: "pub", secret_key: "priv", req_options: req_options]}
  end

  @success %{
    "Messages" => [
      %{
        "Status" => "success",
        "To" => [%{"Email" => "jane@example.com", "MessageUUID" => "uuid-1", "MessageID" => 1}]
      }
    ]
  }

  test "full payload", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      assert conn.method == "POST"
      assert conn.host == "api.mailjet.com"
      assert conn.request_path == "/v3.1/send"
      assert_header(conn, "authorization", "Basic " <> Base.encode64("pub:priv"))

      body = json_body(conn)
      assert body["SandboxMode"] == true
      assert [message] = body["Messages"]
      assert message["From"] == %{"Email" => "no-reply@acme.com", "Name" => "Acme"}

      assert message["To"] == [
               %{"Email" => "jane@example.com", "Name" => "Jane"},
               %{"Email" => "john@example.com"}
             ]

      assert message["Cc"] == [%{"Email" => "cc@example.com"}]
      assert message["Bcc"] == [%{"Email" => "bcc@example.com"}]
      assert message["ReplyTo"] == %{"Email" => "support@acme.com", "Name" => "Support"}
      assert message["Subject"] == "Welcome"
      assert message["TextPart"] == "Hi"
      assert message["HTMLPart"] =~ "cid:logo"
      assert message["Headers"] == %{"X-Campaign" => "onboarding"}
      assert message["EventPayload"] == ~s({"user_id":"42"})
      assert message["CustomID"] == "order-1"
      assert message["CustomCampaign"] == "spring"

      assert message["Attachments"] == [
               %{
                 "ContentType" => "application/pdf",
                 "Filename" => "guide.pdf",
                 "Base64Content" => Base.encode64("PDF")
               }
             ]

      assert message["InlinedAttachments"] == [
               %{
                 "ContentType" => "image/png",
                 "Filename" => "logo.png",
                 "ContentID" => "logo",
                 "Base64Content" => Base.encode64("PNG")
               }
             ]

      refute Map.has_key?(message, "TemplateID")
      Req.Test.json(conn, @success)
    end)

    email =
      full_email()
      |> Email.put_provider_option(:custom_id, "order-1")
      |> Email.put_provider_option(:custom_campaign, "spring")
      |> Email.put_provider_option(:sandbox_mode, true)

    assert {:ok, %Response{id: "uuid-1", provider: :mailjet, raw: @success}} =
             Mailixir.deliver(email, config)
  end

  test "template payload", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      assert [message] = json_body(conn)["Messages"]
      assert message["TemplateID"] == 123
      assert message["TemplateLanguage"] == true
      assert message["Variables"] == %{"name" => "Jane"}
      refute Map.has_key?(message, "Subject")
      Req.Test.json(conn, @success)
    end)

    email = Email.new(from: "a@x.com", to: "b@x.com") |> Email.template(123, %{name: "Jane"})
    assert {:ok, _} = Mailixir.deliver(email, config)
  end

  test "per-message error", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{
        "Messages" => [
          %{
            "Status" => "error",
            "Errors" => [
              %{
                "ErrorCode" => "mj-0013",
                "ErrorMessage" => "\"x\" is an invalid email address.",
                "ErrorRelatedTo" => ["To[0].Email"]
              }
            ]
          }
        ]
      })
    end)

    assert {:error, %Error{reason: :api_error, provider: :mailjet, status: 400, message: message}} =
             Mailixir.deliver(minimal_email(), config)

    assert message == ~s|HTTP 400: "x" is an invalid email address. (To[0].Email)|
  end

  test "global error", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{"ErrorMessage" => "Unauthorized", "StatusCode" => 401})
    end)

    assert {:error, %Error{status: 401, message: "HTTP 401: Unauthorized"}} =
             Mailixir.deliver(minimal_email(), config)
  end

  test "missing secret" do
    assert {:error, %Error{reason: :invalid_config, details: [:secret_key]}} =
             Mailixir.deliver(minimal_email(), adapter: Mailjet, api_key: "k")
  end
end

defmodule Mailixir.Adapters.MailjetBatchTest do
  use Mailixir.AdapterCase, async: true

  alias Mailixir.Adapters.Mailjet

  setup %{req_options: req_options} do
    {:ok, config: [adapter: Mailjet, api_key: "pub", secret_key: "priv", req_options: req_options]}
  end

  defp email(subject), do: Email.new(from: "a@x.com", to: "b@x.com", subject: subject, text_body: "t")
  defp success(uuid), do: %{"Status" => "success", "To" => [%{"Email" => "b@x.com", "MessageUUID" => uuid}]}

  test "sends all messages in one request", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      assert [%{"Subject" => "1"}, %{"Subject" => "2"}] = json_body(conn)["Messages"]
      Req.Test.json(conn, %{"Messages" => [success("u1"), success("u2")]})
    end)

    assert {:ok, [%Response{id: "u1"}, %Response{id: "u2"}]} = Mailixir.deliver_many([email("1"), email("2")], config)
  end

  test "chunks by 50", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      messages = json_body(conn)["Messages"]
      send(self(), {:chunk, length(messages)})
      Req.Test.json(conn, %{"Messages" => Enum.map(messages, &success(&1["Subject"]))})
    end)

    emails = for i <- 1..120, do: email("#{i}")
    assert {:ok, responses} = Mailixir.deliver_many(emails, config)
    assert length(responses) == 120
    assert Enum.map(responses, & &1.id) == Enum.map(1..120, &"#{&1}")
    assert_received {:chunk, 50}
    assert_received {:chunk, 50}
    assert_received {:chunk, 20}
  end

  test "per-message failures become batch_failure with ordered results", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{
        "Messages" => [
          success("u1"),
          %{"Status" => "error", "Errors" => [%{"ErrorMessage" => "invalid", "ErrorRelatedTo" => ["To[0].Email"]}]}
        ]
      })
    end)

    assert {:error,
            %Error{
              reason: :batch_failure,
              provider: :mailjet,
              message: "1 of 2 emails failed in a Mailjet batch",
              details: results
            }} =
             Mailixir.deliver_many([email("1"), email("2")], config)

    assert [
             {:ok, %Response{id: "u1"}},
             {:error, %Error{reason: :api_error, message: "HTTP 400: invalid (To[0].Email)"}}
           ] = results
  end

  test "global error", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"ErrorMessage" => "Unauthorized"})
    end)

    assert {:error, %Error{reason: :api_error, status: 401}} = Mailixir.deliver_many([email("1")], config)
  end
end
