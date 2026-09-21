defmodule Mailixir.Adapters.SESTest do
  use Mailixir.AdapterCase, async: true

  alias Mailixir.Adapters.SES

  setup %{req_options: req_options} do
    config = [
      adapter: SES,
      access_key_id: "AKIAEXAMPLE",
      secret_access_key: "secret",
      region: "eu-west-1",
      req_options: req_options
    ]

    {:ok, config: config}
  end

  test "full payload is SigV4-signed", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      assert conn.method == "POST"
      assert conn.host == "email.eu-west-1.amazonaws.com"
      assert conn.request_path == "/v2/email/outbound-emails"

      [auth] = Plug.Conn.get_req_header(conn, "authorization")

      assert auth =~
               ~r|^AWS4-HMAC-SHA256 Credential=AKIAEXAMPLE/\d{8}/eu-west-1/ses/aws4_request,SignedHeaders=|

      assert [_] = Plug.Conn.get_req_header(conn, "x-amz-date")
      assert Plug.Conn.get_req_header(conn, "x-amz-security-token") == ["tok"]

      body = json_body(conn)
      assert body["FromEmailAddress"] == "Acme <no-reply@acme.com>"

      assert body["Destination"] == %{
               "ToAddresses" => ["Jane <jane@example.com>", "john@example.com"],
               "CcAddresses" => ["cc@example.com"],
               "BccAddresses" => ["bcc@example.com"]
             }

      assert body["ReplyToAddresses"] == ["Support <support@acme.com>"]
      assert body["ConfigurationSetName"] == "per-email"

      assert body["EmailTags"] == [
               %{"Name" => "tag", "Value" => "welcome"},
               %{"Name" => "tag", "Value" => "v2"},
               %{"Name" => "user_id", "Value" => "42"}
             ]

      simple = body["Content"]["Simple"]
      assert simple["Subject"] == %{"Data" => "Welcome", "Charset" => "UTF-8"}
      assert simple["Body"]["Text"] == %{"Data" => "Hi", "Charset" => "UTF-8"}
      assert simple["Body"]["Html"]["Data"] =~ "cid:logo"
      assert simple["Headers"] == [%{"Name" => "X-Campaign", "Value" => "onboarding"}]

      assert simple["Attachments"] == [
               %{
                 "FileName" => "guide.pdf",
                 "ContentType" => "application/pdf",
                 "RawContent" => Base.encode64("PDF"),
                 "ContentTransferEncoding" => "BASE64",
                 "ContentDisposition" => "ATTACHMENT"
               },
               %{
                 "FileName" => "logo.png",
                 "ContentType" => "image/png",
                 "RawContent" => Base.encode64("PNG"),
                 "ContentTransferEncoding" => "BASE64",
                 "ContentDisposition" => "INLINE",
                 "ContentId" => "logo"
               }
             ]

      Req.Test.json(conn, %{"MessageId" => "0100018-abc"})
    end)

    email = full_email() |> Email.put_provider_option(:configuration_set, "per-email")

    assert {:ok, %Response{id: "0100018-abc", provider: :ses}} =
             Mailixir.deliver(
               email,
               config ++ [session_token: "tok", configuration_set: "default"]
             )
  end

  test "template payload and config-level configuration set", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      assert conn.host == "localhost"
      body = json_body(conn)

      assert body["Content"] == %{
               "Template" => %{"TemplateName" => "welcome", "TemplateData" => ~s({"name":"Jane"})}
             }

      assert body["ConfigurationSetName"] == "default"
      refute Map.has_key?(body, "ReplyToAddresses")
      assert Plug.Conn.get_req_header(conn, "x-amz-security-token") == []
      Req.Test.json(conn, %{"MessageId" => "m"})
    end)

    email =
      Email.new(from: "a@x.com", to: "b@x.com") |> Email.template("welcome", %{name: "Jane"})

    assert {:ok, %Response{id: "m"}} =
             Mailixir.deliver(
               email,
               config ++ [base_url: "http://localhost:4566", configuration_set: "default"]
             )
  end

  test "api error includes the AWS error type", %{stub: stub, config: config} do
    Req.Test.stub(stub, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Plug.Conn.put_resp_header("x-amzn-errortype", "MessageRejected")
      |> Req.Test.json(%{"message" => "Email address is not verified."})
    end)

    assert {:error, %Error{reason: :api_error, provider: :ses, status: 400, message: message}} =
             Mailixir.deliver(minimal_email(), config)

    assert message == "HTTP 400: MessageRejected: Email address is not verified."
  end

  test "missing region" do
    assert {:error, %Error{reason: :invalid_config, details: [:region]}} =
             Mailixir.deliver(minimal_email(),
               adapter: SES,
               access_key_id: "a",
               secret_access_key: "b"
             )
  end
end
