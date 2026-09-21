if Code.ensure_loaded?(Plug.Router) do
  defmodule Mailixir.Plug.Mailbox do
    @moduledoc """
    Browser UI for emails captured by `Mailixir.Adapters.Local`. Requires the
    optional `:plug` dependency.

    Mount it in a Phoenix router, dev-only:

        if Application.compile_env(:my_app, :dev_routes) do
          scope "/dev" do
            pipe_through :browser
            forward "/mailbox", Mailixir.Plug.Mailbox
          end
        end

    Or in a bare `Plug.Router`: `forward "/mailbox", to: Mailixir.Plug.Mailbox`.

    Routes (relative to the mount point):

      * `GET /` — inbox, newest first
      * `GET /:id` — one email: headers, text and HTML bodies, attachments
      * `GET /:id/html` — the HTML body alone (rendered in a sandboxed iframe)
      * `GET /:id/attachments/:index` — download an attachment
      * `POST /:id/delete`, `POST /clear`
    """

    use Plug.Router

    alias Mailixir.{Address, Attachment, Email, Local.Mailbox}

    plug(:match)
    plug(:dispatch)

    get "/" do
      case Mailbox.all() do
        [] -> html(conn, 200, layout(conn, nil, [], empty()))
        [latest | _] = emails -> html(conn, 200, layout(conn, latest, emails, detail(conn, latest)))
      end
    end

    post "/clear" do
      Mailbox.clear()
      redirect(conn, base(conn))
    end

    get "/:id" do
      with_email(conn, id, fn email -> html(conn, 200, layout(conn, email, Mailbox.all(), detail(conn, email))) end)
    end

    get "/:id/html" do
      with_email(conn, id, fn email -> html(conn, 200, email.html_body || "") end)
    end

    get "/:id/attachments/:index" do
      with_email(conn, id, fn email ->
        case Enum.at(email.attachments, String.to_integer(index)) do
          %Attachment{} = att ->
            conn
            |> put_resp_content_type(att.content_type)
            |> put_resp_header("content-disposition", ~s(attachment; filename="#{att.filename}"))
            |> send_resp(200, att.content)

          nil ->
            send_resp(conn, 404, "attachment not found")
        end
      end)
    end

    post "/:id/delete" do
      Mailbox.delete(id)
      redirect(conn, base(conn))
    end

    match _ do
      send_resp(conn, 404, "not found")
    end

    defp with_email(conn, id, fun) do
      case Mailbox.get(id) do
        %Email{} = email -> fun.(email)
        nil -> send_resp(conn, 404, "email not found")
      end
    end

    defp html(conn, status, body) do
      conn |> put_resp_content_type("text/html") |> send_resp(status, body)
    end

    defp redirect(conn, to) do
      conn |> put_resp_header("location", to) |> send_resp(303, "")
    end

    defp base(%Plug.Conn{script_name: []}), do: "/"
    defp base(%Plug.Conn{script_name: script_name}), do: "/" <> Enum.join(script_name, "/")

    defp path(conn, suffix), do: String.trim_trailing(base(conn), "/") <> suffix

    # -- rendering ------------------------------------------------------------

    defp layout(conn, current, emails, content) do
      [
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>Mailixir mailbox</title><style>",
        css(),
        "</style></head><body><aside><header><h1>Mailbox</h1>",
        if(emails == [],
          do: "",
          else: [
            "<form method=\"post\" action=\"",
            path(conn, "/clear"),
            "\"><button type=\"submit\">Clear all</button></form>"
          ]
        ),
        "</header><ul>",
        Enum.map(emails, &list_item(conn, &1, current)),
        "</ul></aside><main>",
        content,
        "</main></body></html>"
      ]
    end

    defp list_item(conn, email, current) do
      id = email.private.mailbox_id
      class = if current && current.private.mailbox_id == id, do: " class=\"active\"", else: ""

      [
        "<li",
        class,
        "><a href=\"",
        path(conn, "/#{id}"),
        "\"><strong>",
        e(email.subject || "(no subject)"),
        "</strong><span>",
        e(addresses(email.to)),
        "</span><time>",
        e(DateTime.to_iso8601(email.private.received_at)),
        "</time></a></li>"
      ]
    end

    defp empty, do: "<p class=\"empty\">No emails yet. Deliver one with <code>Mailixir.Adapters.Local</code>.</p>"

    defp detail(conn, email) do
      id = email.private.mailbox_id

      [
        "<h2>",
        e(email.subject || "(no subject)"),
        "</h2><table>",
        rows([
          {"From", email.from && Address.format(email.from)},
          {"To", addresses(email.to)},
          {"Cc", addresses(email.cc)},
          {"Bcc", addresses(email.bcc)},
          {"Reply-To", email.reply_to && Address.format(email.reply_to)},
          {"Received", DateTime.to_iso8601(email.private.received_at)},
          {"Template", email.template && "#{inspect(email.template)} #{inspect(email.template_vars)}"},
          {"Tags", if(email.tags != [], do: Enum.join(email.tags, ", "))},
          {"Metadata", if(map_size(email.metadata) > 0, do: inspect(email.metadata))},
          {"Provider options", if(map_size(email.provider_options) > 0, do: inspect(email.provider_options))}
        ]),
        Enum.map(email.headers, fn {k, v} -> row(k, v) end),
        "</table>",
        attachments(conn, email),
        bodies(conn, email),
        "<form method=\"post\" action=\"",
        path(conn, "/#{id}/delete"),
        "\" class=\"danger\"><button type=\"submit\">Delete</button></form>"
      ]
    end

    defp attachments(_conn, %Email{attachments: []}), do: ""

    defp attachments(conn, %Email{attachments: attachments} = email) do
      [
        "<h3>Attachments</h3><ul class=\"attachments\">",
        attachments
        |> Enum.with_index()
        |> Enum.map(fn {att, index} ->
          [
            "<li><a href=\"",
            path(conn, "/#{email.private.mailbox_id}/attachments/#{index}"),
            "\">",
            e(att.filename),
            "</a> <small>",
            e(att.content_type),
            " · ",
            e("#{byte_size(att.content)} bytes"),
            if(Attachment.inline?(att), do: " · inline cid:#{e(att.content_id)}", else: ""),
            "</small></li>"
          ]
        end),
        "</ul>"
      ]
    end

    defp bodies(conn, email) do
      [
        if(email.html_body,
          do: [
            "<h3>HTML</h3><iframe sandbox src=\"",
            path(conn, "/#{email.private.mailbox_id}/html"),
            "\"></iframe>"
          ],
          else: ""
        ),
        if(email.text_body, do: ["<h3>Text</h3><pre>", e(email.text_body), "</pre>"], else: "")
      ]
    end

    defp rows(pairs), do: for({label, value} <- pairs, value not in [nil, ""], do: row(label, value))
    defp row(label, value), do: ["<tr><th>", e(label), "</th><td>", e(value), "</td></tr>"]

    defp addresses([]), do: nil
    defp addresses(list), do: Enum.map_join(list, ", ", &Address.format/1)

    defp e(value), do: Plug.HTML.html_escape(to_string(value))

    defp css do
      """
      *{box-sizing:border-box}body{margin:0;display:grid;grid-template-columns:320px 1fr;height:100vh;font:14px/1.45 system-ui,sans-serif;color:#1a1a1a;background:#fff}
      aside{border-right:1px solid #e5e5e5;overflow-y:auto;background:#fafafa}aside header{display:flex;justify-content:space-between;align-items:center;padding:12px 16px;border-bottom:1px solid #e5e5e5}
      h1{font-size:16px;margin:0}h2{margin:0 0 12px;font-size:20px}h3{font-size:13px;text-transform:uppercase;letter-spacing:.04em;color:#666;margin:24px 0 8px}
      aside ul{list-style:none;margin:0;padding:0}aside li a{display:block;padding:10px 16px;border-bottom:1px solid #eee;text-decoration:none;color:inherit}
      aside li.active a{background:#e8f0fe}aside li strong{display:block;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
      aside li span,aside li time{display:block;color:#666;font-size:12px}main{padding:24px 32px;overflow-y:auto}
      table{border-collapse:collapse;margin-bottom:8px}th{text-align:left;padding:2px 12px 2px 0;color:#666;font-weight:500;vertical-align:top;white-space:nowrap}td{padding:2px 0;word-break:break-all}
      iframe{width:100%;height:60vh;border:1px solid #e5e5e5;border-radius:4px;background:#fff}pre{white-space:pre-wrap;background:#f6f6f6;padding:12px;border-radius:4px}
      button{font:inherit;padding:4px 10px;border:1px solid #ccc;border-radius:4px;background:#fff;cursor:pointer}form.danger{margin-top:24px}form.danger button{color:#b00020;border-color:#b00020}
      .attachments{padding-left:18px}.empty{color:#666}small{color:#666}code{background:#f0f0f0;padding:1px 4px;border-radius:3px}
      """
    end
  end
end
