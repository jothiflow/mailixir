if Code.ensure_loaded?(Plug.Conn) do
  defmodule Mailixir.Plug.RawBody do
    @moduledoc """
    Keeps the raw request body available for webhook signature verification.

    `Plug.Parsers` consumes the body while parsing, so pass this module as its
    `:body_reader`; the untouched bytes are then in `conn.assigns.raw_body`.

        plug Plug.Parsers,
          parsers: [:urlencoded, :multipart, :json],
          body_reader: {Mailixir.Plug.RawBody, :read_body, []},
          json_decoder: JSON

    Only bodies of requests whose path matches `:paths` (default: every path
    containing `/webhooks`) are kept, so ordinary requests pay nothing.
    """

    @doc "A `Plug.Parsers` body reader that caches the body under `conn.assigns.raw_body`."
    @spec read_body(Plug.Conn.t(), keyword()) ::
            {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
    def read_body(conn, opts \\ []) do
      paths = Keyword.get(opts, :paths, ["/webhooks"])

      case Plug.Conn.read_body(conn, opts) do
        {status, chunk, conn} when status in [:ok, :more] ->
          if Enum.any?(paths, &String.contains?(conn.request_path, &1)),
            do: {status, chunk, Plug.Conn.assign(conn, :raw_body, (conn.assigns[:raw_body] || "") <> chunk)},
            else: {status, chunk, conn}

        other ->
          other
      end
    end
  end
end
