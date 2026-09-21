defmodule Mailixir.MIME do
  @moduledoc """
  Encodes a `Mailixir.Email` as an RFC 5322 message with MIME parts, ready
  for SMTP, sendmail, or any API that takes a raw message.

  Structure produced (outer to inner), only as deep as the email needs:

      multipart/mixed          # when there are regular attachments
      └ multipart/related      # when there are inline attachments
        └ multipart/alternative# when both text and HTML bodies exist
          ├ text/plain
          └ text/html

  Text parts are quoted-printable, attachments base64, non-ASCII headers
  RFC 2047 encoded, non-ASCII filenames RFC 2231 encoded. `Bcc` is never
  written into the message; use `envelope/1` for the SMTP recipients.
  """

  alias Mailixir.{Address, Attachment, Email}

  @crlf "\r\n"
  @line_max 76

  @doc """
  Encodes the email. Options:

    * `:date` — `DateTime` for the `Date` header, defaults to now
    * `:message_id` — defaults to a random id at the sender's domain
  """
  @spec encode(Email.t(), keyword()) :: binary()
  def encode(%Email{} = email, opts \\ []) do
    {part_headers, body} = render(body_part(email))

    headers =
      message_headers(email, opts) ++
        Enum.map(email.headers, fn {k, v} -> {k, encode_header_value(v)} end) ++ part_headers

    IO.iodata_to_binary([Enum.map(headers, &format_header/1), @crlf, body])
  end

  @doc "SMTP envelope: `{sender_email, [recipient_email]}` including Bcc."
  @spec envelope(Email.t()) :: {String.t(), [String.t()]}
  def envelope(%Email{} = email) do
    {Address.email(email.from), email |> Email.recipients() |> Enum.map(&Address.email/1) |> Enum.uniq()}
  end

  @doc "Encodes a header value with RFC 2047 B-encoding when it contains non-ASCII characters."
  @spec encode_header_value(String.t()) :: String.t()
  def encode_header_value(value) do
    if ascii?(value), do: value, else: encoded_words(value)
  end

  @doc "Formats an address for a header, encoding the display name when needed."
  @spec encode_address(Address.t()) :: String.t()
  def encode_address({nil, email}), do: email

  def encode_address({name, email} = address),
    do: if(ascii?(name), do: Address.format(address), else: "#{encoded_words(name)} <#{email}>")

  @doc "Quoted-printable encoding (RFC 2045 §6.7) with CRLF line endings and soft breaks."
  @spec quoted_printable(binary()) :: binary()
  def quoted_printable(binary) do
    binary
    |> String.split(~r/\r\n|\n|\r/)
    |> Enum.map_join(@crlf, &qp_line/1)
  end

  @doc "Base64 encoding wrapped at 76 characters."
  @spec base64(binary()) :: binary()
  def base64(binary) do
    binary |> Base.encode64() |> chunk_every(@line_max) |> Enum.join(@crlf)
  end

  # -- message headers ----------------------------------------------------------

  defp message_headers(email, opts) do
    date = Keyword.get(opts, :date) || DateTime.utc_now()

    [
      {"Date", rfc2822_date(date)},
      {"From", encode_address(email.from)},
      {"To", address_list(email.to)},
      {"Cc", address_list(email.cc)},
      {"Reply-To", email.reply_to && encode_address(email.reply_to)},
      {"Subject", email.subject && encode_header_value(email.subject)},
      {"Message-ID", "<#{Keyword.get(opts, :message_id) || message_id(email)}>"},
      {"MIME-Version", "1.0"}
    ]
    |> Enum.reject(fn {name, value} -> is_nil(value) or Map.has_key?(email.headers, name) end)
  end

  defp address_list([]), do: nil
  defp address_list(addresses), do: Enum.map_join(addresses, ",\r\n ", &encode_address/1)

  @doc "Generates a random `Message-ID` (without angle brackets) at the sender's domain."
  @spec message_id(Email.t()) :: String.t()
  def message_id(%Email{from: from}) do
    domain = from |> Address.email() |> String.split("@") |> List.last()
    "#{Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)}@#{domain}"
  end

  defp rfc2822_date(%DateTime{} = date) do
    Calendar.strftime(date, "%a, %d %b %Y %H:%M:%S ") <> tz_offset(date.utc_offset + date.std_offset)
  end

  defp tz_offset(seconds) do
    sign = if seconds < 0, do: "-", else: "+"
    minutes = div(abs(seconds), 60)
    sign <> String.pad_leading("#{div(minutes, 60)}", 2, "0") <> String.pad_leading("#{rem(minutes, 60)}", 2, "0")
  end

  # -- parts --------------------------------------------------------------------

  defp body_part(email) do
    {inline, regular} = Enum.split_with(email.attachments, &Attachment.inline?/1)

    content =
      case {email.text_body, email.html_body} do
        {text, nil} -> text_part("text/plain", text || "")
        {nil, html} -> text_part("text/html", html)
        {text, html} -> multipart("alternative", [text_part("text/plain", text), text_part("text/html", html)])
      end

    content = if inline == [], do: content, else: multipart("related", [content | Enum.map(inline, &attachment_part/1)])
    if regular == [], do: content, else: multipart("mixed", [content | Enum.map(regular, &attachment_part/1)])
  end

  defp text_part(type, text) do
    {[{"Content-Type", "#{type}; charset=utf-8"}, {"Content-Transfer-Encoding", "quoted-printable"}],
     quoted_printable(text)}
  end

  defp attachment_part(%Attachment{} = att) do
    disposition = if Attachment.inline?(att), do: "inline", else: "attachment"

    headers =
      [
        {"Content-Type", att.content_type <> name_param("name", att.filename)},
        {"Content-Transfer-Encoding", "base64"},
        {"Content-Disposition", disposition <> name_param("filename", att.filename)},
        if(Attachment.inline?(att), do: {"Content-ID", "<#{att.content_id}>"})
      ]
      |> Enum.reject(&is_nil/1)

    {headers, base64(att.content)}
  end

  defp multipart(subtype, parts) do
    boundary = "=_mailixir_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    {[{"Content-Type", "multipart/#{subtype}; boundary=\"#{boundary}\""}], {:multipart, boundary, parts}}
  end

  defp render({headers, {:multipart, boundary, parts}}) do
    body =
      Enum.map(parts, fn part ->
        {part_headers, part_body} = render(part)
        ["--", boundary, @crlf, Enum.map(part_headers, &format_header/1), @crlf, part_body, @crlf]
      end) ++ ["--", boundary, "--", @crlf]

    {headers, body}
  end

  defp render({headers, body}), do: {headers, body}

  defp format_header({name, value}), do: [name, ": ", value, @crlf]

  # RFC 2231 for non-ASCII filenames, quoted string otherwise.
  defp name_param(param, filename) do
    if ascii?(filename) do
      ~s(; #{param}="#{String.replace(filename, ~s("), ~s(\\"))}")
    else
      "; #{param}*=UTF-8''#{URI.encode(filename, &URI.char_unreserved?/1)}"
    end
  end

  # -- encodings ----------------------------------------------------------------

  defp encoded_words(value) do
    value
    |> String.graphemes()
    |> chunk_by_bytes(45)
    |> Enum.map_join("\r\n ", &"=?UTF-8?B?#{Base.encode64(&1)}?=")
  end

  defp chunk_by_bytes(graphemes, max) do
    graphemes
    |> Enum.chunk_while(
      {[], 0},
      fn g, {acc, size} ->
        if size + byte_size(g) > max and acc != [],
          do: {:cont, acc |> Enum.reverse() |> IO.iodata_to_binary(), {[g], byte_size(g)}},
          else: {:cont, {[g | acc], size + byte_size(g)}}
      end,
      fn
        {[], _} -> {:cont, []}
        {acc, _} -> {:cont, acc |> Enum.reverse() |> IO.iodata_to_binary(), []}
      end
    )
  end

  defp qp_line(line) do
    line
    |> :binary.bin_to_list()
    |> qp_tokens([])
    |> qp_wrap([], 0, [])
  end

  # Trailing whitespace must be encoded so it survives transport.
  defp qp_tokens([c], acc) when c in [?\s, ?\t], do: Enum.reverse([hex(c) | acc])
  defp qp_tokens([c | rest], acc) when c in [?\s, ?\t], do: qp_tokens(rest, [<<c>> | acc])
  defp qp_tokens([c | rest], acc) when c in 33..126 and c != ?=, do: qp_tokens(rest, [<<c>> | acc])
  defp qp_tokens([c | rest], acc), do: qp_tokens(rest, [hex(c) | acc])
  defp qp_tokens([], acc), do: Enum.reverse(acc)

  defp qp_wrap([], line, _len, lines), do: [Enum.reverse(line) | lines] |> Enum.reverse() |> Enum.join("=\r\n")

  defp qp_wrap([token | rest], line, len, lines) do
    size = byte_size(token)

    if len + size > @line_max - 1,
      do: qp_wrap(rest, [token], size, [Enum.reverse(line) | lines]),
      else: qp_wrap(rest, [token | line], len + size, lines)
  end

  defp hex(c), do: "=" <> String.pad_leading(Integer.to_string(c, 16), 2, "0")

  defp chunk_every(string, size) when byte_size(string) <= size, do: [string]

  defp chunk_every(string, size) do
    <<head::binary-size(size), rest::binary>> = string
    [head | chunk_every(rest, size)]
  end

  defp ascii?(string), do: String.printable?(string) and string =~ ~r/^[\x20-\x7E]*$/
end
