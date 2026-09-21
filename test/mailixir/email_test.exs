defmodule Mailixir.EmailTest do
  use ExUnit.Case, async: true

  import Mailixir.Email
  alias Mailixir.{Attachment, Email, Error}

  test "new/1 normalises every field" do
    email =
      Email.new(
        from: "Acme <no-reply@acme.com>",
        to: ["a@x.com", {"B", "b@x.com"}],
        cc: "c@x.com",
        bcc: [%{name: "D", email: "d@x.com"}],
        reply_to: "r@x.com",
        subject: "Hi",
        text_body: "t",
        html_body: "<p>h</p>",
        headers: [{:"X-One", "1"}],
        attachments: [{"a.txt", "x"}],
        tags: "welcome",
        metadata: %{user_id: "42"},
        template: "tpl",
        template_vars: %{name: "A"},
        provider_options: [track_opens: true]
      )

    assert email.from == {"Acme", "no-reply@acme.com"}
    assert email.to == [{nil, "a@x.com"}, {"B", "b@x.com"}]
    assert email.cc == [{nil, "c@x.com"}]
    assert email.bcc == [{"D", "d@x.com"}]
    assert email.reply_to == {nil, "r@x.com"}
    assert email.headers == %{"X-One" => "1"}
    assert [%Attachment{filename: "a.txt"}] = email.attachments
    assert email.tags == ["welcome"]
    assert email.metadata == %{"user_id" => "42"}
    assert email.template == "tpl"
    assert email.template_vars == %{name: "A"}
    assert email.provider_options == %{track_opens: true}
  end

  test "new/1 rejects unknown keys" do
    assert_raise ArgumentError, ~r/unknown Mailixir.Email field :nope/, fn ->
      Email.new(nope: 1)
    end
  end

  test "setters append and pipe" do
    email =
      new()
      |> from({"Acme", "a@acme.com"})
      |> to("one@x.com")
      |> to(["two@x.com"])
      |> cc("cc@x.com")
      |> bcc("bcc@x.com")
      |> reply_to("r@x.com")
      |> subject("S")
      |> text_body("T")
      |> html_body("H")
      |> header("X-A", "1")
      |> header(:"X-B", "2")
      |> attachment({"f.txt", "c"})
      |> tag("t1")
      |> tag("t2")
      |> metadata(:k, "v")
      |> template(12, %{a: 1})
      |> put_provider_option(:foo, :bar)

    assert length(email.to) == 2
    assert email.headers == %{"X-A" => "1", "X-B" => "2"}
    assert email.tags == ["t1", "t2"]
    assert email.metadata == %{"k" => "v"}
    assert email.template == 12
    assert email.template_vars == %{a: 1}
    assert email.provider_options == %{foo: :bar}

    assert recipients(email) == [
             {nil, "one@x.com"},
             {nil, "two@x.com"},
             {nil, "cc@x.com"},
             {nil, "bcc@x.com"}
           ]

    assert reply_to(email, nil).reply_to == nil
  end

  describe "validate/1" do
    test "collects every missing requirement" do
      assert {:error, %Error{reason: :invalid_email, message: message}} = validate(new())
      assert message =~ "from is required"
      assert message =~ "at least one recipient"
      assert message =~ "subject is required"
      assert message =~ "text_body or html_body is required"
    end

    test "template waives subject and body" do
      email = new() |> from("a@x.com") |> to("b@x.com") |> template("welcome")
      assert {:ok, ^email} = validate(email)
    end

    test "complete email passes" do
      email = new() |> from("a@x.com") |> bcc("b@x.com") |> subject("s") |> html_body("h")
      assert {:ok, ^email} = validate(email)
    end
  end
end

defmodule Mailixir.EmailAssignsTest do
  use ExUnit.Case, async: true

  import Mailixir.Email

  test "assigns and private are stored, not validated against" do
    email = new() |> assign(:user, "jane") |> put_private(:attempt, 1)
    assert email.assigns == %{user: "jane"}
    assert email.private == %{attempt: 1}
    assert Mailixir.Email.new(assigns: [a: 1], private: %{b: 2}).assigns == %{a: 1}
  end
end
