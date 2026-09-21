defmodule Mailixir.MIMETest do
  use ExUnit.Case, async: true

  alias Mailixir.{Attachment, Email, MIME}

  @date ~U[2026-09-21 10:30:00Z]

  # gen_smtp's decoder needs the iconv NIF for charset conversion; `encoding: :none`
  # skips it. Our wire format is pure ASCII, so bodies still decode losslessly and
  # only headers come back as raw RFC 2047 words, which decode_words/1 handles.
  defp decode(raw), do: :mimemail.decode(raw, encoding: :none)

  defp decode_words(value) do
    Regex.replace(~r/=\?UTF-8\?B\?([A-Za-z0-9+\/=]+)\?=(?:\r\n )?/, value, fn _, b64 -> Base.decode64!(b64) end)
  end

  defp header(headers, name), do: name |> :proplists.get_value(headers) |> decode_words()

  describe "quoted_printable/1" do
    test "leaves printable ASCII alone and encodes specials" do
      assert MIME.quoted_printable("hello world") == "hello world"
      assert MIME.quoted_printable("a=b") == "a=3Db"
      assert MIME.quoted_printable("café") == "caf=C3=A9"
    end

    test "encodes trailing whitespace and normalises newlines" do
      assert MIME.quoted_printable("end \nnext\t\r\nlast") == "end=20\r\nnext=09\r\nlast"
    end

    test "soft-wraps at 76 characters" do
      encoded = MIME.quoted_printable(String.duplicate("a", 100))
      lines = String.split(encoded, "\r\n")
      assert Enum.all?(lines, &(String.length(&1) <= 76))
      assert String.ends_with?(hd(lines), "=")
      assert encoded |> String.replace("=\r\n", "") == String.duplicate("a", 100)
    end

    test "never splits an escape sequence" do
      encoded = MIME.quoted_printable(String.duplicate("é", 60))
      refute encoded =~ ~r/=[0-9A-F]?=\r\n/
      assert Enum.all?(String.split(encoded, "\r\n"), &(String.length(&1) <= 76))
    end
  end

  test "base64/1 wraps lines and keeps the tail" do
    data = :crypto.strong_rand_bytes(200)
    encoded = MIME.base64(data)
    assert Enum.all?(String.split(encoded, "\r\n"), &(String.length(&1) <= 76))
    assert encoded |> String.replace("\r\n", "") |> Base.decode64!() == data
  end

  describe "header encoding" do
    test "ASCII passes through, UTF-8 gets B-encoded words" do
      assert MIME.encode_header_value("Plain subject") == "Plain subject"
      assert MIME.encode_header_value("Héllo") == "=?UTF-8?B?#{Base.encode64("Héllo")}?="
    end

    test "long UTF-8 values are split into several words on grapheme boundaries" do
      value = String.duplicate("é", 60)
      encoded = MIME.encode_header_value(value)
      words = String.split(encoded, "\r\n ")
      assert length(words) > 1
      assert Enum.all?(words, &(String.length(&1) <= 76))

      decoded =
        words |> Enum.map_join(fn "=?UTF-8?B?" <> rest -> rest |> String.trim_trailing("?=") |> Base.decode64!() end)

      assert decoded == value
    end

    test "addresses" do
      assert MIME.encode_address({nil, "a@x.com"}) == "a@x.com"
      assert MIME.encode_address({"Jane Doe", "a@x.com"}) == "Jane Doe <a@x.com>"
      assert MIME.encode_address({"Doe, Jane", "a@x.com"}) == ~s("Doe, Jane" <a@x.com>)
      assert MIME.encode_address({"Zoë", "a@x.com"}) == "=?UTF-8?B?#{Base.encode64("Zoë")}?= <a@x.com>"
    end
  end

  test "envelope/1 includes bcc and dedupes" do
    email = Email.new(from: {"A", "a@x.com"}, to: "b@x.com", cc: "c@x.com", bcc: ["d@x.com", "b@x.com"])
    assert MIME.envelope(email) == {"a@x.com", ["b@x.com", "c@x.com", "d@x.com"]}
  end

  describe "encode/2" do
    test "plain text only" do
      email = Email.new(from: {"Acme", "a@x.com"}, to: "b@x.com", subject: "Hi", text_body: "Hello")
      raw = MIME.encode(email, date: @date, message_id: "fixed@x.com")

      assert raw =~ "Date: Mon, 21 Sep 2026 10:30:00 +0000\r\n"
      assert raw =~ "From: Acme <a@x.com>\r\n"
      assert raw =~ "To: b@x.com\r\n"
      assert raw =~ "Subject: Hi\r\n"
      assert raw =~ "Message-ID: <fixed@x.com>\r\n"
      assert raw =~ "MIME-Version: 1.0\r\n"
      assert raw =~ "Content-Type: text/plain; charset=utf-8\r\n"
      assert raw =~ "Content-Transfer-Encoding: quoted-printable\r\n\r\nHello"
      refute raw =~ "Bcc"

      assert {"text", "plain", _headers, _params, "Hello"} = decode(raw)
    end

    test "custom headers override generated ones and bcc is never written" do
      email =
        Email.new(from: "a@x.com", to: "b@x.com", bcc: "secret@x.com", subject: "s", text_body: "t")
        |> Email.header("Message-ID", "<mine@x.com>")
        |> Email.header("X-Custom", "yes")

      raw = MIME.encode(email)
      assert raw =~ "Message-ID: <mine@x.com>\r\n"
      assert raw =~ "X-Custom: yes\r\n"
      assert length(Regex.scan(~r/^Message-ID:/m, raw)) == 1
      refute raw =~ "secret@x.com"
    end

    test "full structure: mixed > related > alternative, round-trips through a decoder" do
      email =
        Email.new(
          from: {"Zoë", "a@x.com"},
          to: [{"Jane", "j@x.com"}, "k@x.com"],
          cc: "c@x.com",
          reply_to: "r@x.com",
          subject: "Résumé — attached",
          text_body: "Plain café",
          html_body: ~s(<p>Hi <img src="cid:logo"></p>),
          attachments: [
            Attachment.new({"résumé.pdf", :crypto.strong_rand_bytes(300)}, content_type: "application/pdf"),
            Attachment.new({"logo.png", <<137, 80, 78, 71>>}, type: :inline, content_id: "logo")
          ]
        )

      raw = MIME.encode(email)

      assert {"multipart", "mixed", headers, _, [related, pdf]} = decode(raw)
      assert header(headers, "Subject") == "Résumé — attached"
      assert header(headers, "From") == "Zoë <a@x.com>"
      assert header(headers, "To") == "Jane <j@x.com>,k@x.com"
      assert raw =~ "To: Jane <j@x.com>,\r\n k@x.com\r\n"
      assert header(headers, "Reply-To") == "r@x.com"

      assert {"multipart", "related", _, _, [alternative, logo]} = related
      assert {"multipart", "alternative", _, _, [text, html]} = alternative
      assert {"text", "plain", _, _, "Plain café"} = text
      assert {"text", "html", _, _, ~s(<p>Hi <img src="cid:logo"></p>)} = html

      assert {"image", "png", logo_headers, logo_params, <<137, 80, 78, 71>>} = logo
      assert :proplists.get_value("Content-ID", logo_headers) == "<logo>"
      assert logo_params[:disposition] == "inline"

      assert {"application", "pdf", _, pdf_params, content} = pdf
      assert byte_size(content) == 300
      assert pdf_params[:disposition] == "attachment"
      assert raw =~ "filename*=UTF-8''r%C3%A9sum%C3%A9.pdf"
    end

    test "html only" do
      email = Email.new(from: "a@x.com", to: "b@x.com", subject: "s", html_body: "<b>x</b>")
      assert {"text", "html", _, _, "<b>x</b>"} = email |> MIME.encode() |> decode()
    end
  end
end
