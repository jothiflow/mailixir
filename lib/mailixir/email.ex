defmodule Mailixir.Email do
  @moduledoc """
  Provider-agnostic email. Build one with `new/1` and the pipeable setters,
  then hand it to `Mailixir.deliver/2` or a `Mailixir.Mailer`.

      import Mailixir.Email

      new()
      |> from({"Acme", "no-reply@acme.com"})
      |> to("jane@example.com")
      |> subject("Welcome!")
      |> text_body("Hi Jane")
      |> html_body("<p>Hi Jane</p>")
      |> attachment(Mailixir.Attachment.new("/tmp/guide.pdf"))

  ## Fields common to every provider

    * `:from`, `:to`, `:cc`, `:bcc`, `:reply_to` — `{name, email}` tuples (see `Mailixir.Address`)
    * `:subject`, `:text_body`, `:html_body`
    * `:headers` — extra SMTP headers as a `%{"X-Header" => "value"}` map
    * `:attachments` — `Mailixir.Attachment` structs, regular or inline
    * `:tags` — list of strings for provider-side categorisation
    * `:metadata` — string key/value pairs echoed back in provider webhooks
    * `:template` / `:template_vars` — provider template id and substitution data

  ## Provider-specific options

  `put_provider_option/3` stores arbitrary keys that a given adapter merges into
  its request payload. Each adapter documents what it reads.

  ## Assigns and private data

  `:assigns` (`assign/3`) carries data for rendering the body in your own
  templating layer; `:private` (`put_private/3`) is for library and adapter
  bookkeeping. Neither is sent to the provider.
  """

  alias Mailixir.{Address, Attachment, Error}

  defstruct from: nil,
            to: [],
            cc: [],
            bcc: [],
            reply_to: nil,
            subject: nil,
            text_body: nil,
            html_body: nil,
            headers: %{},
            attachments: [],
            tags: [],
            metadata: %{},
            template: nil,
            template_vars: %{},
            provider_options: %{},
            assigns: %{},
            private: %{}

  @type t :: %__MODULE__{
          from: Address.t() | nil,
          to: [Address.t()],
          cc: [Address.t()],
          bcc: [Address.t()],
          reply_to: Address.t() | nil,
          subject: String.t() | nil,
          text_body: String.t() | nil,
          html_body: String.t() | nil,
          headers: %{String.t() => String.t()},
          attachments: [Attachment.t()],
          tags: [String.t()],
          metadata: %{String.t() => String.t()},
          template: String.t() | integer() | nil,
          template_vars: map(),
          provider_options: map(),
          assigns: map(),
          private: map()
        }

  @doc """
  Creates an email. Accepts the same keys as the struct; address fields go
  through `Mailixir.Address.parse/1`, so any supported shape works.

      Mailixir.Email.new(from: "me@acme.com", to: ["a@x.com", {"B", "b@x.com"}], subject: "Hi")
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs \\ []) do
    Enum.reduce(attrs, %__MODULE__{}, fn
      {:from, v}, email ->
        from(email, v)

      {:to, v}, email ->
        to(email, v)

      {:cc, v}, email ->
        cc(email, v)

      {:bcc, v}, email ->
        bcc(email, v)

      {:reply_to, v}, email ->
        reply_to(email, v)

      {:headers, v}, email ->
        %{email | headers: Map.new(v, fn {k, val} -> {to_string(k), val} end)}

      {:attachments, v}, email ->
        Enum.reduce(v, email, &attachment(&2, &1))

      {:tags, v}, email ->
        %{email | tags: List.wrap(v)}

      {:metadata, v}, email ->
        %{email | metadata: stringify_keys(v)}

      {:template, v}, email ->
        template(email, v)

      {:template_vars, v}, email ->
        %{email | template_vars: v}

      {:provider_options, v}, email ->
        %{email | provider_options: Map.new(v)}

      {:assigns, v}, email ->
        %{email | assigns: Map.new(v)}

      {:private, v}, email ->
        %{email | private: Map.new(v)}

      {key, v}, email when key in [:subject, :text_body, :html_body] ->
        Map.put(email, key, v)

      {key, _}, _ ->
        raise ArgumentError, "unknown Mailixir.Email field #{inspect(key)}"
    end)
  end

  @spec from(t(), Address.input()) :: t()
  def from(%__MODULE__{} = email, address), do: %{email | from: Address.parse(address)}

  @doc "Appends one or more recipients."
  @spec to(t(), Address.input() | [Address.input()]) :: t()
  def to(%__MODULE__{} = email, addresses),
    do: %{email | to: email.to ++ Address.parse_list(addresses)}

  @spec cc(t(), Address.input() | [Address.input()]) :: t()
  def cc(%__MODULE__{} = email, addresses),
    do: %{email | cc: email.cc ++ Address.parse_list(addresses)}

  @spec bcc(t(), Address.input() | [Address.input()]) :: t()
  def bcc(%__MODULE__{} = email, addresses),
    do: %{email | bcc: email.bcc ++ Address.parse_list(addresses)}

  @spec reply_to(t(), Address.input() | nil) :: t()
  def reply_to(%__MODULE__{} = email, nil), do: %{email | reply_to: nil}
  def reply_to(%__MODULE__{} = email, address), do: %{email | reply_to: Address.parse(address)}

  @spec subject(t(), String.t()) :: t()
  def subject(%__MODULE__{} = email, subject) when is_binary(subject),
    do: %{email | subject: subject}

  @spec text_body(t(), String.t()) :: t()
  def text_body(%__MODULE__{} = email, body) when is_binary(body), do: %{email | text_body: body}

  @spec html_body(t(), String.t()) :: t()
  def html_body(%__MODULE__{} = email, body) when is_binary(body), do: %{email | html_body: body}

  @doc "Sets an extra header. Keys are stored as strings."
  @spec header(t(), String.t() | atom(), String.t()) :: t()
  def header(%__MODULE__{} = email, name, value) when is_binary(value) do
    %{email | headers: Map.put(email.headers, to_string(name), value)}
  end

  @doc "Appends an attachment. Accepts a `Mailixir.Attachment` or anything `Mailixir.Attachment.new/1` accepts."
  @spec attachment(t(), Attachment.t() | Path.t() | {String.t(), binary()}) :: t()
  def attachment(%__MODULE__{} = email, %Attachment{} = attachment) do
    %{email | attachments: email.attachments ++ [attachment]}
  end

  def attachment(%__MODULE__{} = email, source), do: attachment(email, Attachment.new(source))

  @spec tag(t(), String.t()) :: t()
  def tag(%__MODULE__{} = email, tag) when is_binary(tag),
    do: %{email | tags: email.tags ++ [tag]}

  @doc "Adds a metadata entry. Providers echo metadata back in webhooks / event logs."
  @spec metadata(t(), String.t() | atom(), String.t()) :: t()
  def metadata(%__MODULE__{} = email, key, value) when is_binary(value) do
    %{email | metadata: Map.put(email.metadata, to_string(key), value)}
  end

  @doc "Selects a provider-side template and, optionally, its substitution variables."
  @spec template(t(), String.t() | integer(), map()) :: t()
  def template(%__MODULE__{} = email, id, vars \\ %{}) when is_binary(id) or is_integer(id) do
    %{email | template: id, template_vars: Map.merge(email.template_vars, vars)}
  end

  @doc "Stores a provider-specific option; see each adapter for the keys it honours."
  @spec put_provider_option(t(), atom(), term()) :: t()
  def put_provider_option(%__MODULE__{} = email, key, value) when is_atom(key) do
    %{email | provider_options: Map.put(email.provider_options, key, value)}
  end

  @doc "Stores a value for your template layer to read when rendering the body."
  @spec assign(t(), atom(), term()) :: t()
  def assign(%__MODULE__{} = email, key, value) when is_atom(key) do
    %{email | assigns: Map.put(email.assigns, key, value)}
  end

  @doc "Stores library-level bookkeeping data that is never sent to the provider."
  @spec put_private(t(), atom(), term()) :: t()
  def put_private(%__MODULE__{} = email, key, value) when is_atom(key) do
    %{email | private: Map.put(email.private, key, value)}
  end

  @doc "All recipients — `to`, `cc` and `bcc` — in that order."
  @spec recipients(t()) :: [Address.t()]
  def recipients(%__MODULE__{} = email), do: email.to ++ email.cc ++ email.bcc

  @doc """
  Checks the email has the minimum every provider requires: a sender, at least
  one recipient, and either a template or a subject plus a body.
  """
  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = email) do
    errors =
      []
      |> check(is_nil(email.from), "from is required")
      |> check(recipients(email) == [], "at least one recipient (to/cc/bcc) is required")
      |> check(
        is_nil(email.template) and is_nil(email.subject),
        "subject is required unless a template is used"
      )
      |> check(
        is_nil(email.template) and is_nil(email.text_body) and is_nil(email.html_body),
        "text_body or html_body is required unless a template is used"
      )

    case errors do
      [] ->
        {:ok, email}

      errors ->
        {:error, Error.new(:invalid_email, Enum.join(Enum.reverse(errors), "; "), details: email)}
    end
  end

  defp check(errors, true, message), do: [message | errors]
  defp check(errors, false, _message), do: errors

  defp stringify_keys(enum), do: Map.new(enum, fn {k, v} -> {to_string(k), v} end)
end
