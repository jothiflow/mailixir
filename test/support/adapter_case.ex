defmodule Mailixir.AdapterCase do
  @moduledoc """
  Shared helpers for adapter tests: a `Req.Test` stub wired through
  `:req_options`, plus request-body decoding for JSON and multipart.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Mailixir.AdapterCase
      alias Mailixir.{Email, Error, Response}
    end
  end

  setup do
    stub = :"stub-#{System.unique_integer([:positive])}"
    {:ok, stub: stub, req_options: [plug: {Req.Test, stub}, retry: false]}
  end

  @doc "Reads and JSON-decodes the request body."
  def json_body(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    JSON.decode!(body)
  end

  @doc """
  Parses a multipart body into `[%{name:, value:, filename:, content_type:}]`,
  preserving repeated fields and order.
  """
  def multipart_body(conn) do
    [content_type] = Plug.Conn.get_req_header(conn, "content-type")
    [_, boundary] = Regex.run(~r/boundary=(.+)$/, content_type)
    {:ok, body, _conn} = Plug.Conn.read_body(conn)

    body
    |> String.split("--" <> boundary)
    |> Enum.reject(&(&1 in ["", "--\r\n", "--"]))
    |> Enum.map(&parse_part/1)
  end

  defp parse_part(part) do
    [raw_headers, value] =
      part |> String.trim_leading("\r\n") |> String.split("\r\n\r\n", parts: 2)

    headers =
      Map.new(String.split(raw_headers, "\r\n"), fn h ->
        [k, v] = String.split(h, ": ", parts: 2)
        {String.downcase(k), v}
      end)

    disposition = Map.fetch!(headers, "content-disposition")
    [_, name] = Regex.run(~r/name="([^"]*)"/, disposition)

    %{
      name: name,
      value: String.trim_trailing(value, "\r\n"),
      filename: with([_, f] <- Regex.run(~r/filename="([^"]*)"/, disposition), do: f),
      content_type: headers["content-type"]
    }
  end

  @doc "Returns every value for a multipart field name."
  def field_values(parts, name), do: for(%{name: ^name, value: v} <- parts, do: v)

  @doc "Asserts the request carries the given header value."
  def assert_header(conn, name, value) do
    ExUnit.Assertions.assert(Plug.Conn.get_req_header(conn, name) == [value])
    conn
  end

  @doc "A fully-populated email exercising every mapped field."
  def full_email do
    Mailixir.Email.new(
      from: {"Acme", "no-reply@acme.com"},
      to: [{"Jane", "jane@example.com"}, "john@example.com"],
      cc: "cc@example.com",
      bcc: "bcc@example.com",
      reply_to: {"Support", "support@acme.com"},
      subject: "Welcome",
      text_body: "Hi",
      html_body: ~s(<p>Hi <img src="cid:logo"></p>),
      headers: %{"X-Campaign" => "onboarding"},
      attachments: [
        Mailixir.Attachment.new({"guide.pdf", "PDF"}, content_type: "application/pdf"),
        Mailixir.Attachment.new({"logo.png", "PNG"}, type: :inline, content_id: "logo")
      ],
      tags: ["welcome", "v2"],
      metadata: %{"user_id" => "42"}
    )
  end

  @doc "A minimal email."
  def minimal_email do
    Mailixir.Email.new(from: "a@x.com", to: "b@x.com", subject: "S", text_body: "T")
  end
end
