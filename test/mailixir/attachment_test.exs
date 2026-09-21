defmodule Mailixir.AttachmentTest do
  use ExUnit.Case, async: true

  alias Mailixir.Attachment

  test "from raw content guesses the content type" do
    att = Attachment.new({"data.csv", "a,b"})
    assert att.filename == "data.csv"
    assert att.content_type == "text/csv"
    assert att.type == :attachment
    assert att.content_id == nil
    assert Attachment.base64(att) == Base.encode64("a,b")
  end

  test "from a path" do
    path = Path.join(System.tmp_dir!(), "mailixir-#{System.unique_integer([:positive])}.txt")
    File.write!(path, "hello")
    on_exit(fn -> File.rm(path) end)

    att = Attachment.new(path, filename: "renamed.txt")
    assert att.filename == "renamed.txt"
    assert att.content == "hello"
    assert att.content_type == "text/plain"
  end

  test "inline defaults content_id to filename" do
    att = Attachment.new({"logo.png", <<0>>}, type: :inline)
    assert Attachment.inline?(att)
    assert att.content_id == "logo.png"

    assert Attachment.new({"logo.png", <<0>>}, type: :inline, content_id: "logo").content_id ==
             "logo"
  end

  test "rejects unknown type" do
    assert_raise ArgumentError, fn -> Attachment.new({"a", "b"}, type: :weird) end
  end
end
