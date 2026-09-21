defmodule Mailixir.Attachment do
  @moduledoc """
  A file attached to an email — either a regular attachment or an inline
  image referenced from the HTML body via `cid:` (`type: :inline`).
  """

  @enforce_keys [:filename, :content]
  defstruct [
    :filename,
    :content,
    :content_id,
    content_type: "application/octet-stream",
    type: :attachment
  ]

  @type type :: :attachment | :inline

  @type t :: %__MODULE__{
          filename: String.t(),
          content: binary(),
          content_type: String.t(),
          content_id: String.t() | nil,
          type: type()
        }

  @doc """
  Builds an attachment from a file path or from raw content.

      Mailixir.Attachment.new("/tmp/invoice.pdf")
      Mailixir.Attachment.new({"report.csv", "a,b\\n1,2"}, content_type: "text/csv")
      Mailixir.Attachment.new("/tmp/logo.png", type: :inline, content_id: "logo")

  Options:

    * `:filename` — overrides the name derived from the path
    * `:content_type` — defaults to a guess from the extension via `MIME`
    * `:type` — `:attachment` (default) or `:inline`
    * `:content_id` — for inline attachments; defaults to the filename
  """
  @spec new(Path.t() | {String.t(), binary()}, keyword()) :: t()
  def new(source, opts \\ [])

  def new({filename, content}, opts) when is_binary(filename) and is_binary(content) do
    build(filename, content, opts)
  end

  def new(path, opts) when is_binary(path) do
    build(Path.basename(path), File.read!(path), opts)
  end

  @doc "Base64-encodes the attachment content, as most HTTP APIs expect."
  @spec base64(t()) :: String.t()
  def base64(%__MODULE__{content: content}), do: Base.encode64(content)

  @doc "Returns true for inline attachments."
  @spec inline?(t()) :: boolean()
  def inline?(%__MODULE__{type: :inline}), do: true
  def inline?(%__MODULE__{}), do: false

  defp build(filename, content, opts) do
    filename = Keyword.get(opts, :filename, filename)
    type = Keyword.get(opts, :type, :attachment)

    unless type in [:attachment, :inline] do
      raise ArgumentError,
            "attachment :type must be :attachment or :inline, got: #{inspect(type)}"
    end

    %__MODULE__{
      filename: filename,
      content: content,
      content_type: Keyword.get(opts, :content_type) || MIME.from_path(filename),
      type: type,
      content_id: Keyword.get(opts, :content_id) || if(type == :inline, do: filename)
    }
  end
end
