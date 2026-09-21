defmodule Mailixir.Plug.MailboxTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Mailixir.{Adapters.Local, Attachment, Email, Local.Mailbox}

  @opts Mailixir.Plug.Mailbox.init([])

  setup do
    Mailbox.clear()

    email =
      Email.new(
        from: {"Acme", "a@x.com"},
        to: "b@x.com",
        subject: "Hello <world>",
        text_body: "plain & simple",
        html_body: "<p>Hi</p>",
        headers: %{"X-Test" => "1"},
        tags: ["welcome"],
        attachments: [Attachment.new({"file.txt", "content"}, content_type: "text/plain")]
      )

    {:ok, %{id: id}} = Mailixir.deliver(email, adapter: Local)
    {:ok, id: id}
  end

  defp request(method, path) do
    conn(method, path) |> Map.put(:script_name, ["dev", "mailbox"]) |> Mailixir.Plug.Mailbox.call(@opts)
  end

  test "index lists emails and shows the latest, escaped", %{id: id} do
    conn = request(:get, "/")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]
    assert conn.resp_body =~ "Hello &lt;world&gt;"
    assert conn.resp_body =~ "plain &amp; simple"
    assert conn.resp_body =~ ~s(href="/dev/mailbox/#{id}")
    assert conn.resp_body =~ ~s(src="/dev/mailbox/#{id}/html")
    assert conn.resp_body =~ "X-Test"
    assert conn.resp_body =~ "welcome"
    assert conn.resp_body =~ "file.txt"
  end

  test "empty inbox" do
    Mailbox.clear()
    conn = request(:get, "/")
    assert conn.status == 200
    assert conn.resp_body =~ "No emails yet"
  end

  test "show, html and attachment routes", %{id: id} do
    assert request(:get, "/#{id}").status == 200
    assert request(:get, "/#{id}/html").resp_body == "<p>Hi</p>"

    conn = request(:get, "/#{id}/attachments/0")
    assert conn.status == 200
    assert conn.resp_body == "content"
    assert get_resp_header(conn, "content-disposition") == [~s(attachment; filename="file.txt")]
    assert request(:get, "/#{id}/attachments/9").status == 404
    assert request(:get, "/unknown").status == 404
  end

  test "delete and clear redirect to the mount point", %{id: id} do
    conn = request(:post, "/#{id}/delete")
    assert conn.status == 303
    assert get_resp_header(conn, "location") == ["/dev/mailbox"]
    assert Mailbox.all() == []

    Mailixir.deliver!(Email.new(from: "a@x.com", to: "b@x.com", subject: "s", text_body: "t"), adapter: Local)
    assert request(:post, "/clear").status == 303
    assert Mailbox.all() == []
  end
end
