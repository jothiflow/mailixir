defmodule Mailixir.Adapters.LocalTest do
  use ExUnit.Case, async: false

  alias Mailixir.{Adapters.Local, Email, Local.Mailbox, Response}

  setup do
    Mailbox.clear()
    :ok
  end

  defp email(subject), do: Email.new(from: "a@x.com", to: "b@x.com", subject: subject, text_body: "t")

  test "stores emails newest first with ids" do
    assert {:ok, %Response{id: id1, provider: :local}} = Mailixir.deliver(email("1"), adapter: Local)
    assert {:ok, %Response{id: id2}} = Mailixir.deliver(email("2"), adapter: Local)

    assert [%Email{subject: "2", private: %{mailbox_id: ^id2, received_at: %DateTime{}}}, %Email{subject: "1"}] =
             Mailbox.all()

    assert %Email{subject: "1"} = Mailbox.get(id1)
    assert Mailbox.get("nope") == nil

    Mailbox.delete(id1)
    assert [%Email{subject: "2"}] = Mailbox.all()
    Mailbox.clear()
    assert Mailbox.all() == []
  end

  test "caps the mailbox size" do
    for i <- 1..510, do: Mailixir.deliver!(email("#{i}"), adapter: Local)
    all = Mailbox.all()
    assert length(all) == 500
    assert hd(all).subject == "510"
  end
end
