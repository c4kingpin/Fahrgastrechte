defmodule FahrgastrechteWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  The module intentionally contains only shared building blocks that the
  application uses: flash messages, form inputs, icons and small JS helpers.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework.
  Here are useful references:

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://phoenix-live-view.hexdocs.pm/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: FahrgastrechteWeb.Gettext

  alias Fahrgastrechte.GermanDateTime
  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="fixed inset-x-4 top-4 z-50 flex justify-end sm:inset-x-6"
      {@rest}
    >
      <div class={[
        "flex w-full max-w-sm items-start gap-3 rounded-2xl border px-4 py-3.5 text-sm shadow-[0_20px_50px_-24px_rgba(15,23,42,0.6)] backdrop-blur-xl",
        @kind == :info && "border-sky-200 bg-sky-50/95 text-sky-950",
        @kind == :error && "border-rose-200 bg-rose-50/95 text-rose-950"
      ]}>
        <.icon :if={@kind == :info} name="hero-information-circle" class="size-5 shrink-0" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle" class="size-5 shrink-0" />
        <div>
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{msg}</p>
        </div>
        <div class="flex-1" />
        <button
          type="button"
          class="group -mr-1 self-start rounded-lg p-1 transition hover:bg-black/5 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-current"
          aria-label={gettext("close")}
        >
          <.icon name="hero-x-mark" class="size-5 opacity-40 group-hover:opacity-70" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://phoenix-html.hexdocs.pm/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="mb-2">
      <label
        for={@id}
        class="flex cursor-pointer items-center gap-2 text-sm font-medium text-slate-700"
      >
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          aria-invalid={if(@errors != [], do: "true", else: nil)}
          aria-describedby={if(@errors != [], do: "#{@id}-errors", else: nil)}
          value="true"
          checked={@checked}
          class={
            @class ||
              "scheme-light size-4 rounded border-slate-300 bg-white text-rose-700 accent-rose-700 focus:ring-2 focus:ring-rose-600/20 focus:ring-offset-2 disabled:cursor-not-allowed disabled:bg-slate-100"
          }
          {@rest}
        />
        <span>{@label}</span>
      </label>
      <div :if={@errors != []} id={"#{@id}-errors"}>
        <.error :for={msg <- @errors}>{msg}</.error>
      </div>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="mb-2">
      <label for={@id} class="block">
        <span :if={@label} class="mb-1.5 block text-sm font-medium text-slate-700">
          {@label}
        </span>
        <select
          id={@id}
          name={@name}
          aria-invalid={if(@errors != [], do: "true", else: nil)}
          aria-describedby={if(@errors != [], do: "#{@id}-errors", else: nil)}
          class={[
            @class ||
              "scheme-light block min-h-11 w-full rounded-xl border border-slate-300 bg-white px-3 py-2.5 pr-10 text-base text-slate-950 shadow-sm outline-none transition focus:border-rose-600 focus:ring-4 focus:ring-rose-600/10 disabled:cursor-not-allowed disabled:border-slate-200 disabled:bg-slate-100 disabled:text-slate-500 sm:text-sm",
            @errors != [] &&
              (@error_class ||
                 "border-rose-600 ring-4 ring-rose-600/10")
          ]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <div :if={@errors != []} id={"#{@id}-errors"}>
        <.error :for={msg <- @errors}>{msg}</.error>
      </div>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="mb-2">
      <label for={@id} class="block">
        <span :if={@label} class="mb-1.5 block text-sm font-medium text-slate-700">
          {@label}
        </span>
        <textarea
          id={@id}
          name={@name}
          aria-invalid={if(@errors != [], do: "true", else: nil)}
          aria-describedby={if(@errors != [], do: "#{@id}-errors", else: nil)}
          class={[
            @class ||
              "scheme-light block min-h-28 w-full resize-y rounded-xl border border-slate-300 bg-white px-3 py-2.5 text-base text-slate-950 shadow-sm outline-none transition placeholder:text-slate-400 focus:border-rose-600 focus:ring-4 focus:ring-rose-600/10 disabled:cursor-not-allowed disabled:border-slate-200 disabled:bg-slate-100 disabled:text-slate-500 sm:text-sm",
            @errors != [] &&
              (@error_class ||
                 "border-rose-600 ring-4 ring-rose-600/10")
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <div :if={@errors != []} id={"#{@id}-errors"}>
        <.error :for={msg <- @errors}>{msg}</.error>
      </div>
    </div>
    """
  end

  # Date/datetime inputs submit deterministic German text ("TT.MM.JJJJ[, HH:MM]")
  # instead of relying on the browser's locale, but still offer a native picker
  # through a transparent overlay input synced by the .GermanDatePicker hook.
  def input(%{type: type} = assigns) when type in ["date", "datetime-local"] do
    assigns =
      assigns
      |> assign(:text_value, localized_input_value(assigns.type, assigns.value))
      |> assign(:native_value, native_input_value(assigns.type, assigns.value))
      |> assign(:rest, localized_input_rest(assigns.type, assigns.rest))

    ~H"""
    <div class="mb-2">
      <label for={@id} class="block">
        <span :if={@label} class="mb-1.5 block text-sm font-medium text-slate-700">
          {@label}
        </span>
        <div id={"#{@id}-picker"} phx-hook=".GermanDatePicker" phx-update="ignore" class="relative">
          <input
            type="text"
            name={@name}
            id={@id}
            value={@text_value}
            aria-invalid={if(@errors != [], do: "true", else: nil)}
            aria-describedby={if(@errors != [], do: "#{@id}-errors", else: nil)}
            class={[
              @class ||
                "scheme-light block min-h-11 w-full rounded-xl border border-slate-300 bg-white py-2.5 pl-3 pr-11 text-base text-slate-950 shadow-sm outline-none transition placeholder:text-slate-400 focus:border-rose-600 focus:ring-4 focus:ring-rose-600/10 disabled:cursor-not-allowed disabled:border-slate-200 disabled:bg-slate-100 disabled:text-slate-500 sm:text-sm",
              @errors != [] &&
                (@error_class || "border-rose-600 ring-4 ring-rose-600/10")
            ]}
            {@rest}
          />
          <span class="pointer-events-none absolute inset-y-0 right-0 flex items-center pr-3 text-slate-400">
            <.icon name="hero-calendar-days" class="size-5" />
          </span>
          <input
            type={@type}
            value={@native_value}
            tabindex="-1"
            aria-hidden="true"
            data-role="native-picker"
            disabled={@rest[:disabled]}
            class="absolute inset-y-0 right-0 w-11 cursor-pointer opacity-0 disabled:cursor-not-allowed"
          />
        </div>
        <div :if={@errors != []} id={"#{@id}-errors"}>
          <.error :for={msg <- @errors}>{msg}</.error>
        </div>
      </label>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".GermanDatePicker">
      export default {
        mounted() {
          this.textInput = this.el.querySelector('input[type="text"]')
          this.nativeInput = this.el.querySelector('[data-role="native-picker"]')
          this.isDateTime = this.nativeInput.type === "datetime-local"

          this.nativeInput.addEventListener("change", () => {
            const formatted = this.formatNative(this.nativeInput.value)
            if (!formatted) return

            this.textInput.value = formatted
            this.textInput.dispatchEvent(new Event("input", {bubbles: true}))
            this.textInput.dispatchEvent(new Event("change", {bubbles: true}))
          })

          this.textInput.addEventListener("change", () => {
            const native = this.parseGerman(this.textInput.value)
            if (native) this.nativeInput.value = native
          })
        },
        formatNative(value) {
          if (!value) return null
          if (this.isDateTime) {
            const [datePart, timePart] = value.split("T")
            const [y, m, d] = datePart.split("-")
            return `${d}.${m}.${y}, ${timePart.slice(0, 5)}`
          }
          const [y, m, d] = value.split("-")
          return `${d}.${m}.${y}`
        },
        parseGerman(value) {
          if (this.isDateTime) {
            const match = value.match(/^(\d{2})\.(\d{2})\.(\d{4}),?\s+(\d{2}):(\d{2})$/)
            if (!match) return null
            const [, d, m, y, h, min] = match
            return `${y}-${m}-${d}T${h}:${min}`
          }
          const match = value.match(/^(\d{2})\.(\d{2})\.(\d{4})$/)
          if (!match) return null
          const [, d, m, y] = match
          return `${y}-${m}-${d}`
        }
      }
    </script>
    """
  end

  # Every other input type renders as-is; the browser handles its own locale.
  def input(assigns) do
    assigns =
      assign(
        assigns,
        :normalized_value,
        Phoenix.HTML.Form.normalize_value(assigns.type, assigns.value)
      )

    ~H"""
    <div class="mb-2">
      <label for={@id} class="block">
        <span :if={@label} class="mb-1.5 block text-sm font-medium text-slate-700">
          {@label}
        </span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={@normalized_value}
          aria-invalid={if(@errors != [], do: "true", else: nil)}
          aria-describedby={if(@errors != [], do: "#{@id}-errors", else: nil)}
          class={[
            @class ||
              "scheme-light block min-h-11 w-full rounded-xl border border-slate-300 bg-white px-3 py-2.5 text-base text-slate-950 shadow-sm outline-none transition placeholder:text-slate-400 focus:border-rose-600 focus:ring-4 focus:ring-rose-600/10 disabled:cursor-not-allowed disabled:border-slate-200 disabled:bg-slate-100 disabled:text-slate-500 file:mr-3 file:border-0 file:bg-transparent file:text-sm file:font-semibold file:text-slate-700 sm:text-sm",
            @errors != [] &&
              (@error_class || "border-rose-600 ring-4 ring-rose-600/10")
          ]}
          {@rest}
        />
      </label>
      <div :if={@errors != []} id={"#{@id}-errors"}>
        <.error :for={msg <- @errors}>{msg}</.error>
      </div>
    </div>
    """
  end

  defp localized_input_value("date", %Date{} = value), do: GermanDateTime.format_date(value)

  defp localized_input_value("date", value) when is_binary(value) do
    case GermanDateTime.parse_date(value) do
      {:ok, date} -> GermanDateTime.format_date(date)
      :error -> value
    end
  end

  defp localized_input_value("datetime-local", %NaiveDateTime{} = value),
    do: GermanDateTime.format_datetime(value)

  defp localized_input_value("datetime-local", value) when is_binary(value) do
    case GermanDateTime.parse_datetime(value) do
      {:ok, naive} -> GermanDateTime.format_datetime(naive)
      :error -> value
    end
  end

  defp localized_input_value(_type, value), do: value || ""

  defp native_input_value("date", %Date{} = value), do: Date.to_iso8601(value)

  defp native_input_value("date", value) when is_binary(value) do
    case GermanDateTime.parse_date(value) do
      {:ok, date} -> Date.to_iso8601(date)
      :error -> ""
    end
  end

  defp native_input_value("date", _value), do: ""

  defp native_input_value("datetime-local", %NaiveDateTime{} = value),
    do: Calendar.strftime(value, "%Y-%m-%dT%H:%M")

  defp native_input_value("datetime-local", value) when is_binary(value) do
    case GermanDateTime.parse_datetime(value) do
      {:ok, naive} -> Calendar.strftime(naive, "%Y-%m-%dT%H:%M")
      :error -> ""
    end
  end

  defp native_input_value("datetime-local", _value), do: ""

  defp localized_input_rest("date", rest) do
    rest
    |> Map.put_new(:autocomplete, "off")
    |> Map.put_new(:inputmode, "numeric")
    |> Map.put_new(:placeholder, "TT.MM.JJJJ")
  end

  defp localized_input_rest("datetime-local", rest) do
    rest
    |> Map.put_new(:autocomplete, "off")
    |> Map.put_new(:inputmode, "numeric")
    |> Map.put_new(:placeholder, "TT.MM.JJJJ, HH:MM")
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex items-center gap-2 text-sm font-medium text-rose-700">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(FahrgastrechteWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(FahrgastrechteWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
